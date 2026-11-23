// The test salon is open around the clock (UTC), so the queue is always open.
// (The "runs past closing" rule could refuse a token in the last half hour
// before midnight UTC; those tests set their own hours.)

import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { prisma } from '../src/db.js';
import { Role } from '../src/generated/prisma/enums.js';
import { closeStaleTokens } from '../src/queue/service.js';
import { app, auth, createSalon, signUp, tomorrowAt } from './helpers.js';

async function setup(chairs = 2) {
  const owner = await signUp('o@example.com', Role.owner);
  const salon = await createSalon(owner, chairs);
  return { owner, salon };
}

describe('taking a token', () => {
  it('numbers tokens 1, 2, 3 and estimates each one', async () => {
    const { owner, salon } = await setup(1);
    const a = await signUp('a@example.com');
    const b = await signUp('b@example.com');

    const first = await request(app)
      .post(`/salons/${salon.id}/queue`)
      .set(auth(a))
      .send({ service_ids: [salon.services[0]!.id], customer_name: 'Asha' })
      .expect(201);
    expect(first.body).toMatchObject({
      number: 1,
      status: 'waiting',
      customer_name: 'Asha',
      minutes: 30,
      ahead: 0,
      walk_in: false,
    });
    const second = await request(app).post(`/salons/${salon.id}/queue`).set(auth(b)).send({}).expect(201);
    const walkIn = await request(app)
      .post(`/salons/${salon.id}/queue/walk-in`)
      .set(auth(owner))
      .send({ customer_name: 'Man at the door', minutes: 20 })
      .expect(201);
    expect(second.body).toMatchObject({ number: 2, ahead: 1 });
    expect(walkIn.body).toMatchObject({ number: 3, ahead: 2, walk_in: true, minutes: 20 });

    // One chair: #1 now, #2 after 30 min, #3 after that.
    const startOf = (t: { estimated_start: string }) => new Date(t.estimated_start).getTime();
    const mins = (ms: number) => Math.round(ms / 60_000);
    const view = await request(app).get(`/salons/${salon.id}/queue`).expect(200);
    expect(view.body.waiting).toBe(3);
    expect(view.body.queue.map((t: { number: number }) => t.number)).toEqual([1, 2, 3]);
    const [s1, s2, s3] = view.body.queue.map(startOf);
    expect(mins(s2 - s1)).toBe(30);
    expect(mins(s3 - s2)).toBeGreaterThanOrEqual(22); // second customer's typical service (22.5 rounded)

    // The public view never shows names.
    expect(JSON.stringify(view.body)).not.toContain('Asha');
    expect(JSON.stringify(view.body)).not.toContain('door');
  });

  it('a customer holds one active token at a time, anywhere', async () => {
    const { salon } = await setup();
    const other = await createSalon();
    const a = await signUp('a@example.com');
    await request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}).expect(201);
    const res = await request(app).post(`/salons/${other.id}/queue`).set(auth(a)).send({}).expect(409);
    expect(res.body.error).toMatch(/already have token #1/);
  });

  it('two taps at once give one token', async () => {
    const { salon } = await setup();
    const a = await signUp('a@example.com');
    const results = await Promise.all([
      request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}),
      request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual([201, 409]);
    expect(await prisma.queueToken.count()).toBe(1);
  });

  it('many customers at once all get different numbers', async () => {
    const { salon } = await setup();
    const users = await Promise.all(['a', 'b', 'c', 'd'].map((n) => signUp(`${n}@example.com`)));
    const results = await Promise.all(
      users.map((u) => request(app).post(`/salons/${salon.id}/queue`).set(auth(u)).send({})),
    );
    expect(results.map((r) => r.status)).toEqual([201, 201, 201, 201]);
    expect(results.map((r) => r.body.number).sort()).toEqual([1, 2, 3, 4]);
  });

  it('is refused when closed, when every chair is on break, or when the queue would run past closing', async () => {
    const { salon } = await setup(1);
    const a = await signUp('a@example.com');
    const join = () => request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({});

    await prisma.chair.updateMany({ where: { salonId: salon.id }, data: { status: 'on_break' } });
    expect((await join().expect(409)).body.error).toMatch(/on break/);
    await prisma.chair.updateMany({ where: { salonId: salon.id }, data: { status: 'free' } });

    // Closes in 20 minutes: a 30-minute service can't be finished.
    const nowMin = new Date().getUTCHours() * 60 + new Date().getUTCMinutes();
    await prisma.salon.update({
      where: { id: salon.id },
      data: { openMin: Math.max(0, nowMin - 60), closeMin: nowMin + 20 },
    });
    expect((await join().expect(409)).body.error).toMatch(/run past closing/);

    // Closed right now.
    await prisma.salon.update({
      where: { id: salon.id },
      data: { openMin: (nowMin + 120) % 1300, closeMin: ((nowMin + 120) % 1300) + 60 },
    });
    expect((await join().expect(409)).body.error).toMatch(/closed/);
  });

  it("can't queue with an appointment starting within the hour", async () => {
    const { salon } = await setup();
    const a = await signUp('a@example.com');
    // The next half-hour slot: always 1-30 minutes away.
    const soon = new Date(Date.now() + 60_000);
    soon.setUTCMinutes(soon.getUTCMinutes() < 30 ? 30 : 60, 0, 0);
    await request(app)
      .post('/bookings')
      .set(auth(a))
      .send({ salon_id: salon.id, slot_start: soon.toISOString(), service_ids: [salon.services[0]!.id] })
      .expect(201);
    const res = await request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}).expect(409);
    expect(res.body.error).toMatch(/appointment .* within the hour/);
  });
});

describe('serving the queue', () => {
  it('call, start and finish a token; the chair follows', async () => {
    const { owner, salon } = await setup();
    const a = await signUp('a@example.com');
    const token = (await request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}).expect(201)).body;
    const chair = salon.chairs[1]!;

    const called = await request(app)
      .post(`/queue/${token.id}/call`)
      .set(auth(owner))
      .send({ chair_id: chair.id })
      .expect(200);
    expect(called.body).toMatchObject({ status: 'called', chair_id: chair.id, chair_name: 'Chair 2' });

    const started = await request(app).post(`/queue/${token.id}/start`).set(auth(owner)).send({}).expect(200);
    expect(started.body).toMatchObject({ status: 'serving', chair_id: chair.id });
    expect((await prisma.chair.findUniqueOrThrow({ where: { id: chair.id } })).status).toBe('busy');
    const salonView = await request(app).get(`/salons/${salon.id}`).expect(200);
    expect(salonView.body).toMatchObject({ queue: 0, now_serving: [1] });

    const done = await request(app).post(`/queue/${token.id}/done`).set(auth(owner)).send({}).expect(200);
    expect(done.body.status).toBe('done');
    expect((await prisma.chair.findUniqueOrThrow({ where: { id: chair.id } })).status).toBe('free');

    // Finished tokens can't be started again.
    const again = await request(app).post(`/queue/${token.id}/start`).set(auth(owner)).send({}).expect(409);
    expect(again.body.error).toMatch(/#1 is done/);
  });

  it("won't start someone on a chair that is busy, on break or has an appointment coming", async () => {
    const { owner, salon } = await setup(2);
    const [a, b, c] = await Promise.all(['a', 'b', 'c'].map((n) => signUp(`${n}@example.com`)));
    const take = async (u: typeof a) =>
      (await request(app).post(`/salons/${salon.id}/queue`).set(auth(u)).send({}).expect(201)).body;
    const [t1, t2] = [await take(a), await take(b)];
    const [chair1, chair2] = salon.chairs;

    await request(app).post(`/queue/${t1.id}/start`).set(auth(owner)).send({ chair_id: chair1!.id }).expect(200);
    const busy = await request(app)
      .post(`/queue/${t2.id}/start`)
      .set(auth(owner))
      .send({ chair_id: chair1!.id })
      .expect(409);
    expect(busy.body.error).toMatch(/still serving #1/);

    await prisma.chair.update({ where: { id: chair2!.id }, data: { status: 'on_break' } });
    const onBreak = await request(app)
      .post(`/queue/${t2.id}/start`)
      .set(auth(owner))
      .send({ chair_id: chair2!.id })
      .expect(409);
    expect(onBreak.body.error).toMatch(/on break/);
    await prisma.chair.update({ where: { id: chair2!.id }, data: { status: 'free' } });

    // An appointment on chair 2 in 15 minutes: a 30-minute walk-in would run into it.
    const soon = new Date(Date.now() + 15 * 60_000);
    const booking = await prisma.booking.create({
      data: {
        salonId: salon.id,
        chairId: chair2!.id,
        customerId: c.id,
        slotStart: soon,
        total: 300,
        minutes: 30,
      },
    });
    const clash = await request(app)
      .post(`/queue/${t2.id}/start`)
      .set(auth(owner))
      .send({ chair_id: chair2!.id })
      .expect(409);
    expect(clash.body).toMatchObject({ code: 'appointment_clash' });
    expect(clash.body.error).toMatch(/appointment in 1[45] min/);
    // Staff can still go ahead on purpose.
    await request(app)
      .post(`/queue/${t2.id}/start`)
      .set(auth(owner))
      .send({ chair_id: chair2!.id, force: true })
      .expect(200);
    await prisma.booking.delete({ where: { id: booking.id } });
  });

  it('customers cancel their own token; only staff serve tokens', async () => {
    const { owner, salon } = await setup();
    const a = await signUp('a@example.com');
    const stranger = await signUp('s@example.com');
    const token = (await request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}).expect(201)).body;

    await request(app).post(`/queue/${token.id}/start`).set(auth(a)).send({}).expect(403);
    await request(app).post(`/queue/${token.id}/cancel`).set(auth(stranger)).send({}).expect(403);
    await request(app).post(`/queue/${token.id}/explode`).set(auth(owner)).send({}).expect(404);

    const mine = await request(app).get('/queue/mine').set(auth(a)).expect(200);
    expect(mine.body).toHaveLength(1);
    expect(mine.body[0]).toMatchObject({ number: 1, salon_name: 'Test Salon', ahead: 0 });

    await request(app).post(`/queue/${token.id}/cancel`).set(auth(a)).send({}).expect(200);
    expect((await request(app).get('/queue/mine').set(auth(a)).expect(200)).body).toEqual([]);
    // Cancelled: can take a new one.
    await request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}).expect(201);
  });

  it('staff see names in the manage view, with no-shows', async () => {
    const { owner, salon } = await setup();
    const a = await signUp('a@example.com');
    const t = (await request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({ customer_name: 'Asha' }).expect(201)).body;
    await request(app).post(`/salons/${salon.id}/queue/walk-in`).set(auth(owner)).send({ customer_name: 'Ravi' }).expect(201);
    await request(app).post(`/queue/${t.id}/no_show`).set(auth(owner)).send({}).expect(200);

    const res = await request(app).get(`/salons/${salon.id}/queue/manage`).set(auth(owner)).expect(200);
    expect(res.body.tokens.map((x: { customer_name: string; status: string }) => [x.customer_name, x.status])).toEqual([
      ['Asha', 'no_show'],
      ['Ravi', 'waiting'],
    ]);
    expect(res.body.waiting).toBe(1);
  });

  it('closes tokens left over from yesterday', async () => {
    const { salon } = await setup();
    const a = await signUp('a@example.com');
    const t = (await request(app).post(`/salons/${salon.id}/queue`).set(auth(a)).send({}).expect(201)).body;
    await prisma.queueToken.update({ where: { id: t.id }, data: { createdAt: new Date(Date.now() - 20 * 3_600_000) } });
    await closeStaleTokens();
    expect((await prisma.queueToken.findUniqueOrThrow({ where: { id: t.id } })).status).toBe('no_show');
  });
});

describe('booking conflicts', () => {
  it("a customer can't book two appointments that overlap, at any salon", async () => {
    const a = await signUp('a@example.com');
    const one = await createSalon();
    const two = await createSalon();
    const both = one.services.map((s) => s.id); // 45 minutes
    await request(app)
      .post('/bookings')
      .set(auth(a))
      .send({ salon_id: one.id, slot_start: tomorrowAt(10), service_ids: both })
      .expect(201);
    const clash = await request(app)
      .post('/bookings')
      .set(auth(a))
      .send({
        salon_id: two.id,
        slot_start: tomorrowAt(10).replace('T10:00', 'T10:30'),
        service_ids: [two.services[0]!.id],
      })
      .expect(409);
    expect(clash.body.error).toMatch(/already have an appointment at Test Salon/);
    await request(app)
      .post('/bookings')
      .set(auth(a))
      .send({ salon_id: two.id, slot_start: tomorrowAt(11), service_ids: [two.services[0]!.id] })
      .expect(201);
  });

  it('a customer can hold at most 5 upcoming appointments', async () => {
    const a = await signUp('a@example.com');
    const salon = await createSalon();
    const book = (hour: number) =>
      request(app)
        .post('/bookings')
        .set(auth(a))
        .send({ salon_id: salon.id, slot_start: tomorrowAt(hour), service_ids: [salon.services[0]!.id] });
    for (const hour of [8, 9, 10, 11, 12]) await book(hour).expect(201);
    expect((await book(13).expect(409)).body.error).toMatch(/up to 5 upcoming/);
  });

  it("an appointment can't start on a chair still serving a walk-in", async () => {
    const { owner, salon } = await setup(1);
    const a = await signUp('a@example.com');
    const b = await signUp('b@example.com');
    const t = (
      await request(app)
        .post(`/salons/${salon.id}/queue`)
        .set(auth(a))
        .send({ service_ids: [salon.services[0]!.id] }) // a 30-minute haircut
        .expect(201)
    ).body;
    await request(app).post(`/queue/${t.id}/start`).set(auth(owner)).send({}).expect(200);

    // The walk-in has the only chair for the next 30 minutes.
    const next = new Date(Date.now() + 60_000);
    next.setUTCMinutes(next.getUTCMinutes() < 30 ? 30 : 60, 0, 0);
    const minutesAway = (next.getTime() - Date.now()) / 60_000;
    const res = await request(app)
      .post('/bookings')
      .set(auth(b))
      .send({ salon_id: salon.id, slot_start: next.toISOString(), service_ids: [salon.services[0]!.id] });
    if (minutesAway < 29) {
      expect(res.status).toBe(409);
      const date = next.toISOString().slice(0, 10);
      const avail = await request(app).get(`/salons/${salon.id}/availability`).query({ date }).expect(200);
      const slot = avail.body.slots.find((s: { start: string }) => s.start === next.toISOString());
      expect(slot.chair_ids).toEqual([]);
    } else if (minutesAway > 31) {
      expect(res.status).toBe(201); // the walk-in will be done by then
    }
  });

  it("opening hours can't change to leave booked customers outside them", async () => {
    const { owner, salon } = await setup();
    const a = await signUp('a@example.com');
    await request(app)
      .post('/bookings')
      .set(auth(a))
      .send({ salon_id: salon.id, slot_start: tomorrowAt(19), service_ids: [salon.services[0]!.id] })
      .expect(201);
    const fields = { name: 'Test Salon', lat: 28.6, lon: 77.2, timezone: 'UTC', open_min: 540, staff: 2 };
    const res = await request(app)
      .patch(`/salons/${salon.id}`)
      .set(auth(owner))
      .send({ ...fields, close_min: 1080 }) // closes 18:00, appointment at 19:00
      .expect(409);
    expect(res.body.error).toMatch(/1 upcoming appointment falls outside/);
    await request(app)
      .patch(`/salons/${salon.id}`)
      .set(auth(owner))
      .send({ ...fields, close_min: 1260 })
      .expect(200);
  });
});
