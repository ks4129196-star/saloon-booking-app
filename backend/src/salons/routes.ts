import { Router } from 'express';
import { z } from 'zod';

import { canManageSalon, currentUser, requireAuth, requireRole } from '../auth/rbac.js';
import { prisma } from '../db.js';
import { Role } from '../generated/prisma/enums.js';
import { badRequest, forbidden, notFound } from '../lib/errors.js';
import { serviceJson, salonJson } from '../lib/serialize.js';
import { isValidTimeZone } from '../lib/time.js';
import { emitSalonChanged, emitSalonDeleted } from '../realtime.js';

const salonFields = z
  .object({
    owner_id: z.uuid().nullable().optional(),
    name: z.string().trim().min(2).max(80),
    type: z.string().trim().min(1).max(60).default('Salon'),
    address: z.string().trim().max(200).default(''),
    phone: z.string().trim().max(30).default(''),
    lat: z.number().min(-90).max(90),
    lon: z.number().min(-180).max(180),
    timezone: z.string().refine(isValidTimeZone, 'Unknown time zone.').default('Asia/Kolkata'),
    open_min: z.number().int().min(0).max(1439),
    close_min: z.number().int().min(1).max(1440),
    staff: z.number().int().min(1).max(100).default(1),
    queue: z.number().int().min(0).max(500).optional(),
    highlights: z.array(z.string().trim().min(1).max(40)).max(12).default([]),
  })
  .refine((salon) => salon.close_min > salon.open_min, {
    message: 'Closing time must be after opening time.',
    path: ['close_min'],
  });

const queueBody = z.object({ queue: z.number().int().min(0).max(500) });

const serviceFields = z.object({
  name: z.string().trim().min(1).max(80),
  price: z.number().int().min(0).max(1_000_000),
  minutes: z.number().int().min(5).max(600),
  category: z.string().trim().min(1).max(40).default('Other'),
});

const idParam = (value: unknown) => {
  const id = Number(value);
  if (!Number.isInteger(id) || id <= 0) throw notFound();
  return id;
};

const withServices = { services: { orderBy: { id: 'asc' as const } } };

async function loadManagedSalon(req: Express.Request, id: number) {
  const salon = await prisma.salon.findUnique({ where: { id } });
  if (!salon) throw notFound('This salon no longer exists.');
  if (!canManageSalon(currentUser(req), salon)) throw forbidden();
  return salon;
}

async function broadcastSalon(id: number) {
  const salon = await prisma.salon.findUnique({ where: { id }, include: withServices });
  if (salon) emitSalonChanged(salon);
  return salon;
}

/**
 * Only admins choose a salon's owner. An owner's salons always belong to
 * them, and the new owner must have the owner role.
 */
async function resolveOwnerId(req: Express.Request, requested: string | null | undefined) {
  const user = currentUser(req);
  if (user.role !== Role.admin) return user.id;
  if (!requested) return null;
  const owner = await prisma.user.findUnique({ where: { id: requested } });
  if (!owner || owner.role !== Role.owner) throw badRequest('The new owner must be a salon owner.');
  return owner.id;
}

export const salonsRouter = Router();
salonsRouter.use(requireAuth);

salonsRouter.get('/', async (_req, res) => {
  const salons = await prisma.salon.findMany({ include: withServices, orderBy: { id: 'asc' } });
  res.json(salons.map(salonJson));
});

/** Salons this user may manage: every salon for admins, owned ones for owners. */
salonsRouter.get('/managed', requireRole(Role.owner, Role.admin), async (req, res) => {
  const user = currentUser(req);
  const salons = await prisma.salon.findMany({
    where: user.role === Role.admin ? {} : { ownerId: user.id },
    include: withServices,
    orderBy: { name: 'asc' },
  });
  res.json(salons.map(salonJson));
});

salonsRouter.get('/:id', async (req, res) => {
  const salon = await prisma.salon.findUnique({
    where: { id: idParam(req.params.id) },
    include: withServices,
  });
  if (!salon) throw notFound('This salon no longer exists.');
  res.json(salonJson(salon));
});

salonsRouter.post('/', requireRole(Role.owner, Role.admin), async (req, res) => {
  const body = salonFields.parse(req.body);
  const salon = await prisma.salon.create({
    data: {
      ownerId: await resolveOwnerId(req, body.owner_id),
      name: body.name,
      type: body.type,
      address: body.address,
      phone: body.phone,
      lat: body.lat,
      lon: body.lon,
      timezone: body.timezone,
      openMin: body.open_min,
      closeMin: body.close_min,
      staff: body.staff,
      queue: body.queue ?? 0,
      highlights: body.highlights,
    },
    include: withServices,
  });
  emitSalonChanged(salon);
  res.status(201).json(salonJson(salon));
});

salonsRouter.patch('/:id', async (req, res) => {
  const existing = await loadManagedSalon(req, idParam(req.params.id));
  const body = salonFields.parse(req.body);
  const ownerId =
    currentUser(req).role === Role.admin
      ? await resolveOwnerId(req, body.owner_id === undefined ? existing.ownerId : body.owner_id)
      : existing.ownerId;
  await prisma.salon.update({
    where: { id: existing.id },
    data: {
      ownerId,
      name: body.name,
      type: body.type,
      address: body.address,
      phone: body.phone,
      lat: body.lat,
      lon: body.lon,
      timezone: body.timezone,
      openMin: body.open_min,
      closeMin: body.close_min,
      staff: body.staff,
      ...(body.queue === undefined ? {} : { queue: body.queue }),
      highlights: body.highlights,
    },
  });
  res.json(salonJson((await broadcastSalon(existing.id))!));
});

/** Live queue: how many people are waiting right now. */
salonsRouter.patch('/:id/queue', async (req, res) => {
  const existing = await loadManagedSalon(req, idParam(req.params.id));
  const body = queueBody.parse(req.body);
  await prisma.salon.update({ where: { id: existing.id }, data: { queue: body.queue } });
  res.json(salonJson((await broadcastSalon(existing.id))!));
});

salonsRouter.delete('/:id', async (req, res) => {
  const existing = await loadManagedSalon(req, idParam(req.params.id));
  await prisma.salon.delete({ where: { id: existing.id } });
  emitSalonDeleted(existing.id);
  res.status(204).end();
});

// -------------------------------- Services -----------------------------------

salonsRouter.post('/:id/services', async (req, res) => {
  const salon = await loadManagedSalon(req, idParam(req.params.id));
  const body = serviceFields.parse(req.body);
  const service = await prisma.service.create({ data: { ...body, salonId: salon.id } });
  await broadcastSalon(salon.id);
  res.status(201).json(serviceJson(service));
});

export const servicesRouter = Router();
servicesRouter.use(requireAuth);

async function loadManagedService(req: Express.Request, id: number) {
  const service = await prisma.service.findUnique({ where: { id }, include: { salon: true } });
  if (!service) throw notFound('This service no longer exists.');
  if (!canManageSalon(currentUser(req), service.salon)) throw forbidden();
  return service;
}

servicesRouter.patch('/:id', async (req, res) => {
  const existing = await loadManagedService(req, idParam(req.params.id));
  const body = serviceFields.parse(req.body);
  const service = await prisma.service.update({ where: { id: existing.id }, data: body });
  await broadcastSalon(existing.salonId);
  res.json(serviceJson(service));
});

servicesRouter.delete('/:id', async (req, res) => {
  const existing = await loadManagedService(req, idParam(req.params.id));
  await prisma.service.delete({ where: { id: existing.id } });
  await broadcastSalon(existing.salonId);
  res.status(204).end();
});
