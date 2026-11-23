// Booking rules:
//   - prices and durations come from the database, not from the app
//   - the appointment must start upcoming, within 14 days, on the 30-minute
//     grid, and end by closing time
//   - it sits on one chair and holds every 30-minute block it needs there
//     (booking_slots); the database refuses a block held twice, so two
//     customers can never get the same chair at the same time
//   - it can't start on a chair while a walk-in is still being served there
//   - a customer can't hold two appointments that overlap (at any salon), nor
//     more than MAX_UPCOMING_BOOKINGS upcoming ones
// Online payments hold the blocks as `pending_payment` for 15 minutes.

import { canManageSalon } from '../auth/rbac.js';
import { prisma } from '../db.js';
import type { Chair, Prisma, Salon, User } from '../generated/prisma/client.js';
import { BookingStatus, PaymentMethod, PaymentStatus, TokenStatus } from '../generated/prisma/enums.js';
import { ApiError, badRequest, conflict, forbidden, notFound } from '../lib/errors.js';
import { BOOKING_WINDOW_DAYS, localParts, SLOT_MINUTES, slotsNeeded, zonedInstant } from '../lib/time.js';
import { createOrder, paymentsEnabled } from '../payments/razorpay.js';
import { emitBookingChanged, emitSlotChanged } from '../realtime.js';

export const PAYMENT_HOLD_MS = 15 * 60 * 1000;
export const MAX_UPCOMING_BOOKINGS = 5;
const SLOT_MS = SLOT_MINUTES * 60_000;

const holdCutoff = () => new Date(Date.now() - PAYMENT_HOLD_MS);

/** What every booking response includes. */
export const bookingInclude = {
  salon: { select: { name: true } },
  chair: { select: { name: true } },
} as const;

/** Bookings that occupy their time right now. */
export const activeBookingWhere = () => ({
  OR: [
    { status: BookingStatus.confirmed },
    { status: BookingStatus.pending_payment, createdAt: { gt: holdCutoff() } },
  ],
});

const isUniqueViolation = (error: unknown) =>
  typeof error === 'object' &&
  error !== null &&
  ((error as { code?: string }).code === 'P2002' ||
    String((error as { message?: string }).message).includes('23505'));

/** Start times of the 30-minute blocks an appointment needs. */
const blocksFrom = (start: Date, minutes: number) =>
  Array.from({ length: slotsNeeded(minutes) }, (_, i) => new Date(start.getTime() + i * SLOT_MS));

/** Unpaid holds past 15 minutes stop holding their blocks. */
async function releaseStaleHolds(tx: Prisma.TransactionClient, salonId?: number) {
  const stale = await tx.booking.findMany({
    where: {
      status: BookingStatus.pending_payment,
      createdAt: { lte: holdCutoff() },
      ...(salonId === undefined ? {} : { salonId }),
    },
    select: { id: true },
  });
  if (stale.length === 0) return [];
  const ids = stale.map((b) => b.id);
  await tx.bookingSlot.deleteMany({ where: { bookingId: { in: ids } } });
  await tx.booking.updateMany({
    where: { id: { in: ids }, status: BookingStatus.pending_payment },
    data: { status: BookingStatus.expired },
  });
  return ids;
}

/**
 * Chairs taken by walk-ins right now: a token being served holds its chair
 * until its service should end; one called to a chair holds it from now.
 */
async function walkInHolds(chairIds: number[], now = new Date()) {
  if (chairIds.length === 0) return [];
  const tokens = await prisma.queueToken.findMany({
    where: {
      chairId: { in: chairIds },
      status: { in: [TokenStatus.serving, TokenStatus.called] },
      createdAt: { gt: new Date(now.getTime() - 18 * 3_600_000) },
    },
    select: { chairId: true, minutes: true, startedAt: true },
  });
  return tokens.map((t) => {
    const from = t.startedAt ?? now;
    // Running over: assume a few more minutes.
    const end = Math.max(from.getTime() + t.minutes * 60_000, now.getTime() + 5 * 60_000);
    return { chairId: t.chairId!, end: new Date(end) };
  });
}

const heldByWalkIn = (holds: { chairId: number; end: Date }[], chairId: number, start: Date) =>
  holds.some((h) => h.chairId === chairId && h.end > start);

/**
 * How many upcoming active bookings of a salon would fall outside these
 * opening hours (start before opening or end after closing).
 */
export async function bookingsOutsideHours(salonId: number, openMin: number, closeMin: number, timeZone: string) {
  const upcoming = await prisma.booking.findMany({
    where: { salonId, slotStart: { gte: new Date() }, ...activeBookingWhere() },
    select: { slotStart: true, minutes: true },
  });
  return upcoming.filter((b) => {
    const start = localParts(b.slotStart, timeZone).minuteOfDay;
    return start < openMin || start + slotsNeeded(b.minutes) * SLOT_MINUTES > closeMin;
  }).length;
}

// ------------------------------- Availability --------------------------------

export interface AvailableSlot {
  start: Date;
  /** Chairs free for the whole appointment, in chair order. */
  chairIds: number[];
}

/**
 * Start times on [date] (salon's local calendar day) when an appointment of
 * [minutes] fits, and which chairs are free for all of it. Past times and
 * days outside the booking window give no slots.
 */
export async function availableSlots(
  salon: Salon,
  chairs: Chair[],
  date: string,
  minutes: number,
): Promise<AvailableSlot[]> {
  const need = slotsNeeded(minutes);
  const now = Date.now();
  const starts: Date[] = [];
  for (let m = salon.openMin; m + need * SLOT_MINUTES <= salon.closeMin; m += SLOT_MINUTES) {
    const start = zonedInstant(date, m, salon.timezone);
    if (start.getTime() <= now || start.getTime() > now + BOOKING_WINDOW_DAYS * 86_400_000) continue;
    starts.push(start);
  }
  if (starts.length === 0 || chairs.length === 0) {
    return starts.map((start) => ({ start, chairIds: [] }));
  }

  const held = await prisma.bookingSlot.findMany({
    where: {
      chairId: { in: chairs.map((c) => c.id) },
      slotStart: { gte: starts[0]!, lt: new Date(starts.at(-1)!.getTime() + need * SLOT_MS) },
      booking: activeBookingWhere(),
    },
    select: { chairId: true, slotStart: true },
  });
  const taken = new Set(held.map((h) => `${h.chairId}|${h.slotStart.getTime()}`));
  const holds = await walkInHolds(chairs.map((c) => c.id));

  return starts.map((start) => ({
    start,
    chairIds: chairs
      .filter(
        (chair) =>
          !heldByWalkIn(holds, chair.id, start) &&
          blocksFrom(start, minutes).every((block) => !taken.has(`${chair.id}|${block.getTime()}`)),
      )
      .map((chair) => chair.id),
  }));
}

// --------------------------------- Booking -----------------------------------

export interface NewBooking {
  salonId: number;
  slotStart: Date;
  serviceIds: number[];
  paymentMethod: PaymentMethod;
  /** A particular chair, or any free one when undefined. */
  chairId?: number;
  customerName?: string;
  customerPhone?: string;
  notes?: string;
}

/** A customer can't be in two chairs at once, nor hoard upcoming slots. */
async function checkCustomerFree(user: User, start: Date, minutes: number) {
  const end = start.getTime() + minutes * 60_000;
  const mine = await prisma.booking.findMany({
    where: { customerId: user.id, slotStart: { gte: new Date(Date.now() - 12 * 3_600_000) }, ...activeBookingWhere() },
    include: { salon: { select: { name: true, timezone: true } } },
    orderBy: { slotStart: 'asc' },
  });
  const clash = mine.find(
    (b) => b.slotStart.getTime() < end && b.slotStart.getTime() + b.minutes * 60_000 > start.getTime(),
  );
  if (clash) {
    const at = new Intl.DateTimeFormat('en-IN', {
      timeZone: clash.salon.timezone,
      hour: 'numeric',
      minute: '2-digit',
    }).format(clash.slotStart);
    throw conflict(`You already have an appointment at ${clash.salon.name} at ${at} that overlaps this time.`);
  }
  if (mine.filter((b) => b.slotStart.getTime() > Date.now()).length >= MAX_UPCOMING_BOOKINGS) {
    throw conflict(
      `You can hold up to ${MAX_UPCOMING_BOOKINGS} upcoming appointments. Cancel one to book another.`,
    );
  }
}

export async function createBooking(user: User, input: NewBooking) {
  if (input.paymentMethod === PaymentMethod.online && !paymentsEnabled()) {
    throw new ApiError(503, 'Online payment is not available. Choose pay at the salon.', 'payments_disabled');
  }

  const salon = await prisma.salon.findUnique({
    where: { id: input.salonId },
    include: { chairs: { orderBy: { id: 'asc' } } },
  });
  if (!salon) throw notFound('This salon no longer exists.');

  const serviceIds = [...new Set(input.serviceIds)];
  if (serviceIds.length === 0) throw badRequest('Select at least one service.');
  const services = await prisma.service.findMany({
    where: { salonId: salon.id, id: { in: serviceIds } },
    orderBy: { id: 'asc' },
  });
  if (services.length !== serviceIds.length) {
    throw badRequest('One of the selected services is no longer offered.');
  }
  const minutes = services.reduce((sum, s) => sum + s.minutes, 0);

  const now = Date.now();
  const start = input.slotStart;
  if (start.getTime() <= now || start.getTime() > now + BOOKING_WINDOW_DAYS * 86_400_000) {
    throw badRequest('Pick an upcoming time slot.');
  }
  const local = localParts(start, salon.timezone);
  if (
    start.getUTCMilliseconds() !== 0 ||
    local.second !== 0 ||
    local.minuteOfDay < salon.openMin ||
    (local.minuteOfDay - salon.openMin) % SLOT_MINUTES !== 0
  ) {
    throw badRequest("That time is outside the salon's opening hours.");
  }
  if (local.minuteOfDay + slotsNeeded(minutes) * SLOT_MINUTES > salon.closeMin) {
    throw badRequest('These services take too long to finish before closing. Pick an earlier time.');
  }

  if (salon.chairs.length === 0) {
    throw conflict('This salon is not taking bookings right now.');
  }
  if (input.chairId !== undefined && !salon.chairs.some((c) => c.id === input.chairId)) {
    throw badRequest('That chair is not at this salon.');
  }
  await checkCustomerFree(user, start, minutes);

  const holds = await walkInHolds(salon.chairs.map((c) => c.id));
  const candidates = (
    input.chairId === undefined ? salon.chairs : salon.chairs.filter((c) => c.id === input.chairId)
  ).filter((c) => !heldByWalkIn(holds, c.id, start));
  const blocks = blocksFrom(start, minutes);
  const online = input.paymentMethod === PaymentMethod.online;

  // Two customers can pick the same chair at once: the database lets one
  // through and the other tries the next free chair.
  let booking;
  for (let attempt = 0; attempt < 4 && !booking; attempt++) {
    try {
      booking = await prisma.$transaction(async (tx) => {
        await releaseStaleHolds(tx, salon.id);
        const held = await tx.bookingSlot.findMany({
          where: { chairId: { in: candidates.map((c) => c.id) }, slotStart: { in: blocks } },
          select: { chairId: true },
        });
        const busy = new Set(held.map((h) => h.chairId));
        const chair = candidates.find((c) => !busy.has(c.id));
        if (!chair) {
          throw conflict(
            input.chairId === undefined
              ? 'Sorry, that time was just booked. Pick another time.'
              : 'That chair is booked or still serving a walk-in then. Pick another time or any chair.',
          );
        }

        const created = await tx.booking.create({
          data: {
            salonId: salon.id,
            chairId: chair.id,
            customerId: user.id,
            customerEmail: user.email,
            customerName: input.customerName ?? user.fullName ?? '',
            customerPhone: input.customerPhone ?? '',
            notes: input.notes ?? '',
            slotStart: start,
            services: services.map((s) => ({ name: s.name, price: s.price, minutes: s.minutes })),
            total: services.reduce((sum, s) => sum + s.price, 0),
            minutes,
            status: online ? BookingStatus.pending_payment : BookingStatus.confirmed,
            paymentMethod: input.paymentMethod,
          },
        });
        await tx.bookingSlot.createMany({
          data: blocks.map((slotStart) => ({ chairId: chair.id, slotStart, bookingId: created.id })),
        });
        return tx.booking.findUniqueOrThrow({ where: { id: created.id }, include: bookingInclude });
      });
    } catch (error) {
      if (!isUniqueViolation(error)) throw error;
    }
  }
  if (!booking) throw conflict('Sorry, that time was just booked. Pick another time.');

  let order;
  if (online) {
    try {
      order = await createOrder(booking.id, booking.total);
    } catch (error) {
      console.error('Creating the Razorpay order failed:', error);
      await prisma.booking.delete({ where: { id: booking.id } });
      throw new ApiError(502, 'Could not start the payment. Please try again.', 'payment_failed');
    }
    booking = await prisma.booking.update({
      where: { id: booking.id },
      data: { razorpayOrderId: order.id },
      include: bookingInclude,
    });
  }

  emitSlotChanged(booking.salonId, booking.slotStart, true);
  emitBookingChanged(booking);
  return { booking, order };
}

/**
 * Customers cancel their own upcoming bookings; owners cancel their salon's;
 * admins cancel any.
 */
export async function cancelBooking(user: User, bookingId: string) {
  const booking = await prisma.booking.findUnique({
    where: { id: bookingId },
    include: { salon: true },
  });
  if (!booking) throw notFound('Booking not found.');

  const allowed =
    canManageSalon(user, booking.salon) ||
    (booking.customerId === user.id && booking.slotStart > new Date());
  if (!allowed) throw forbidden('You cannot cancel this booking.');

  if (booking.status !== BookingStatus.confirmed && booking.status !== BookingStatus.pending_payment) {
    throw conflict('This booking is not active.');
  }

  const [, updated] = await prisma.$transaction([
    prisma.bookingSlot.deleteMany({ where: { bookingId: booking.id } }), // frees the chair
    prisma.booking.update({
      where: { id: booking.id },
      data: {
        status: BookingStatus.cancelled,
        // Paid online: an admin refunds it from the Razorpay dashboard.
        ...(booking.paymentStatus === PaymentStatus.paid ? { paymentStatus: PaymentStatus.refund_due } : {}),
      },
      include: bookingInclude,
    }),
  ]);
  emitSlotChanged(updated.salonId, updated.slotStart, false);
  emitBookingChanged(updated);
  return updated;
}

/** Marks a paid order's booking confirmed. Safe to call more than once. */
export async function confirmPayment(orderId: string, paymentId: string) {
  const booking = await prisma.booking.findUnique({ where: { razorpayOrderId: orderId } });
  if (!booking) throw notFound('Booking not found for this payment.');
  if (booking.paymentStatus !== PaymentStatus.unpaid) {
    return prisma.booking.findUniqueOrThrow({ where: { id: booking.id }, include: bookingInclude });
  }

  // Paid after the hold ran out or after a cancel: the chair may already be
  // someone else's, so keep the money flagged for a refund instead.
  const stillHeld = booking.status === BookingStatus.pending_payment;
  const updated = await prisma.booking.update({
    where: { id: booking.id },
    data: {
      status: stillHeld ? BookingStatus.confirmed : booking.status,
      paymentStatus: stillHeld ? PaymentStatus.paid : PaymentStatus.refund_due,
      razorpayPaymentId: paymentId,
    },
    include: bookingInclude,
  });
  emitBookingChanged(updated);
  return updated;
}

/** Releases unpaid holds older than 15 minutes. Runs every minute. */
export async function expireStaleHolds() {
  const ids = await prisma.$transaction((tx) => releaseStaleHolds(tx));
  if (ids.length === 0) return;
  const expired = await prisma.booking.findMany({ where: { id: { in: ids } }, include: bookingInclude });
  for (const booking of expired) {
    emitSlotChanged(booking.salonId, booking.slotStart, false);
    emitBookingChanged(booking);
  }
}
