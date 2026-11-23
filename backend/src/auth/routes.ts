import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { z } from 'zod';

import { config } from '../config.js';
import { prisma } from '../db.js';
import { CodePurpose } from '../generated/prisma/enums.js';
import { ApiError, conflict, forbidden, notFound } from '../lib/errors.js';
import { profileJson } from '../lib/serialize.js';
import { consumeCode, sendCode } from './codes.js';
import { currentUser, requireAuth } from './rbac.js';
import { issueTokens, revokeRefreshToken, rotateRefreshToken } from './tokens.js';

const BCRYPT_ROUNDS = 12;

const email = z
  .string()
  .trim()
  .toLowerCase()
  .pipe(z.email({ message: 'Enter a valid email address.' }));
const password = z
  .string()
  .min(8, 'Use at least 8 characters.')
  .max(72, 'Use at most 72 characters.'); // bcrypt only reads 72 bytes
const code = z.string().trim().regex(/^\d{6}$/, 'Enter the 6-digit code from your email.');

const credentials = z.object({ email, password });
const emailOnly = z.object({ email });
const emailAndCode = z.object({ email, code });
const refreshBody = z.object({ refresh_token: z.string().min(1) });
const profileUpdate = z.object({
  full_name: z.string().trim().max(80).nullable(),
});

// Slows down password guessing and email flooding from one address.
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 30,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  skip: () => config.env === 'test',
  message: { error: 'Too many attempts. Please wait a few minutes and try again.', code: 'rate_limited' },
});

export const authRouter = Router();

/** Creates an account (or updates an unverified one) and emails a code. */
authRouter.post('/register', authLimiter, async (req, res) => {
  const body = credentials.parse(req.body);
  const passwordHash = await bcrypt.hash(body.password, BCRYPT_ROUNDS);

  const existing = await prisma.user.findUnique({ where: { email: body.email } });
  if (existing?.emailVerified) {
    throw conflict('An account with this email already exists. Log in instead.');
  }
  const user = existing
    ? await prisma.user.update({ where: { id: existing.id }, data: { passwordHash } })
    : await prisma.user.create({ data: { email: body.email, passwordHash } });

  await sendCode(user, CodePurpose.signup);
  res.status(202).json({ message: `A verification code was sent to ${user.email}.` });
});

authRouter.post('/register/resend', authLimiter, async (req, res) => {
  const body = emailOnly.parse(req.body);
  const user = await prisma.user.findUnique({ where: { email: body.email } });
  if (!user) throw notFound('No account found for this email. Create an account first.');
  if (user.emailVerified) throw conflict('This email is already verified. Log in instead.');

  await sendCode(user, CodePurpose.signup);
  res.status(202).json({ message: `A new code has been sent to ${user.email}.` });
});

authRouter.post('/register/verify', authLimiter, async (req, res) => {
  const body = emailAndCode.parse(req.body);
  const user = await prisma.user.findUnique({ where: { email: body.email } });
  if (!user) throw notFound('No account found for this email. Create an account first.');

  await consumeCode(user.id, CodePurpose.signup, body.code);
  const verified = await prisma.user.update({
    where: { id: user.id },
    data: { emailVerified: true },
  });
  res.json({ user: profileJson(verified), ...(await issueTokens(user.id)) });
});

/** Emails a login code. Never creates an account. */
authRouter.post('/login/code', authLimiter, async (req, res) => {
  const body = emailOnly.parse(req.body);
  const user = await prisma.user.findUnique({ where: { email: body.email } });
  if (!user) throw notFound('No account found for this email. Create an account first.');

  await sendCode(user, CodePurpose.login);
  res.status(202).json({ message: `A login code was sent to ${user.email}.` });
});

/** Signs in with an emailed code. Also verifies the email if it was not yet. */
authRouter.post('/login/code/verify', authLimiter, async (req, res) => {
  const body = emailAndCode.parse(req.body);
  const user = await prisma.user.findUnique({ where: { email: body.email } });
  if (!user) throw notFound('No account found for this email. Create an account first.');

  await consumeCode(user.id, CodePurpose.login, body.code);
  const signedIn = user.emailVerified
    ? user
    : await prisma.user.update({ where: { id: user.id }, data: { emailVerified: true } });
  res.json({ user: profileJson(signedIn), ...(await issueTokens(user.id)) });
});

authRouter.post('/login', authLimiter, async (req, res) => {
  const body = credentials.parse(req.body);
  const user = await prisma.user.findUnique({ where: { email: body.email } });
  const ok = user ? await bcrypt.compare(body.password, user.passwordHash) : false;
  if (!user || !ok) throw new ApiError(401, 'Wrong email or password.', 'invalid_credentials');
  if (!user.emailVerified) {
    throw forbidden('Your email is not verified yet. Log in with an email code to verify it.');
  }
  res.json({ user: profileJson(user), ...(await issueTokens(user.id)) });
});

authRouter.post('/refresh', async (req, res) => {
  const body = refreshBody.parse(req.body);
  res.json(await rotateRefreshToken(body.refresh_token));
});

authRouter.post('/logout', async (req, res) => {
  const body = refreshBody.parse(req.body);
  await revokeRefreshToken(body.refresh_token);
  res.status(204).end();
});

// ----------------------------------- Me -------------------------------------

export const meRouter = Router();
meRouter.use(requireAuth);

meRouter.get('/', (req, res) => {
  res.json(profileJson(currentUser(req)));
});

meRouter.patch('/', async (req, res) => {
  const body = profileUpdate.parse(req.body);
  const user = await prisma.user.update({
    where: { id: currentUser(req).id },
    data: { fullName: body.full_name || null },
  });
  res.json(profileJson(user));
});
