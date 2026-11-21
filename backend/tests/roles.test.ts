import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { Role } from '../src/generated/prisma/enums.js';
import { app, auth, createSalon, signUp } from './helpers.js';

const newSalon = {
  name: 'New Salon',
  type: 'Barber Shop',
  lat: 28.61,
  lon: 77.2,
  open_min: 600,
  close_min: 1200,
  staff: 2,
  highlights: ['AC'],
};

describe('salons and roles', () => {
  it('everyone signed in can browse; nobody signed out can', async () => {
    const customer = await signUp('c@example.com');
    await createSalon();
    await request(app).get('/salons').expect(401);
    const res = await request(app).get('/salons').set(auth(customer)).expect(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0].services.map((s: { name: string }) => s.name)).toEqual(['Haircut', 'Shave']);
  });

  it('customers cannot create salons', async () => {
    const customer = await signUp('c@example.com');
    await request(app).post('/salons').set(auth(customer)).send(newSalon).expect(403);
  });

  it("an owner's new salon always belongs to them", async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const other = await signUp('o2@example.com', Role.owner);
    const res = await request(app)
      .post('/salons')
      .set(auth(owner))
      .send({ ...newSalon, owner_id: other.id })
      .expect(201);
    expect(res.body.owner_id).toBe(owner.id);
    expect(res.body.rating).toBe(0);
  });

  it("owners edit their own salons only; ratings can't be set", async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const other = await signUp('o2@example.com', Role.owner);
    const mine = await createSalon(owner);
    const theirs = await createSalon(other);

    const res = await request(app)
      .patch(`/salons/${mine.id}`)
      .set(auth(owner))
      .send({ ...newSalon, name: 'Renamed', rating: 5, reviews: 999 })
      .expect(200);
    expect(res.body).toMatchObject({ name: 'Renamed', rating: 0, reviews: 0, owner_id: owner.id });

    await request(app).patch(`/salons/${theirs.id}`).set(auth(owner)).send(newSalon).expect(403);
    await request(app).patch(`/salons/${theirs.id}/queue`).set(auth(owner)).send({ queue: 3 }).expect(403);
    await request(app).delete(`/salons/${theirs.id}`).set(auth(owner)).expect(403);
    await request(app)
      .post(`/salons/${theirs.id}/services`)
      .set(auth(owner))
      .send({ name: 'X', price: 1, minutes: 10 })
      .expect(403);
    await request(app).delete(`/services/${theirs.services[0]!.id}`).set(auth(owner)).expect(403);
  });

  it('owners manage the live queue and services of their salon', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const salon = await createSalon(owner);
    const queue = await request(app).patch(`/salons/${salon.id}/queue`).set(auth(owner)).send({ queue: 4 }).expect(200);
    expect(queue.body.queue).toBe(4);

    const service = await request(app)
      .post(`/salons/${salon.id}/services`)
      .set(auth(owner))
      .send({ name: 'Facial', price: 800, minutes: 45, category: 'Skin' })
      .expect(201);
    await request(app)
      .patch(`/services/${service.body.id}`)
      .set(auth(owner))
      .send({ name: 'Gold Facial', price: 1500, minutes: 60, category: 'Skin' })
      .expect(200);
    await request(app).delete(`/services/${service.body.id}`).set(auth(owner)).expect(204);
  });

  it('validates salon fields', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const res = await request(app)
      .post('/salons')
      .set(auth(owner))
      .send({ ...newSalon, open_min: 1200, close_min: 600 })
      .expect(400);
    expect(res.body.error).toMatch(/Closing time/);
  });

  it('admins edit any salon and can only assign owners as owners', async () => {
    const admin = await signUp('a@example.com', Role.admin);
    const owner = await signUp('o@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const salon = await createSalon();

    await request(app)
      .patch(`/salons/${salon.id}`)
      .set(auth(admin))
      .send({ ...newSalon, owner_id: customer.id })
      .expect(400);
    const res = await request(app)
      .patch(`/salons/${salon.id}`)
      .set(auth(admin))
      .send({ ...newSalon, owner_id: owner.id })
      .expect(200);
    expect(res.body.owner_id).toBe(owner.id);

    const managed = await request(app).get('/salons/managed').set(auth(owner)).expect(200);
    expect(managed.body.map((s: { id: number }) => s.id)).toEqual([salon.id]);
  });
});

describe('admin: users and roles', () => {
  it('only admins list users and change roles', async () => {
    const admin = await signUp('a@example.com', Role.admin);
    const customer = await signUp('c@example.com');

    await request(app).get('/admin/users').set(auth(customer)).expect(403);
    const list = await request(app).get('/admin/users').set(auth(admin)).expect(200);
    expect(list.body).toHaveLength(2);

    await request(app).patch(`/admin/users/${customer.id}/role`).set(auth(customer)).send({ role: 'admin' }).expect(403);
    const res = await request(app)
      .patch(`/admin/users/${customer.id}/role`)
      .set(auth(admin))
      .send({ role: 'owner' })
      .expect(200);
    expect(res.body.role).toBe('owner');

    // The role change applies to the very next request.
    await request(app).get('/salons/managed').set(auth(customer)).expect(200);
  });

  it('admins cannot change their own role', async () => {
    const admin = await signUp('a@example.com', Role.admin);
    const res = await request(app)
      .patch(`/admin/users/${admin.id}/role`)
      .set(auth(admin))
      .send({ role: 'customer' })
      .expect(403);
    expect(res.body.error).toMatch(/own role/);
  });
});
