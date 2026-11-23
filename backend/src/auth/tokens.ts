import { createHash, randomBytes } from 'node:crypto';

import jwt from 'jsonwebtoken';

import { config } from '../config.js';
import { prisma } from '../db.js';
import { unauthorized } from '../lib/errors.js';

const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
const REFRESH_TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;

const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');

export function signAccessToken(userId: string): string {
  return jwt.sign({}, config.jwtSecret, {
    algorithm: 'HS256',
    subject: userId,
    expiresIn: ACCESS_TOKEN_TTL_SECONDS,
  });
}

/** Returns the user id, or throws 401. */
export function verifyAccessToken(token: string): string {
  try {
    const payload = jwt.verify(token, config.jwtSecret, { algorithms: ['HS256'] });
    if (typeof payload === 'string' || !payload.sub) throw unauthorized();
    return payload.sub;
  } catch {
    throw unauthorized();
  }
}

/** Refresh tokens are random strings; only their hash is stored. */
async function createRefreshToken(userId: string): Promise<string> {
  const token = randomBytes(48).toString('base64url');
  await prisma.refreshToken.create({
    data: {
      userId,
      tokenHash: sha256(token),
      expiresAt: new Date(Date.now() + REFRESH_TOKEN_TTL_MS),
    },
  });
  return token;
}

export async function issueTokens(userId: string) {
  return {
    access_token: signAccessToken(userId),
    refresh_token: await createRefreshToken(userId),
    expires_in: ACCESS_TOKEN_TTL_SECONDS,
  };
}

/**
 * Swaps a refresh token for a new pair. Each refresh token works once; using
 * one that was already rotated revokes every session of that user, because
 * it means the token was copied.
 */
export async function rotateRefreshToken(token: string) {
  const stored = await prisma.refreshToken.findUnique({ where: { tokenHash: sha256(token) } });
  if (!stored) throw unauthorized();

  if (stored.revokedAt) {
    await prisma.refreshToken.updateMany({
      where: { userId: stored.userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    throw unauthorized();
  }
  if (stored.expiresAt <= new Date()) throw unauthorized();

  const { count } = await prisma.refreshToken.updateMany({
    where: { id: stored.id, revokedAt: null },
    data: { revokedAt: new Date() },
  });
  if (count === 0) throw unauthorized(); // lost a race with another refresh
  return issueTokens(stored.userId);
}

export async function revokeRefreshToken(token: string) {
  await prisma.refreshToken.updateMany({
    where: { tokenHash: sha256(token), revokedAt: null },
    data: { revokedAt: new Date() },
  });
}
