// A salon's live queue state: today's active tokens and the waiting-time
// estimate. Loaded for many salons at once with a few queries.

import { prisma } from '../db.js';
import type { Chair, QueueToken, Salon, Service } from '../generated/prisma/client.js';
import { TokenStatus } from '../generated/prisma/enums.js';
import { activeBookingWhere } from '../bookings/service.js';
import { localDate, localParts, zonedInstant } from '../lib/time.js';
import { type Estimate, type EstimateInput, estimateQueue } from './estimate.js';

export const ACTIVE_TOKEN: TokenStatus[] = [TokenStatus.waiting, TokenStatus.called, TokenStatus.serving];

export type LiveToken = QueueToken & { chair: { name: string } | null };

export interface LiveInfo {
  /** The salon's calendar day now, e.g. "2026-11-22". */
  day: string;
  open: boolean;
  closesAt: Date;
  /** Waiting or called: people still to be served. */
  waiting: number;
  /** Today's waiting, called and serving tokens, in number order. */
  tokens: LiveToken[];
  estimate: Estimate;
  /** What [estimate] was worked out from, to try other service lengths. */
  input: EstimateInput;
}

export type SalonWithDetails = Salon & { chairs: Chair[]; services: Service[] };

export const todayAt = (salon: Salon, now = new Date()) => localDate(now, salon.timezone);

export function isOpenAt(salon: Salon, now = new Date()) {
  const minute = localParts(now, salon.timezone).minuteOfDay;
  return minute >= salon.openMin && minute < salon.closeMin;
}

export function typicalMinutes(services: Service[]) {
  if (services.length === 0) return 30;
  return Math.max(5, Math.round(services.reduce((sum, s) => sum + s.minutes, 0) / services.length));
}

export async function loadLive(salons: SalonWithDetails[], now = new Date()): Promise<Map<number, LiveInfo>> {
  const out = new Map<number, LiveInfo>();
  if (salons.length === 0) return out;
  const ids = salons.map((s) => s.id);

  const [tokens, bookings] = await Promise.all([
    prisma.queueToken.findMany({
      where: { salonId: { in: ids }, status: { in: ACTIVE_TOKEN } },
      include: { chair: { select: { name: true } } },
      orderBy: [{ salonId: 'asc' }, { number: 'asc' }],
    }),
    prisma.booking.findMany({
      where: {
        salonId: { in: ids },
        chairId: { not: null },
        slotStart: { gte: new Date(now.getTime() - 12 * 3_600_000), lt: new Date(now.getTime() + 24 * 3_600_000) },
        ...activeBookingWhere(),
      },
      select: { salonId: true, chairId: true, slotStart: true, minutes: true },
    }),
  ]);

  for (const salon of salons) {
    const day = todayAt(salon, now);
    const own = tokens.filter((t) => t.salonId === salon.id && t.day === day);
    const input: EstimateInput = {
      now,
      chairs: salon.chairs.map((c) => ({ id: c.id, status: c.status, statusSince: c.statusSince })),
      bookings: bookings
        .filter((b) => b.salonId === salon.id)
        .map((b) => ({
          chairId: b.chairId!,
          start: b.slotStart,
          end: new Date(b.slotStart.getTime() + b.minutes * 60_000),
        })),
      tokens: own.map((t) => ({
        id: t.id,
        status: t.status as 'waiting' | 'called' | 'serving',
        chairId: t.chairId,
        minutes: t.minutes,
        startedAt: t.startedAt,
      })),
      typicalMinutes: typicalMinutes(salon.services),
    };
    const estimate = estimateQueue(input);
    out.set(salon.id, {
      day,
      open: isOpenAt(salon, now),
      closesAt: zonedInstant(day, salon.closeMin, salon.timezone),
      waiting: own.filter((t) => t.status !== TokenStatus.serving).length,
      tokens: own,
      estimate,
      input,
    });
  }
  return out;
}

export async function loadLiveOne(salon: SalonWithDetails, now = new Date()) {
  return (await loadLive([salon], now)).get(salon.id)!;
}
