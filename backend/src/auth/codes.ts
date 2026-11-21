import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';

import { config } from '../config.js';
import { prisma } from '../db.js';
import { CodePurpose } from '../generated/prisma/enums.js';
import { ApiError, badRequest } from '../lib/errors.js';
import { getMailer } from './mailer.js';

const CODE_TTL_MS = 10 * 60 * 1000;
const RESEND_COOLDOWN_MS = 60 * 1000;
const MAX_ATTEMPTS = 5;

const hashCode = (userId: string, purpose: CodePurpose, code: string) =>
  createHmac('sha256', config.codeSecret).update(`${userId}:${purpose}:${code}`).digest();

/** Creates a 6-digit code, emails it, and stores only its hash. */
export async function sendCode(user: { id: string; email: string }, purpose: CodePurpose) {
  const latest = await prisma.emailCode.findFirst({
    where: { userId: user.id, purpose },
    orderBy: { createdAt: 'desc' },
  });
  if (latest) {
    const waitMs = latest.createdAt.getTime() + RESEND_COOLDOWN_MS - Date.now();
    if (waitMs > 0) {
      throw new ApiError(
        429,
        `Please wait ${Math.ceil(waitMs / 1000)} seconds before requesting another code.`,
        'code_cooldown',
      );
    }
  }

  const code = randomInt(0, 1_000_000).toString().padStart(6, '0');
  const record = await prisma.emailCode.create({
    data: {
      userId: user.id,
      purpose,
      codeHash: hashCode(user.id, purpose, code).toString('hex'),
      expiresAt: new Date(Date.now() + CODE_TTL_MS),
    },
  });

  try {
    await getMailer().sendCode(user.email, code, purpose);
  } catch (error) {
    console.error('Sending the code email failed:', error);
    // Let the user ask again straight away.
    await prisma.emailCode.delete({ where: { id: record.id } });
    throw new ApiError(
      502,
      'We could not send the email right now. Please try again in a few minutes.',
      'email_failed',
    );
  }
}

/** Checks a code and marks it used. Throws 400 if it is wrong or expired. */
export async function consumeCode(userId: string, purpose: CodePurpose, code: string) {
  const invalid = badRequest('That code is wrong or has expired. Request a new one.');
  const record = await prisma.emailCode.findFirst({
    where: { userId, purpose, consumedAt: null },
    orderBy: { createdAt: 'desc' },
  });
  if (!record || record.expiresAt <= new Date() || record.attempts >= MAX_ATTEMPTS) {
    throw invalid;
  }

  const expected = Buffer.from(record.codeHash, 'hex');
  const actual = hashCode(userId, purpose, code);
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    await prisma.emailCode.update({
      where: { id: record.id },
      data: { attempts: { increment: 1 } },
    });
    throw invalid;
  }

  const { count } = await prisma.emailCode.updateMany({
    where: { id: record.id, consumedAt: null },
    data: { consumedAt: new Date() },
  });
  if (count === 0) throw invalid; // already used by a parallel request
}
