// Walk-in queue tokens.
//
// Rules:
//   - tokens are numbered 1, 2, 3... per salon per day (salon's time zone)
//   - a customer holds at most one active token, in any salon (also enforced
//     by a unique index)
//   - tokens are taken only while the salon is open, with a working chair,
//     and only if the queue would be served before closing time
//   - a token is started on a chair that is not on break, not serving
//     someone else, and has no appointment that the service would run into
//   - staff call, start, finish or mark tokens as no-shows; customers cancel
//     their own

import { canManageSalon } from '../auth/rbac.js';
import { prisma } from '../db.js';
import type { QueueToken, User } from '../generated/prisma/client.js';
import { ChairStatus, TokenStatus } from '../generated/prisma/enums.js';
import { activeBookingWhere } from '../bookings/service.js';
import { broadcastSalon } from '../salons/routes.js';
import { estimateQueue } from './estimate.js';
import { ApiError, badRequest, conflict, forbidden, notFound } from '../lib/errors.js';
import { emitQueueChanged, emitTokenChanged } from '../realtime.js';
import { ACTIVE_TOKEN, isOpenAt, loadLiveOne, type SalonWithDetails, todayAt, typicalMinutes } from './live.js';

const salonDetails = {
  services: { orderBy: { id: 'asc' as const } },
  chairs: { orderBy: { id: 'asc' as const } },
};
const tokenInclude = { chair: { select: { name: true } }, salon: { select: { name: true } } } as const;

/** Active tokens left over from an earlier day are closed. */
const STALE_TOKEN_MS = 18 * 3_600_000;

const isUniqueViolation = (error: unknown) =>
  typeof error === 'object' &&
  error !== null &&
  ((error as { code?: string }).code === 'P2002' ||
    String((error as { message?: string }).message).includes('23505'));

/** Closes active tokens older than a day: nobody is still waiting on them. */
export async function closeStaleTokens(where: { customerId?: string } = {}) {
  const cutoff = new Date(Date.now() - STALE_TOKEN_MS);
  const now = new Date();
  await prisma.$transaction([
    prisma.queueToken.updateMany({
      where: { ...where, createdAt: { lt: cutoff }, status: { in: [TokenStatus.waiting, TokenStatus.called] } },
      data: { status: TokenStatus.no_show, finishedAt: now },
    }),
    prisma.queueToken.updateMany({
      where: { ...where, createdAt: { lt: cutoff }, status: TokenStatus.serving },
      data: { status: TokenStatus.done, finishedAt: now },
    }),
  ]);
}

async function loadSalon(salonId: number) {
  const salon = await prisma.salon.findUnique({ where: { id: salonId }, include: salonDetails });
  if (!salon) throw notFound('This salon no longer exists.');
  return salon;
}

/** Tells everyone the queue changed, and the token's customer about their token. */
async function announce(token: QueueToken) {
  const full = await prisma.queueToken.findUnique({ where: { id: token.id }, include: tokenInclude });
  if (full) emitTokenChanged(full);
  emitQueueChanged(token.salonId);
  // Salon cards show the queue length and wait.
  await broadcastSalon(token.salonId);
}

// ---------------------------------- Joining ----------------------------------

export interface JoinRequest {
  serviceIds?: number[];
  /** Staff adding a walk-in may give a length instead of services. */
  minutes?: number;
  customerName?: string;
  customerPhone?: string;
}

/**
 * Takes the next token. [customer] is the signed-in customer taking it in
 * the app, or null when staff add someone at the door.
 */
export async function joinQueue(salonId: number, customer: User | null, request: JoinRequest) {
  const salon = await loadSalon(salonId);
  const now = new Date();

  if (!isOpenAt(salon, now)) throw conflict('The salon is closed right now. The queue opens when it does.');
  if (!salon.chairs.some((c) => c.status !== ChairStatus.on_break)) {
    throw conflict('Every chair is on break right now. Try again in a little while.');
  }

  const { services, minutes } = await pickServices(salon, request);
  const name = (request.customerName ?? customer?.fullName ?? '').trim();
  if (!customer && !name) throw badRequest('Enter a name to call the walk-in by.');

  if (customer) {
    await closeStaleTokens({ customerId: customer.id });
    await checkNoActiveToken(prisma, customer.id);
    await checkNoAppointmentSoon(customer, now, minutes);
  }

  // Would this person be served before closing?
  const live = await loadLiveOne(salon, now);
  const fit = estimateQueue(live.input, minutes).nextStart;
  if (fit && fit.getTime() + minutes * 60_000 > live.closesAt.getTime()) {
    throw conflict(
      'The queue is full for today: this service would run past closing time. Book an appointment for another day instead.',
    );
  }

  const day = todayAt(salon, now);
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const token = await prisma.$transaction(async (tx) => {
        // One join at a time per customer and per salon, so two taps can't
        // both pass the checks and numbers are handed out in order. (Always
        // customer first, then salon, so two joins never wait on each other.)
        if (customer) {
          await tx.$queryRaw`SELECT pg_advisory_xact_lock(hashtext(${'queue-user:' + customer.id}))::text`;
          await checkNoActiveToken(tx, customer.id);
        }
        await tx.$queryRaw`SELECT pg_advisory_xact_lock(hashtext(${'queue-salon:' + salonId}))::text`;
        const last = await tx.queueToken.aggregate({ where: { salonId, day }, _max: { number: true } });
        return tx.queueToken.create({
          data: {
            salonId,
            day,
            number: (last._max.number ?? 0) + 1,
            customerId: customer?.id ?? null,
            customerName: name,
            customerPhone: (request.customerPhone ?? '').trim(),
            services,
            minutes,
          },
          include: tokenInclude,
        });
      });
      await announce(token);
      return describeToken(token.id);
    } catch (error) {
      // The locks make this rare; the unique indexes are the last line of
      // defence (one active token per customer, one number per salon-day).
      if (!isUniqueViolation(error)) throw error;
      if (customer) await checkNoActiveToken(prisma, customer.id);
    }
  }
  throw conflict('The queue is very busy right now. Please try again.');
}

async function checkNoActiveToken(db: Pick<typeof prisma, 'queueToken'>, customerId: string) {
  const existing = await db.queueToken.findFirst({
    where: { customerId, status: { in: ACTIVE_TOKEN } },
    include: { salon: { select: { name: true } } },
  });
  if (existing) {
    throw conflict(`You already have token #${existing.number} at ${existing.salon.name}. Cancel it to take another.`);
  }
}

async function pickServices(salon: SalonWithDetails, request: JoinRequest) {
  const ids = [...new Set(request.serviceIds ?? [])];
  if (ids.length > 0) {
    const chosen = salon.services.filter((s) => ids.includes(s.id));
    if (chosen.length !== ids.length) throw badRequest('One of the selected services is no longer offered.');
    return {
      services: chosen.map((s) => ({ name: s.name, price: s.price, minutes: s.minutes })),
      minutes: Math.min(600, Math.max(5, chosen.reduce((sum, s) => sum + s.minutes, 0))),
    };
  }
  return { services: [], minutes: request.minutes ?? typicalMinutes(salon.services) };
}

/** A customer with an appointment starting soon shouldn't also queue. */
async function checkNoAppointmentSoon(customer: User, now: Date, minutes: number) {
  const soon = await prisma.booking.findFirst({
    where: {
      customerId: customer.id,
      slotStart: { gte: now, lt: new Date(now.getTime() + Math.max(minutes, 60) * 60_000) },
      ...activeBookingWhere(),
    },
    include: { salon: { select: { name: true } } },
  });
  if (soon) {
    throw conflict(
      `You have an appointment at ${soon.salon.name} within the hour. Cancel it first if you want to queue instead.`,
    );
  }
}

// ------------------------------ Reading tokens --------------------------------

/** A token with its place in the queue and estimated start. */
export async function describeToken(tokenId: string) {
  const token = await prisma.queueToken.findUnique({ where: { id: tokenId }, include: tokenInclude });
  if (!token) throw notFound('Token not found.');
  if (!ACTIVE_TOKEN.includes(token.status)) return { token, estimatedStart: undefined, ahead: undefined };
  const salon = await loadSalon(token.salonId);
  const live = await loadLiveOne(salon);
  const ahead = live.tokens.filter((t) => t.number < token.number && t.status !== TokenStatus.serving).length;
  return { token, estimatedStart: live.estimate.starts.get(token.id), ahead };
}

// --------------------------------- Actions -----------------------------------

export type TokenAction = 'call' | 'start' | 'done' | 'no_show' | 'cancel';

export interface ActionOptions {
  chairId?: number;
  /** Start even though an appointment is due on that chair soon. */
  force?: boolean;
}

export async function tokenAction(user: User, tokenId: string, action: TokenAction, options: ActionOptions = {}) {
  const token = await prisma.queueToken.findUnique({ where: { id: tokenId }, include: { salon: true } });
  if (!token) throw notFound('Token not found.');
  const staff = canManageSalon(user, token.salon);
  const own = token.customerId === user.id;
  if (action === 'cancel' ? !staff && !own : !staff) throw forbidden();

  const now = new Date();
  const from = (...allowed: TokenStatus[]) => {
    if (!allowed.includes(token.status)) {
      throw conflict(`Token #${token.number} is ${token.status.replace('_', ' ')}, so it can't be ${verb(action)}.`);
    }
  };

  let updated: QueueToken;
  switch (action) {
    case 'call': {
      from(TokenStatus.waiting, TokenStatus.called);
      const chair = options.chairId === undefined ? null : await usableChair(token.salonId, options.chairId);
      updated = await prisma.queueToken.update({
        where: { id: token.id },
        data: { status: TokenStatus.called, calledAt: now, chairId: chair?.id ?? token.chairId },
      });
      break;
    }
    case 'start': {
      from(TokenStatus.waiting, TokenStatus.called);
      const chairId = options.chairId ?? token.chairId ?? (await firstFreeChair(token.salonId));
      if (chairId === null) throw conflict('No chair is free. Pick a chair, or finish someone first.');
      const chair = await usableChair(token.salonId, chairId);
      const serving = await prisma.queueToken.findFirst({
        where: { chairId: chair.id, status: TokenStatus.serving, id: { not: token.id } },
      });
      if (serving) throw conflict(`${chair.name} is still serving #${serving.number}. Finish it first.`);
      if (!options.force) await checkNoAppointmentInWay(chair.id, chair.name, now, token.minutes);
      [updated] = await prisma.$transaction([
        prisma.queueToken.update({
          where: { id: token.id },
          data: { status: TokenStatus.serving, chairId: chair.id, startedAt: now, calledAt: token.calledAt ?? now },
        }),
        prisma.chair.update({ where: { id: chair.id }, data: { status: ChairStatus.busy, statusSince: now } }),
      ]);
      break;
    }
    case 'done': {
      from(TokenStatus.serving);
      [updated] = await prisma.$transaction([
        prisma.queueToken.update({
          where: { id: token.id },
          data: { status: TokenStatus.done, finishedAt: now },
        }),
        ...(token.chairId === null
          ? []
          : [
              prisma.chair.updateMany({
                where: { id: token.chairId, status: ChairStatus.busy },
                data: { status: ChairStatus.free, statusSince: now },
              }),
            ]),
      ]);
      break;
    }
    case 'no_show':
    case 'cancel': {
      from(TokenStatus.waiting, TokenStatus.called);
      updated = await prisma.queueToken.update({
        where: { id: token.id },
        data: { status: action === 'cancel' ? TokenStatus.cancelled : TokenStatus.no_show, finishedAt: now },
      });
      break;
    }
  }
  await announce(updated);
  return describeToken(updated.id);
}

const verb = (action: TokenAction) =>
  ({ call: 'called', start: 'started', done: 'finished', no_show: 'marked as a no-show', cancel: 'cancelled' })[action];

async function usableChair(salonId: number, chairId: number) {
  const chair = await prisma.chair.findUnique({ where: { id: chairId } });
  if (!chair || chair.salonId !== salonId) throw badRequest('That chair is not at this salon.');
  if (chair.status === ChairStatus.on_break) throw conflict(`${chair.name} is on break.`);
  return chair;
}

async function firstFreeChair(salonId: number) {
  const chairs = await prisma.chair.findMany({
    where: { salonId, status: ChairStatus.free },
    orderBy: { id: 'asc' },
  });
  for (const chair of chairs) {
    const serving = await prisma.queueToken.count({ where: { chairId: chair.id, status: TokenStatus.serving } });
    if (serving === 0) return chair.id;
  }
  return null;
}

/** A walk-in must not run into an appointment booked on the same chair. */
async function checkNoAppointmentInWay(chairId: number, chairName: string, now: Date, minutes: number) {
  const end = new Date(now.getTime() + minutes * 60_000);
  const bookings = await prisma.booking.findMany({
    where: {
      chairId,
      slotStart: { gte: new Date(now.getTime() - 10 * 3_600_000), lt: end },
      ...activeBookingWhere(),
    },
    orderBy: { slotStart: 'asc' },
  });
  const clash = bookings.find((b) => b.slotStart.getTime() + b.minutes * 60_000 > now.getTime());
  if (clash) {
    const inMin = Math.max(0, Math.round((clash.slotStart.getTime() - now.getTime()) / 60_000));
    // A distinct code so the app can offer "start anyway" (force).
    throw new ApiError(
      409,
      inMin === 0
        ? `${chairName} has an appointment right now. Use another chair.`
        : `${chairName} has an appointment in ${inMin} min, and this service takes ${minutes} min. Use another chair.`,
      'appointment_clash',
    );
  }
}
