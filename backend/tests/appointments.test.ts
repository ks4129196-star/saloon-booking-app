import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { prisma } from '../src/db.js';
import { Role } from '../src/generated/prisma/enums.js';
import { app, auth, createSalon, signUp, tomorrowAt } from './helpers.js';

const tomorrow = () => tomorrowAt(0).slice(0, 10);
const at = (hour: number, minute = 0) =>
  tomorrowAt(hour).replace(`T${String(hour).padStart(2, '0')}:00`, `T${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`);

describe('appointments on chairs', () => {
  it('a time can be booked once per chair', async () => {
    const [a, b, c] = await Promise.all(['a', 'b', 'c'].map((n) => signUp(`${n}@example.com`)));
    const salon = await createSalon(null, 2);
    const body = { salon_id: salon.id, slot_start: tomorrowAt(10), service_ids: [salon.services[0]!.id] };

    const first = await request(app).post('/bookings').set(auth(a)).send(body).expect(201);
    const second = await request(app).post('/bookings').set(auth(b)).send(body).expect(201);
    expect([first.body.booking.chair_id, second.body.booking.chair_id].sort()).toEqual(
      salon.chairs.map((ch) => ch.id).sort(),
    );
    await request(app).post('/bookings').set(auth(c)).send(body).expect(409);
  });

  it('two customers booking at once both get a chair when two are free', async () => {
    const [a, b] = await Promise.all(['a', 'b'].map((n) => signUp(`${n}@example.com`)));
    const salon = await createSalon(null, 2);
    const body = { salon_id: salon.id, slot_start: tomorrowAt(11), service_ids: [salon.services[0]!.id] };
    const results = await Promise.all([
      request(app).post('/bookings').set(auth(a)).send(body),
      request(app).post('/bookings').set(auth(b)).send(body),
    ]);
    expect(results.map((r) => r.status)).toEqual([201, 201]);
    expect(new Set(results.map((r) => r.body.booking.chair_id)).size).toBe(2);
  });

  it('a customer can pick a chair', async () => {
    const [a, b] = await Promise.all(['a', 'b'].map((n) => signUp(`${n}@example.com`)));
    const salon = await createSalon(null, 2);
    const second = salon.chairs[1]!;
    const body = {
      salon_id: salon.id,
      slot_start: tomorrowAt(12),
      service_ids: [salon.services[0]!.id],
      chair_id: second.id,
    };
    const res = await request(app).post('/bookings').set(auth(a)).send(body).expect(201);
    expect(res.body.booking).toMatchObject({ chair_id: second.id, chair_name: 'Chair 2' });

    const taken = await request(app).post('/bookings').set(auth(b)).send(body).expect(409);
    expect(taken.body.error).toMatch(/chair is booked/);
    // Any chair still works: Chair 1 is free.
    const any = await request(app)
      .post('/bookings')
      .set(auth(b))
      .send({ ...body, chair_id: undefined })
      .expect(201);
    expect(any.body.booking.chair_id).toBe(salon.chairs[0]!.id);

    const other = await createSalon();
    await request(app)
      .post('/bookings')
      .set(auth(b))
      .send({ ...body, chair_id: other.chairs[0]!.id })
      .expect(400);
  });

  it('a long appointment holds the chair for every block it needs', async () => {
    const [a, b] = await Promise.all(['a', 'b'].map((n) => signUp(`${n}@example.com`)));
    const salon = await createSalon(null, 1);
    const both = salon.services.map((s) => s.id); // 45 minutes: two blocks
    await request(app)
      .post('/bookings')
      .set(auth(a))
      .send({ salon_id: salon.id, slot_start: tomorrowAt(13), service_ids: both })
      .expect(201);

    const send = (slot: string) =>
      request(app)
        .post('/bookings')
        .set(auth(b))
        .send({ salon_id: salon.id, slot_start: slot, service_ids: [salon.services[0]!.id] });
    await send(at(13, 30)).expect(409); // still in the chair
    // A 45-minute booking at 12:30 would run into 13:00.
    await request(app)
      .post('/bookings')
      .set(auth(b))
      .send({ salon_id: salon.id, slot_start: at(12, 30), service_ids: both })
      .expect(409);
    await send(tomorrowAt(14)).expect(201);
  });

  it('the appointment must finish by closing time', async () => {
    const customer = await signUp('c@example.com');
    const created = await createSalon(null, 1);
    const salon = await prisma.salon.update({
      where: { id: created.id },
      data: { openMin: 600, closeMin: 1200 },
      include: { services: { orderBy: { id: 'asc' } } },
    });
    const res = await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: at(19, 30), service_ids: salon.services.map((s) => s.id) })
      .expect(400);
    expect(res.body.error).toMatch(/before closing/);
    await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: at(19, 30), service_ids: [salon.services[0]!.id] })
      .expect(201);
  });

  it('a salon without chairs takes no bookings', async () => {
    const customer = await signUp('c@example.com');
    const salon = await createSalon(null, 0);
    const res = await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: tomorrowAt(10), service_ids: [salon.services[0]!.id] })
      .expect(409);
    expect(res.body.error).toMatch(/not taking bookings/);
  });
});

describe('the booking form', () => {
  it('saves the customer details and shows them to the salon owner', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const salon = await createSalon(owner);
    const res = await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({
        salon_id: salon.id,
        slot_start: tomorrowAt(9),
        service_ids: [salon.services[0]!.id],
        customer_name: '  Asha Verma ',
        customer_phone: '+91 98765 43210',
        notes: 'Short on the sides',
      })
      .expect(201);
    expect(res.body.booking).toMatchObject({
      customer_name: 'Asha Verma',
      customer_phone: '+91 98765 43210',
      notes: 'Short on the sides',
    });

    const list = await request(app)
      .get(`/salons/${salon.id}/bookings`)
      .query({ from: tomorrowAt(0), to: tomorrowAt(23) })
      .set(auth(owner))
      .expect(200);
    expect(list.body).toHaveLength(1);
    expect(list.body[0]).toMatchObject({ customer_name: 'Asha Verma', chair_name: 'Chair 1' });

    // Outside the requested day: not listed.
    const later = await request(app)
      .get(`/salons/${salon.id}/bookings`)
      .query({ from: tomorrowAt(10), to: tomorrowAt(23) })
      .set(auth(owner))
      .expect(200);
    expect(later.body).toHaveLength(0);
  });

  it('checks the phone number and the length of notes', async () => {
    const customer = await signUp('c@example.com');
    const salon = await createSalon();
    const base = { salon_id: salon.id, slot_start: tomorrowAt(9), service_ids: [salon.services[0]!.id] };
    await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ ...base, customer_phone: 'call me maybe' })
      .expect(400);
    await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ ...base, notes: 'x'.repeat(501) })
      .expect(400);
  });
});

describe('availability', () => {
  it('lists start times with the chairs free for the whole appointment', async () => {
    const customer = await signUp('c@example.com');
    const salon = await createSalon(null, 2);
    await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({
        salon_id: salon.id,
        slot_start: tomorrowAt(10),
        service_ids: [salon.services[0]!.id],
        chair_id: salon.chairs[0]!.id,
      })
      .expect(201);

    const res = await request(app)
      .get(`/salons/${salon.id}/availability`)
      .query({ date: tomorrow(), minutes: 30 })
      .expect(200);
    expect(res.body).toMatchObject({ date: tomorrow(), timezone: 'UTC', minutes: 30, slot_minutes: 30 });
    expect(res.body.slots).toHaveLength(48); // open around the clock
    const bySlot = new Map(res.body.slots.map((s: { start: string; chair_ids: number[] }) => [s.start, s.chair_ids]));
    expect(bySlot.get(tomorrowAt(10))).toEqual([salon.chairs[1]!.id]);
    expect(bySlot.get(at(10, 30))).toEqual(salon.chairs.map((c) => c.id));

    // 60 minutes starting 09:30 would overlap 10:00 on Chair 1.
    const long = await request(app)
      .get(`/salons/${salon.id}/availability`)
      .query({ date: tomorrow(), minutes: 60 })
      .expect(200);
    const longBySlot = new Map(
      long.body.slots.map((s: { start: string; chair_ids: number[] }) => [s.start, s.chair_ids]),
    );
    expect(longBySlot.get(at(9, 30))).toEqual([salon.chairs[1]!.id]);
    expect(long.body.slots).toHaveLength(47); // the last start must end by midnight
  });

  it('gives no times for past days or days beyond two weeks', async () => {
    const salon = await createSalon();
    const past = await request(app)
      .get(`/salons/${salon.id}/availability`)
      .query({ date: '2020-01-01' })
      .expect(200);
    expect(past.body.slots).toEqual([]);
    const far = new Date(Date.now() + 30 * 86_400_000).toISOString().slice(0, 10);
    const future = await request(app).get(`/salons/${salon.id}/availability`).query({ date: far }).expect(200);
    expect(future.body.slots).toEqual([]);
    await request(app).get(`/salons/${salon.id}/availability`).query({ date: 'tomorrow' }).expect(400);
    await request(app).get('/salons/99999/availability').query({ date: tomorrow() }).expect(404);
  });
});

describe('managing chairs with appointments', () => {
  it("a chair with upcoming appointments can't be removed", async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const salon = await createSalon(owner);
    const chair = salon.chairs[0]!;
    const booked = await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: tomorrowAt(10), service_ids: [salon.services[0]!.id], chair_id: chair.id })
      .expect(201);

    const res = await request(app).delete(`/chairs/${chair.id}`).set(auth(owner)).expect(409);
    expect(res.body.error).toMatch(/1 upcoming appointment/);

    await request(app).post(`/bookings/${booked.body.booking.id}/cancel`).set(auth(owner)).expect(200);
    await request(app).delete(`/chairs/${chair.id}`).set(auth(owner)).expect(204);
  });
});
