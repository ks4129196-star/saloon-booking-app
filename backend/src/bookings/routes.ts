import { Router } from 'express';
import { z } from 'zod';

import { canManageSalon, currentUser, requireAuth } from '../auth/rbac.js';
import { config } from '../config.js';
import { prisma } from '../db.js';
import { PaymentMethod } from '../generated/prisma/enums.js';
import { badRequest, forbidden, notFound } from '../lib/errors.js';
import { bookingJson } from '../lib/serialize.js';
import { activeBookingWhere, bookingInclude, cancelBooking, createBooking } from './service.js';

const newBooking = z.object({
  salon_id: z.number().int().positive(),
  slot_start: z.iso.datetime({ offset: true }),
  service_ids: z.array(z.number().int().positive()).min(1, 'Select at least one service.').max(20),
  payment_method: z.enum(PaymentMethod).default(PaymentMethod.salon),
  chair_id: z.number().int().positive().nullish(),
  customer_name: z.string().trim().max(80).optional(),
  customer_phone: z
    .string()
    .trim()
    .max(30)
    .regex(/^[0-9+()\- ]*$/, 'Enter a valid phone number.')
    .optional(),
  notes: z.string().trim().max(500).optional(),
});

const range = z.object({
  from: z.iso.datetime({ offset: true }),
  to: z.iso.datetime({ offset: true }),
  salon_id: z.coerce.number().int().positive().optional(),
});

const since = z.object({
  from: z.iso.datetime({ offset: true }),
  to: z.iso.datetime({ offset: true }).optional(),
});

export const bookingsRouter = Router();

/**
 * 30-minute slots in which every chair of a salon is booked. Times only,
 * never who booked them.
 */
bookingsRouter.get('/taken-slots', async (req, res) => {
  const query = range.parse(req.query);
  const from = new Date(query.from);
  const to = new Date(query.to);
  if (to <= from || to.getTime() - from.getTime() > 15 * 86_400_000) {
    throw badRequest('Pick a range of at most 15 days.');
  }
  const salonFilter = query.salon_id ? { salonId: query.salon_id } : {};
  const [rows, chairCounts] = await Promise.all([
    prisma.bookingSlot.findMany({
      where: {
        slotStart: { gte: from, lt: to },
        booking: { ...activeBookingWhere(), ...salonFilter },
      },
      select: { slotStart: true, booking: { select: { salonId: true } } },
    }),
    prisma.chair.groupBy({ by: ['salonId'], where: salonFilter, _count: { _all: true } }),
  ]);
  const chairs = new Map(chairCounts.map((c) => [c.salonId, c._count._all]));
  const held = new Map<string, { salonId: number; slotStart: Date; count: number }>();
  for (const row of rows) {
    const key = `${row.booking.salonId}|${row.slotStart.getTime()}`;
    const entry = held.get(key) ?? { salonId: row.booking.salonId, slotStart: row.slotStart, count: 0 };
    entry.count++;
    held.set(key, entry);
  }
  res.json(
    [...held.values()]
      .filter((entry) => entry.count >= (chairs.get(entry.salonId) ?? 0))
      .sort((a, b) => a.slotStart.getTime() - b.slotStart.getTime() || a.salonId - b.salonId)
      .map((entry) => ({ salon_id: entry.salonId, slot_start: entry.slotStart.toISOString() })),
  );
});

bookingsRouter.post('/', requireAuth, async (req, res) => {
  const body = newBooking.parse(req.body);
  const user = currentUser(req);
  const { booking, order } = await createBooking(user, {
    salonId: body.salon_id,
    slotStart: new Date(body.slot_start),
    serviceIds: body.service_ids,
    paymentMethod: body.payment_method,
    chairId: body.chair_id ?? undefined,
    customerName: body.customer_name,
    customerPhone: body.customer_phone,
    notes: body.notes,
  });
  res.status(201).json({
    booking: bookingJson(booking),
    // Everything the app needs to open Razorpay Checkout.
    payment: order
      ? {
          key_id: config.razorpay!.keyId,
          order_id: order.id,
          amount: order.amount,
          currency: order.currency,
          name: booking.salon.name,
          prefill_email: user.email,
        }
      : null,
  });
});

bookingsRouter.get('/mine', requireAuth, async (req, res) => {
  const bookings = await prisma.booking.findMany({
    where: { customerId: currentUser(req).id },
    include: bookingInclude,
    orderBy: { slotStart: 'desc' },
    take: 100,
  });
  res.json(bookings.map(bookingJson));
});

bookingsRouter.post('/:id/cancel', requireAuth, async (req, res) => {
  const id = z.uuid().safeParse(req.params.id);
  if (!id.success) throw notFound('Booking not found.');
  res.json(bookingJson(await cancelBooking(currentUser(req), id.data)));
});

/** A salon's bookings from [from] (until [to]). Owner of that salon or admin. */
export const salonBookingsRouter = Router({ mergeParams: true });
salonBookingsRouter.use(requireAuth);

salonBookingsRouter.get('/', async (req, res) => {
  const salonId = Number((req.params as { id?: string }).id);
  const salon = Number.isInteger(salonId) ? await prisma.salon.findUnique({ where: { id: salonId } }) : null;
  if (!salon) throw notFound('This salon no longer exists.');
  if (!canManageSalon(currentUser(req), salon)) throw forbidden();

  const query = since.parse(req.query);
  const bookings = await prisma.booking.findMany({
    where: {
      salonId,
      slotStart: { gte: new Date(query.from), ...(query.to ? { lt: new Date(query.to) } : {}) },
    },
    include: bookingInclude,
    orderBy: { slotStart: 'asc' },
    take: 500,
  });
  res.json(bookings.map(bookingJson));
});
