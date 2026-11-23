// Waiting-time estimates for the walk-in queue.
//
// A small simulation of the salon's chairs:
//   1. When will each working chair be free? A chair serving a token frees up
//      when that service should end; one in a booked appointment when the
//      appointment ends; one marked busy without either after a typical
//      service. Chairs on break take nobody.
//   2. Tokens already called to a chair go there next.
//   3. Waiting tokens, in number order, each take whichever chair can start
//      them first, skipping round booked appointments (a walk-in never runs
//      into an appointment).
// The start times found are the estimates. A new walk-in's wait is the same
// calculation for one more token at the end of the queue.

const MINUTE = 60_000;

/** Someone overrunning their service is assumed to finish within this. */
export const OVERRUN_GRACE_MIN = 5;

export type ChairState = 'free' | 'busy' | 'on_break';
export type ActiveTokenStatus = 'waiting' | 'called' | 'serving';

export interface EstimateChair {
  id: number;
  status: ChairState;
  statusSince: Date;
}

export interface EstimateBooking {
  chairId: number;
  start: Date;
  end: Date;
}

export interface EstimateToken {
  id: string;
  status: ActiveTokenStatus;
  chairId: number | null;
  minutes: number;
  startedAt: Date | null;
}

export interface EstimateInput {
  now: Date;
  chairs: EstimateChair[];
  bookings: EstimateBooking[];
  /** Active tokens, in queue order (by number). */
  tokens: EstimateToken[];
  /** Length of a typical service here, for unknown customers. */
  typicalMinutes: number;
}

export interface Estimate {
  /** Every chair is on break: nobody is being served. */
  paused: boolean;
  /** Expected start time of each waiting or called token, by id. */
  starts: Map<string, Date>;
  /** Expected start for someone joining now with a typical service. */
  nextStart: Date | null;
  /** Minutes until [nextStart], or null when paused. */
  waitMinutes: number | null;
}

/** Earliest time from [from] that [minutes] fit on a chair without running into an appointment. */
function earliestFit(from: Date, minutes: number, bookings: EstimateBooking[]): Date {
  let start = from.getTime();
  const length = minutes * MINUTE;
  for (let moved = true; moved; ) {
    moved = false;
    for (const b of bookings) {
      if (start < b.end.getTime() && start + length > b.start.getTime()) {
        start = b.end.getTime();
        moved = true;
      }
    }
  }
  return new Date(start);
}

/**
 * Runs the simulation. [joinMinutes] is the service length of a person
 * joining now (defaults to a typical service), for [Estimate.nextStart].
 */
export function estimateQueue(input: EstimateInput, joinMinutes = input.typicalMinutes): Estimate {
  const now = input.now.getTime();
  const working = input.chairs.filter((c) => c.status !== 'on_break');
  if (working.length === 0) {
    return { paused: true, starts: new Map(), nextStart: null, waitMinutes: null };
  }

  const bookingsOf = new Map<number, EstimateBooking[]>();
  for (const b of input.bookings) {
    if (b.end.getTime() <= now) continue;
    const list = bookingsOf.get(b.chairId) ?? [];
    list.push(b);
    bookingsOf.set(b.chairId, list);
  }

  // 1. When each working chair is next free.
  const freeAt = new Map<number, number>();
  for (const chair of working) {
    const serving = input.tokens.find((t) => t.status === 'serving' && t.chairId === chair.id);
    const inAppointment = (bookingsOf.get(chair.id) ?? []).find(
      (b) => b.start.getTime() <= now && b.end.getTime() > now,
    );
    let at = now;
    if (serving) {
      const end = (serving.startedAt?.getTime() ?? now) + serving.minutes * MINUTE;
      at = Math.max(end, now + (end <= now ? OVERRUN_GRACE_MIN * MINUTE : 0));
    } else if (inAppointment) {
      at = inAppointment.end.getTime();
    } else if (chair.status === 'busy') {
      at = Math.max(
        chair.statusSince.getTime() + input.typicalMinutes * MINUTE,
        now + OVERRUN_GRACE_MIN * MINUTE,
      );
    }
    freeAt.set(chair.id, at);
  }

  const starts = new Map<string, Date>();
  const place = (chairId: number, minutes: number) => {
    const start = earliestFit(new Date(freeAt.get(chairId)!), minutes, bookingsOf.get(chairId) ?? []);
    freeAt.set(chairId, start.getTime() + minutes * MINUTE);
    return start;
  };
  const best = (minutes: number) => {
    let chosen: { chairId: number; start: Date } | null = null;
    for (const chair of working) {
      const start = earliestFit(
        new Date(freeAt.get(chair.id)!),
        minutes,
        bookingsOf.get(chair.id) ?? [],
      );
      if (!chosen || start < chosen.start) chosen = { chairId: chair.id, start };
    }
    return chosen!;
  };

  // 2. Called tokens go to their chair next (or the first chair free).
  for (const token of input.tokens) {
    if (token.status !== 'called') continue;
    const chairId = token.chairId !== null && freeAt.has(token.chairId) ? token.chairId : best(token.minutes).chairId;
    starts.set(token.id, place(chairId, token.minutes));
  }

  // 3. Waiting tokens, in order, each to the chair that can start them first.
  for (const token of input.tokens) {
    if (token.status !== 'waiting') continue;
    starts.set(token.id, place(best(token.minutes).chairId, token.minutes));
  }

  const next = best(joinMinutes).start;
  return {
    paused: false,
    starts,
    nextStart: next,
    waitMinutes: Math.max(0, Math.ceil((next.getTime() - now) / MINUTE)),
  };
}
