import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { prisma } from '../src/db.js';
import { Role } from '../src/generated/prisma/enums.js';
import { app, auth, createSalon, signUp } from './helpers.js';

describe('chairs', () => {
  it('are listed with the salon for everyone, signed in or not', async () => {
    const salon = await createSalon();
    const res = await request(app).get(`/salons/${salon.id}`).expect(200);
    expect(res.body.chairs).toEqual([
      expect.objectContaining({ name: 'Chair 1', status: 'free', salon_id: salon.id }),
      expect.objectContaining({ name: 'Chair 2', status: 'free', salon_id: salon.id }),
    ]);
    expect(typeof res.body.chairs[0].status_since).toBe('string');
  });

  it('a new salon starts with one chair per stylist', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const res = await request(app)
      .post('/salons')
      .set(auth(owner))
      .send({ name: 'Three Chairs', lat: 28.6, lon: 77.2, open_min: 600, close_min: 1200, staff: 3 })
      .expect(201);
    expect(res.body.chairs.map((c: { name: string }) => c.name)).toEqual(['Chair 1', 'Chair 2', 'Chair 3']);
  });

  it('the owner can add, rename, change status and remove chairs', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const salon = await createSalon(owner);

    const added = await request(app).post(`/salons/${salon.id}/chairs`).set(auth(owner)).send({}).expect(201);
    expect(added.body).toMatchObject({ name: 'Chair 3', status: 'free' });

    const chairId = salon.chairs[0]!.id;
    const before = salon.chairs[0]!.statusSince;
    const busy = await request(app)
      .patch(`/chairs/${chairId}`)
      .set(auth(owner))
      .send({ status: 'busy' })
      .expect(200);
    expect(busy.body.status).toBe('busy');
    expect(new Date(busy.body.status_since).getTime()).toBeGreaterThanOrEqual(before.getTime());

    const renamed = await request(app)
      .patch(`/chairs/${chairId}`)
      .set(auth(owner))
      .send({ name: 'Ravi' })
      .expect(200);
    // Renaming keeps the status and when it started.
    expect(renamed.body).toMatchObject({ name: 'Ravi', status: 'busy', status_since: busy.body.status_since });

    await request(app).patch(`/chairs/${chairId}`).set(auth(owner)).send({ status: 'on_break' }).expect(200);
    await request(app).patch(`/chairs/${chairId}`).set(auth(owner)).send({ status: 'asleep' }).expect(400);
    await request(app).patch(`/chairs/${chairId}`).set(auth(owner)).send({}).expect(400);

    await request(app).delete(`/chairs/${added.body.id}`).set(auth(owner)).expect(204);
    const res = await request(app).get(`/salons/${salon.id}`).expect(200);
    expect(res.body.chairs.map((c: { name: string; status: string }) => [c.name, c.status])).toEqual([
      ['Ravi', 'on_break'],
      ['Chair 2', 'free'],
    ]);
  });

  it('only the salon owner or an admin can manage its chairs', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const otherOwner = await signUp('o2@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const admin = await signUp('a@example.com', Role.admin);
    const salon = await createSalon(owner);
    const chairId = salon.chairs[0]!.id;

    for (const user of [otherOwner, customer]) {
      await request(app).post(`/salons/${salon.id}/chairs`).set(auth(user)).send({}).expect(403);
      await request(app).patch(`/chairs/${chairId}`).set(auth(user)).send({ status: 'busy' }).expect(403);
      await request(app).delete(`/chairs/${chairId}`).set(auth(user)).expect(403);
    }
    await request(app).post(`/salons/${salon.id}/chairs`).send({}).expect(401);
    await request(app).patch(`/chairs/${chairId}`).send({ status: 'busy' }).expect(401);
    await request(app).delete(`/chairs/${chairId}`).expect(401);

    await request(app).patch(`/chairs/${chairId}`).set(auth(admin)).send({ status: 'busy' }).expect(200);
    await request(app).patch('/chairs/999999').set(auth(admin)).send({ status: 'busy' }).expect(404);
  });

  it('a salon has at most 50 chairs', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const salon = await createSalon(owner);
    await prisma.chair.createMany({
      data: Array.from({ length: 48 }, (_, i) => ({ salonId: salon.id, name: `Extra ${i}` })),
    });
    await request(app).post(`/salons/${salon.id}/chairs`).set(auth(owner)).send({}).expect(400);
  });

  it('are removed with their salon', async () => {
    const owner = await signUp('o@example.com', Role.owner);
    const salon = await createSalon(owner);
    await request(app).delete(`/salons/${salon.id}`).set(auth(owner)).expect(204);
    expect(await prisma.chair.count({ where: { salonId: salon.id } })).toBe(0);
  });
});
