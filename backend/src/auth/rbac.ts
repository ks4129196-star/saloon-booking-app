import type { RequestHandler } from 'express';

import { prisma } from '../db.js';
import { Role } from '../generated/prisma/enums.js';
import type { User } from '../generated/prisma/client.js';
import { forbidden, unauthorized } from '../lib/errors.js';
import { verifyAccessToken } from './tokens.js';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: User;
    }
  }
}

/**
 * Requires a valid access token. The user (and their current role) is loaded
 * from the database on every request, so a role change applies immediately.
 */
export const requireAuth: RequestHandler = async (req, _res, next) => {
  const header = req.headers.authorization ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token) throw unauthorized();

  const user = await prisma.user.findUnique({ where: { id: verifyAccessToken(token) } });
  if (!user) throw unauthorized();
  req.user = user;
  next();
};

/** Allows only the listed roles. Use after [requireAuth]. */
export const requireRole =
  (...roles: Role[]): RequestHandler =>
  (req, _res, next) => {
    if (!req.user || !roles.includes(req.user.role)) throw forbidden();
    next();
  };

/** The signed-in user. Only call in handlers behind [requireAuth]. */
export function currentUser(req: Express.Request): User {
  if (!req.user) throw unauthorized();
  return req.user;
}

/** Admins manage every salon; owners manage the salons they own. */
export function canManageSalon(user: User, salon: { ownerId: string | null }): boolean {
  return user.role === Role.admin || (user.role === Role.owner && salon.ownerId === user.id);
}
