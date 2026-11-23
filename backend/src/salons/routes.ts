import { Router } from 'express';
import { z } from 'zod';

import { canManageSalon, currentUser, requireAuth, requireRole } from '../auth/rbac.js';
import { prisma } from '../db.js';
import { ChairStatus, Role } from '../generated/prisma/enums.js';
import { activeBookingWhere, availableSlots, bookingsOutsideHours } from '../bookings/service.js';
import { loadLive, loadLiveOne, type SalonWithDetails } from '../queue/live.js';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.js';
import { chairJson, serviceJson, salonJson } from '../lib/serialize.js';
import { isValidTimeZone, SLOT_MINUTES } from '../lib/time.js';
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
    highlights: z.array(z.string().trim().min(1).max(40)).max(12).default([]),
  })
  .refine((salon) => salon.close_min > salon.open_min, {
    message: 'Closing time must be after opening time.',
    path: ['close_min'],
  });

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

const salonDetails = {
  services: { orderBy: { id: 'asc' as const } },
  chairs: { orderBy: { id: 'asc' as const } },
};

const MAX_CHAIRS = 50;

const chairName = z.string().trim().min(1).max(40);
const newChair = z.object({ name: chairName.optional() });
const chairUpdate = z
  .object({ name: chairName.optional(), status: z.enum(ChairStatus).optional() })
  .refine((body) => body.name !== undefined || body.status !== undefined, {
    message: 'Send a name or a status.',
  });

async function loadManagedSalon(req: Express.Request, id: number) {
  const salon = await prisma.salon.findUnique({ where: { id } });
  if (!salon) throw notFound('This salon no longer exists.');
  if (!canManageSalon(currentUser(req), salon)) throw forbidden();
  return salon;
}

/** Salons as JSON with their live queue and wait estimate. */
async function salonsJson(salons: SalonWithDetails[]) {
  const live = await loadLive(salons);
  return salons.map((salon) => salonJson(salon, live.get(salon.id)));
}

/** Sends a salon's current state to every client and returns it as JSON. */
export async function broadcastSalon(id: number) {
  const salon = await prisma.salon.findUnique({ where: { id }, include: salonDetails });
  if (!salon) return null;
  const live = await loadLiveOne(salon);
  emitSalonChanged(salon, live);
  return salonJson(salon, live);
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

salonsRouter.get('/', async (_req, res) => {
  const salons = await prisma.salon.findMany({ include: salonDetails, orderBy: { id: 'asc' } });
  res.json(await salonsJson(salons));
});

/** Salons this user may manage: every salon for admins, owned ones for owners. */
salonsRouter.get('/managed', requireAuth, requireRole(Role.owner, Role.admin), async (req, res) => {
  const user = currentUser(req);
  const salons = await prisma.salon.findMany({
    where: user.role === Role.admin ? {} : { ownerId: user.id },
    include: salonDetails,
    orderBy: { name: 'asc' },
  });
  res.json(await salonsJson(salons));
});

salonsRouter.get('/:id', async (req, res) => {
  const salon = await prisma.salon.findUnique({
    where: { id: idParam(req.params.id) },
    include: salonDetails,
  });
  if (!salon) throw notFound('This salon no longer exists.');
  res.json(salonJson(salon, await loadLiveOne(salon)));
});

const availabilityQuery = z.object({
  date: z.iso.date(),
  minutes: z.coerce.number().int().min(5).max(600).default(SLOT_MINUTES),
});

/**
 * Bookable start times on one day for an appointment of [minutes], with the
 * chairs free for all of it. Public: shows times, never who booked.
 */
salonsRouter.get('/:id/availability', async (req, res) => {
  const salon = await prisma.salon.findUnique({
    where: { id: idParam(req.params.id) },
    include: { chairs: { orderBy: { id: 'asc' } } },
  });
  if (!salon) throw notFound('This salon no longer exists.');
  const query = availabilityQuery.parse(req.query);
  const slots = await availableSlots(salon, salon.chairs, query.date, query.minutes);
  res.json({
    date: query.date,
    timezone: salon.timezone,
    minutes: query.minutes,
    slot_minutes: SLOT_MINUTES,
    slots: slots.map((slot) => ({ start: slot.start.toISOString(), chair_ids: slot.chairIds })),
  });
});

salonsRouter.post('/', requireAuth, requireRole(Role.owner, Role.admin), async (req, res) => {
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
      highlights: body.highlights,
      // One chair per stylist to start with; owners rename or add more.
      chairs: {
        create: Array.from({ length: Math.min(body.staff, MAX_CHAIRS) }, (_, i) => ({
          name: `Chair ${i + 1}`,
        })),
      },
    },
    include: salonDetails,
  });
  const live = await loadLiveOne(salon);
  emitSalonChanged(salon, live);
  res.status(201).json(salonJson(salon, live));
});

salonsRouter.patch('/:id', requireAuth, async (req, res) => {
  const existing = await loadManagedSalon(req, idParam(req.params.id));
  const body = salonFields.parse(req.body);
  const ownerId =
    currentUser(req).role === Role.admin
      ? await resolveOwnerId(req, body.owner_id === undefined ? existing.ownerId : body.owner_id)
      : existing.ownerId;
  // Customers already booked must still fit inside the new hours.
  if (
    body.open_min !== existing.openMin ||
    body.close_min !== existing.closeMin ||
    body.timezone !== existing.timezone
  ) {
    const stranded = await bookingsOutsideHours(existing.id, body.open_min, body.close_min, body.timezone);
    if (stranded > 0) {
      throw conflict(
        `${stranded} upcoming ${stranded === 1 ? 'appointment falls' : 'appointments fall'} outside the new ` +
          'opening hours. Cancel or move them first, or keep the current hours.',
      );
    }
  }
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
      highlights: body.highlights,
    },
  });
  res.json(await broadcastSalon(existing.id));
});

salonsRouter.delete('/:id', requireAuth, async (req, res) => {
  const existing = await loadManagedSalon(req, idParam(req.params.id));
  await prisma.salon.delete({ where: { id: existing.id } });
  emitSalonDeleted(existing.id);
  res.status(204).end();
});

// -------------------------------- Services -----------------------------------

salonsRouter.post('/:id/services', requireAuth, async (req, res) => {
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

// --------------------------------- Chairs ------------------------------------
// Each change is pushed to every client as `salon:changed`, so customers see
// which chairs are free as soon as staff update them.

salonsRouter.post('/:id/chairs', requireAuth, async (req, res) => {
  const salon = await loadManagedSalon(req, idParam(req.params.id));
  const body = newChair.parse(req.body ?? {});
  const count = await prisma.chair.count({ where: { salonId: salon.id } });
  if (count >= MAX_CHAIRS) throw badRequest(`A salon can have at most ${MAX_CHAIRS} chairs.`);
  const chair = await prisma.chair.create({
    data: { salonId: salon.id, name: body.name ?? `Chair ${count + 1}` },
  });
  await broadcastSalon(salon.id);
  res.status(201).json(chairJson(chair));
});

export const chairsRouter = Router();
chairsRouter.use(requireAuth);

async function loadManagedChair(req: Express.Request, id: number) {
  const chair = await prisma.chair.findUnique({ where: { id }, include: { salon: true } });
  if (!chair) throw notFound('This chair no longer exists.');
  if (!canManageSalon(currentUser(req), chair.salon)) throw forbidden();
  return chair;
}

/** Rename a chair or set its status (free, busy or on_break). */
chairsRouter.patch('/:id', async (req, res) => {
  const existing = await loadManagedChair(req, idParam(req.params.id));
  const body = chairUpdate.parse(req.body);
  const statusChanged = body.status !== undefined && body.status !== existing.status;
  const chair = await prisma.chair.update({
    where: { id: existing.id },
    data: {
      ...(body.name === undefined ? {} : { name: body.name }),
      ...(statusChanged ? { status: body.status, statusSince: new Date() } : {}),
    },
  });
  await broadcastSalon(existing.salonId);
  res.json(chairJson(chair));
});

chairsRouter.delete('/:id', async (req, res) => {
  const existing = await loadManagedChair(req, idParam(req.params.id));
  const upcoming = await prisma.booking.count({
    where: {
      chairId: existing.id,
      slotStart: { gte: new Date() },
      ...activeBookingWhere(),
    },
  });
  if (upcoming > 0) {
    throw conflict(
      `${existing.name} has ${upcoming} upcoming ${upcoming === 1 ? 'appointment' : 'appointments'}. ` +
        'Cancel them first, or set the chair on break instead.',
    );
  }
  await prisma.chair.delete({ where: { id: existing.id } });
  await broadcastSalon(existing.salonId);
  res.status(204).end();
});
