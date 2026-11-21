// Booking rules, ported from the Supabase `create_booking` and
// `cancel_booking` functions:
//   - prices and durations come from the database, not from the app
//   - the slot must be upcoming, within 14 days and inside opening hours
//   - a slot holds at most one booking (unique salon_id + active_slot)
// Online payments hold the slot as `pending_payment` for 15 minutes.

import { canManageSalon } from '../auth/rbac.js';
import { prisma } from '../db.js';
import type { User } from '../generated/prisma/client.js';
import { BookingStatus, PaymentMethod, PaymentStatus } from '../generated/prisma/enums.js';
import { ApiError, badRequest, conflict, forbidden, notFound } from '../lib/errors.js';
import { BOOKING_WINDOW_DAYS, localParts, SLOT_MINUTES } from '../lib/time.js';
import { createOrder, paymentsEnabled } from '../payments/razorpay.js';
import { emitBookingChanged, emitSlotChanged } from '../realtime.js';

export const PAYMENT_HOLD_MS = 15 * 60 * 1000;

const holdCutoff = () => new Date(Date.now() - PAYMENT_HOLD_MS);

/** Bookings that occupy their slot right now. */
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

export interface NewBooking {
  salonId: number;
  slotStart: Date;
  serviceIds: number[];
  paymentMethod: PaymentMethod;
}

export async function createBooking(user: User, input: NewBooking) {
  if (input.paymentMethod === PaymentMethod.online && !paymentsEnabled()) {
    throw new ApiError(503, 'Online payment is not available. Choose pay at the salon.', 'payments_disabled');
  }

  const salon = await prisma.salon.findUnique({ where: { id: input.salonId } });
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
    local.minuteOfDay + SLOT_MINUTES > salon.closeMin ||
    (local.minuteOfDay - salon.openMin) % SLOT_MINUTES !== 0
  ) {
    throw badRequest("That time is outside the salon's opening hours.");
  }

  const online = input.paymentMethod === PaymentMethod.online;
  let booking;
  try {
    booking = await prisma.$transaction(async (tx) => {
      // An unpaid hold older than 15 minutes no longer blocks the slot.
      await tx.booking.updateMany({
        where: {
          salonId: salon.id,
          slotStart: start,
          status: BookingStatus.pending_payment,
          createdAt: { lte: holdCutoff() },
        },
        data: { status: BookingStatus.expired, activeSlot: null },
      });
      return tx.booking.create({
        data: {
          salonId: salon.id,
          customerId: user.id,
          customerEmail: user.email,
          slotStart: start,
          activeSlot: start, // unique per salon: a second booking fails here

          services: services.map((s) => ({ name: s.name, price: s.price, minutes: s.minutes })),
          total: services.reduce((sum, s) => sum + s.price, 0),
          minutes: services.reduce((sum, s) => sum + s.minutes, 0),
          status: online ? BookingStatus.pending_payment : BookingStatus.confirmed,
          paymentMethod: input.paymentMethod,
        },
        include: { salon: { select: { name: true } } },
      });
    });
  } catch (error) {
    if (isUniqueViolation(error)) throw conflict('Sorry, that slot was just booked. Pick another time.');
    throw error;
  }

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
      include: { salon: { select: { name: true } } },
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

  const updated = await prisma.booking.update({
    where: { id: booking.id },
    data: {
      status: BookingStatus.cancelled,
      activeSlot: null, // frees the slot
      // Paid online: an admin refunds it from the Razorpay dashboard.
      ...(booking.paymentStatus === PaymentStatus.paid ? { paymentStatus: PaymentStatus.refund_due } : {}),
    },
    include: { salon: { select: { name: true } } },
  });
  emitSlotChanged(updated.salonId, updated.slotStart, false);
  emitBookingChanged(updated);
  return updated;
}

/** Marks a paid order's booking confirmed. Safe to call more than once. */
export async function confirmPayment(orderId: string, paymentId: string) {
  const booking = await prisma.booking.findUnique({ where: { razorpayOrderId: orderId } });
  if (!booking) throw notFound('Booking not found for this payment.');
  if (booking.paymentStatus !== PaymentStatus.unpaid) {
    return prisma.booking.findUniqueOrThrow({
      where: { id: booking.id },
      include: { salon: { select: { name: true } } },
    });
  }

  let status: BookingStatus = BookingStatus.confirmed;
  let paymentStatus: PaymentStatus = PaymentStatus.paid;
  if (booking.status !== BookingStatus.pending_payment) {
    // Paid after the hold ran out or after a cancel: keep the money flagged
    // for a refund rather than double-booking the slot.
    status = booking.status;
    paymentStatus = PaymentStatus.refund_due;
  }

  let updated;
  try {
    updated = await prisma.booking.update({
      where: { id: booking.id },
      data: { status, paymentStatus, razorpayPaymentId: paymentId },
      include: { salon: { select: { name: true } } },
    });
  } catch (error) {
    if (!isUniqueViolation(error)) throw error;
    updated = await prisma.booking.update({
      where: { id: booking.id },
      data: { paymentStatus: PaymentStatus.refund_due, razorpayPaymentId: paymentId },
      include: { salon: { select: { name: true } } },
    });
  }
  emitBookingChanged(updated);
  return updated;
}

/** Releases unpaid holds older than 15 minutes. Runs every minute. */
export async function expireStaleHolds() {
  const stale = await prisma.booking.findMany({
    where: { status: BookingStatus.pending_payment, createdAt: { lte: holdCutoff() } },
    include: { salon: { select: { name: true } } },
  });
  for (const booking of stale) {
    const { count } = await prisma.booking.updateMany({
      where: { id: booking.id, status: BookingStatus.pending_payment },
      data: { status: BookingStatus.expired, activeSlot: null },
    });
    if (count === 1) {
      emitSlotChanged(booking.salonId, booking.slotStart, false);
      emitBookingChanged({ ...booking, status: BookingStatus.expired });
    }
  }
}

