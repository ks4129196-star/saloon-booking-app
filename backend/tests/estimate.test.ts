import { describe, expect, it } from 'vitest';

import { type EstimateChair, type EstimateInput, estimateQueue } from '../src/queue/estimate.js';

const now = new Date('2026-11-22T10:00:00Z');
const at = (hhmm: string) => new Date(`2026-11-22T${hhmm}:00Z`);
const minutesFromNow = (d: Date | null | undefined) => (d ? (d.getTime() - now.getTime()) / 60_000 : null);

const chair = (id: number, status: EstimateChair['status'] = 'free', since = at('09:00')): EstimateChair => ({
  id,
  status,
  statusSince: since,
});

const input = (over: Partial<EstimateInput>): EstimateInput => ({
  now,
  chairs: [chair(1), chair(2)],
  bookings: [],
  tokens: [],
  typicalMinutes: 30,
  ...over,
});

const waiting = (id: string, minutes = 30) => ({
  id,
  status: 'waiting' as const,
  chairId: null,
  minutes,
  startedAt: null,
});

describe('waiting-time estimate', () => {
  it('no wait when a chair is free and nobody queues', () => {
    expect(estimateQueue(input({})).waitMinutes).toBe(0);
  });

  it('shares the queue between working chairs', () => {
    const e = estimateQueue(input({ tokens: [waiting('a'), waiting('b'), waiting('c')] }));
    expect(minutesFromNow(e.starts.get('a'))).toBe(0);
    expect(minutesFromNow(e.starts.get('b'))).toBe(0); // second chair
    expect(minutesFromNow(e.starts.get('c'))).toBe(30);
    expect(e.waitMinutes).toBe(30); // the next person shares the 10:30 turn
  });

  it('counts the time left on someone being served', () => {
    const e = estimateQueue(
      input({
        chairs: [chair(1, 'busy')],
        tokens: [
          { id: 's', status: 'serving', chairId: 1, minutes: 45, startedAt: at('09:30') },
          waiting('a', 20),
        ],
      }),
    );
    expect(minutesFromNow(e.starts.get('a'))).toBe(15); // 09:30 + 45 = 10:15
    expect(e.waitMinutes).toBe(35);
  });

  it('assumes a few more minutes for someone running over', () => {
    const e = estimateQueue(
      input({
        chairs: [chair(1, 'busy')],
        tokens: [{ id: 's', status: 'serving', chairId: 1, minutes: 30, startedAt: at('09:00') }],
      }),
    );
    expect(e.waitMinutes).toBe(5);
  });

  it('a chair marked busy without a token frees after a typical service', () => {
    const e = estimateQueue(input({ chairs: [chair(1, 'busy', at('09:50'))] }));
    expect(e.waitMinutes).toBe(20); // 09:50 + 30
  });

  it('ignores chairs on break, and pauses when all are', () => {
    const one = estimateQueue(input({ chairs: [chair(1, 'on_break'), chair(2)], tokens: [waiting('a')] }));
    expect(one.waitMinutes).toBe(30);

    const none = estimateQueue(input({ chairs: [chair(1, 'on_break')] }));
    expect(none).toMatchObject({ paused: true, waitMinutes: null, nextStart: null });
  });

  it('never runs a walk-in into a booked appointment', () => {
    // Chair 1 has an appointment 10:20-11:00: a 30-minute walk-in doesn't fit
    // before it. Chair 2 is busy until 10:40.
    const e = estimateQueue(
      input({
        chairs: [chair(1), chair(2, 'busy', at('10:10'))],
        bookings: [{ chairId: 1, start: at('10:20'), end: at('11:00') }],
        tokens: [waiting('a')],
      }),
    );
    expect(minutesFromNow(e.starts.get('a'))).toBe(40); // chair 2 at 10:40
    expect(e.waitMinutes).toBe(60); // next: chair 1 after the appointment

    // A 15-minute service fits before the appointment.
    const short = estimateQueue(
      input({
        chairs: [chair(1)],
        bookings: [{ chairId: 1, start: at('10:20'), end: at('11:00') }],
        tokens: [waiting('a', 15)],
      }),
    );
    expect(minutesFromNow(short.starts.get('a'))).toBe(0);
  });

  it('a chair in an appointment frees when it ends', () => {
    const e = estimateQueue(
      input({
        chairs: [chair(1, 'busy')],
        bookings: [{ chairId: 1, start: at('09:30'), end: at('10:25') }],
      }),
    );
    expect(e.waitMinutes).toBe(25);
  });

  it('a called token goes to its chair before anyone waiting', () => {
    const e = estimateQueue(
      input({
        chairs: [chair(1)],
        tokens: [waiting('a'), { id: 'c', status: 'called', chairId: 1, minutes: 20, startedAt: null }],
      }),
    );
    expect(minutesFromNow(e.starts.get('c'))).toBe(0);
    expect(minutesFromNow(e.starts.get('a'))).toBe(20);
  });

  it('estimates a longer service for someone joining', () => {
    const base = input({ chairs: [chair(1)], bookings: [{ chairId: 1, start: at('10:45'), end: at('11:30') }] });
    expect(estimateQueue(base, 30).waitMinutes).toBe(0);
    expect(estimateQueue(base, 60).waitMinutes).toBe(90); // only after the appointment
  });
});
