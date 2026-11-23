import { Router } from 'express';
import { z } from 'zod';

import { currentUser, requireAuth, requireRole } from '../auth/rbac.js';
import { prisma } from '../db.js';
import { Role } from '../generated/prisma/enums.js';
import { forbidden, notFound } from '../lib/errors.js';
import { profileJson } from '../lib/serialize.js';

const roleBody = z.object({ role: z.enum(Role) });

export const adminRouter = Router();
adminRouter.use(requireAuth, requireRole(Role.admin));

adminRouter.get('/users', async (_req, res) => {
  const users = await prisma.user.findMany({ orderBy: { email: 'asc' } });
  res.json(users.map(profileJson));
});

/** Admins cannot change their own role, so the app never loses its last admin by accident. */
adminRouter.patch('/users/:id/role', async (req, res) => {
  const body = roleBody.parse(req.body);
  const id = z.uuid().safeParse(req.params.id);
  if (!id.success) throw notFound('User not found.');
  if (id.data === currentUser(req).id) throw forbidden('You cannot change your own role.');

  const user = await prisma.user.findUnique({ where: { id: id.data } });
  if (!user) throw notFound('User not found.');
  const updated = await prisma.user.update({ where: { id: user.id }, data: { role: body.role } });
  res.json(profileJson(updated));
});
