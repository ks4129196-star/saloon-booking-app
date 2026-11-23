import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { prisma } from '../src/db.js';
import { Role } from '../src/generated/prisma/enums.js';
import { app, auth, createSalon, signUp, tomorrowAt } from './helpers.js';

describe('booking a slot', () => {
  it('prices the booking on the server and marks the slots it needs taken', async () => {
    const customer = await signUp('c@example.com');
    const salon = await createSalon(null, 1);
    const slot = tomorrowAt(10);

    const res = await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: slot, service_ids: salon.services.map((s) => s.id) })
      .expect(201);
    expect(res.body.booking).toMatchObject({
      total: 450,
      minutes: 45,
      status: 'confirmed',
      payment_method: 'salon',
      salons: { name: 'Test Salon' },
      chair_id: salon.chairs[0]!.id,
      chair_name: 'Chair 1',
    });
    expect(res.body.payment).toBeNull();

    const taken = await request(app)
      .get('/bookings/taken-slots')
      .query({ from: tomorrowAt(0), to: tomorrowAt(23), salon_id: salon.id })
      .set(auth(customer))
      .expect(200);
    // 45 minutes holds the 10:00 and 10:30 blocks of the only chair.
    expect(taken.body).toEqual([
      { salon_id: salon.id, slot_start: slot },
      { salon_id: salon.id, slot_start: tomorrowAt(10).replace('T10:00', 'T10:30') },
    ]);

    const mine = await request(app).get('/bookings/mine').set(auth(customer)).expect(200);
    expect(mine.body).toHaveLength(1);
  });

  it('refuses a slot that is already booked', async () => {
    const a = await signUp('a@example.com');
    const b = await signUp('b@example.com');
    const salon = await createSalon(null, 1);
    const body = { salon_id: salon.id, slot_start: tomorrowAt(11), service_ids: [salon.services[0]!.id] };

    await request(app).post('/bookings').set(auth(a)).send(body).expect(201);
    const res = await request(app).post('/bookings').set(auth(b)).send(body).expect(409);
    expect(res.body.error).toMatch(/just booked/);
  });

  it('allows only one of two simultaneous bookings for the last chair', async () => {
    const a = await signUp('a@example.com');
    const b = await signUp('b@example.com');
    const salon = await createSalon(null, 1);
    const body = { salon_id: salon.id, slot_start: tomorrowAt(12), service_ids: [salon.services[0]!.id] };

    const results = await Promise.all([
      request(app).post('/bookings').set(auth(a)).send(body),
      request(app).post('/bookings').set(auth(b)).send(body),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual([201, 409]);
  });

  it('checks the time and the services', async () => {
    const customer = await signUp('c@example.com');
    const salon = await prisma.salon.update({
      where: { id: (await createSalon()).id },
      data: { openMin: 600, closeMin: 1200 },
      include: { services: true },
    });
    const otherSalon = await createSalon();
    const serviceId = salon.services[0]!.id;
    const book = (slot: string, ids = [serviceId]) =>
      request(app).post('/bookings').set(auth(customer)).send({ salon_id: salon.id, slot_start: slot, service_ids: ids });

    expect((await book(tomorrowAt(8))).body.error).toMatch(/opening hours/); // before opening
    expect((await book(tomorrowAt(10).replace(':00:00', ':10:00'))).body.error).toMatch(/opening hours/); // off the grid
    expect((await book(new Date(Date.now() - 3_600_000).toISOString())).body.error).toMatch(/upcoming/);
    expect((await book(tomorrowAt(10), [otherSalon.services[0]!.id])).body.error).toMatch(/no longer offered/);
    await book(tomorrowAt(10)).expect(201);
  });
});

describe('cancelling', () => {
  it('only the customer, the salon owner or an admin can cancel', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const stranger = await signUp('s@example.com');
    const salon = await createSalon(owner);
    const slot = tomorrowAt(14);

    const booked = await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: slot, service_ids: [salon.services[0]!.id] })
      .expect(201);
    const id = booked.body.booking.id;

    await request(app).post(`/bookings/${id}/cancel`).set(auth(stranger)).expect(403);
    const res = await request(app).post(`/bookings/${id}/cancel`).set(auth(owner)).expect(200);
    expect(res.body.status).toBe('cancelled');
    await request(app).post(`/bookings/${id}/cancel`).set(auth(customer)).expect(409);

    // The slot is free again.
    await request(app)
      .post('/bookings')
      .set(auth(stranger))
      .send({ salon_id: salon.id, slot_start: slot, service_ids: [salon.services[0]!.id] })
      .expect(201);
  });

  it("customers can't see other customers' bookings; owners see their salon's", async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const otherOwner = await signUp('o2@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const salon = await createSalon(owner);
    await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: tomorrowAt(15), service_ids: [salon.services[0]!.id] })
      .expect(201);

    const from = new Date().toISOString();
    await request(app).get(`/salons/${salon.id}/bookings`).query({ from }).set(auth(customer)).expect(403);
    await request(app).get(`/salons/${salon.id}/bookings`).query({ from }).set(auth(otherOwner)).expect(403);
    const res = await request(app).get(`/salons/${salon.id}/bookings`).query({ from }).set(auth(owner)).expect(200);
    expect(res.body[0].customer_email).toBe('c@example.com');
  });
});
