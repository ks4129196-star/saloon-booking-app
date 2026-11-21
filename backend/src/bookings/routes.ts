import { Router } from 'express';
import { z } from 'zod';

import { canManageSalon, currentUser, requireAuth } from '../auth/rbac.js';
import { config } from '../config.js';
import { prisma } from '../db.js';
import { PaymentMethod } from '../generated/prisma/enums.js';
import { badRequest, forbidden, notFound } from '../lib/errors.js';
import { bookingJson } from '../lib/serialize.js';
import { activeBookingWhere, cancelBooking, createBooking } from './service.js';

const newBooking = z.object({
  salon_id: z.number().int().positive(),
  slot_start: z.iso.datetime({ offset: true }),
  service_ids: z.array(z.number().int().positive()).min(1, 'Select at least one service.').max(20),
  payment_method: z.enum(PaymentMethod).default(PaymentMethod.salon),
});

const range = z.object({
  from: z.iso.datetime({ offset: true }),
  to: z.iso.datetime({ offset: true }),
  salon_id: z.coerce.number().int().positive().optional(),
});

const since = z.object({ from: z.iso.datetime({ offset: true }) });

const withSalonName = { salon: { select: { name: true } } };

export const bookingsRouter = Router();
bookingsRouter.use(requireAuth);

/** Booked slot times only, never who booked them. */
bookingsRouter.get('/taken-slots', async (req, res) => {
  const query = range.parse(req.query);
  const from = new Date(query.from);
  const to = new Date(query.to);
  if (to <= from || to.getTime() - from.getTime() > 15 * 86_400_000) {
    throw badRequest('Pick a range of at most 15 days.');
  }
  const rows = await prisma.booking.findMany({
    where: {
      ...activeBookingWhere(),
      slotStart: { gte: from, lt: to },
      ...(query.salon_id ? { salonId: query.salon_id } : {}),
    },
    select: { salonId: true, slotStart: true },
  });
  res.json(rows.map((row) => ({ salon_id: row.salonId, slot_start: row.slotStart.toISOString() })));
});

bookingsRouter.post('/', async (req, res) => {
  const body = newBooking.parse(req.body);
  const user = currentUser(req);
  const { booking, order } = await createBooking(user, {
    salonId: body.salon_id,
    slotStart: new Date(body.slot_start),
    serviceIds: body.service_ids,
    paymentMethod: body.payment_method,
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

bookingsRouter.get('/mine', async (req, res) => {
  const bookings = await prisma.booking.findMany({
    where: { customerId: currentUser(req).id },
    include: withSalonName,
    orderBy: { slotStart: 'desc' },
    take: 100,
  });
  res.json(bookings.map(bookingJson));
});

bookingsRouter.post('/:id/cancel', async (req, res) => {
  const id = z.uuid().safeParse(req.params.id);
  if (!id.success) throw notFound('Booking not found.');
  res.json(bookingJson(await cancelBooking(currentUser(req), id.data)));
});

/** A salon's bookings from [from] onwards. Owner of that salon or admin. */
export const salonBookingsRouter = Router({ mergeParams: true });
salonBookingsRouter.use(requireAuth);

salonBookingsRouter.get('/', async (req, res) => {
  const salonId = Number((req.params as { id?: string }).id);
  const salon = Number.isInteger(salonId) ? await prisma.salon.findUnique({ where: { id: salonId } }) : null;
  if (!salon) throw notFound('This salon no longer exists.');
  if (!canManageSalon(currentUser(req), salon)) throw forbidden();

  const query = since.parse(req.query);
  const bookings = await prisma.booking.findMany({
    where: { salonId, slotStart: { gte: new Date(query.from) } },
    include: withSalonName,
    orderBy: { slotStart: 'asc' },
    take: 200,
  });
  res.json(bookings.map(bookingJson));
});
