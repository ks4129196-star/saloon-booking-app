import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';

import { io as connect, type Socket } from 'socket.io-client';
import request from 'supertest';
import { afterEach, describe, expect, it } from 'vitest';

import { Role } from '../src/generated/prisma/enums.js';
import { attachRealtime, closeRealtime } from '../src/realtime.js';
import { app, auth, createSalon, signUp, tomorrowAt } from './helpers.js';

let server: Server | undefined;
const sockets: Socket[] = [];

async function startServer() {
  server = createServer(app);
  attachRealtime(server);
  await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

function open(url: string, token: string) {
  const socket = connect(url, { auth: { token }, transports: ['websocket'], reconnection: false });
  sockets.push(socket);
  return socket;
}

const once = <T>(socket: Socket, event: string) =>
  new Promise<T>((resolve) => socket.once(event, (payload: T) => resolve(payload)));

afterEach(async () => {
  sockets.splice(0).forEach((socket) => socket.close());
  await closeRealtime();
  await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()));
  server = undefined;
});

describe('live updates', () => {
  it('refuses connections with an invalid token', async () => {
    const url = await startServer();
    const socket = open(url, 'forged');
    const error = await once<Error>(socket, 'connect_error');
    expect(error.message).toBe('unauthorized');
  });

  it('lets guests follow salon changes but not bookings', async () => {
    const url = await startServer();
    const owner = await signUp('o@example.com', Role.owner);
    const salon = await createSalon(owner);
    const guest = open(url, '');
    await once(guest, 'connect');
    expect(
      await new Promise<boolean>((resolve) => guest.emit('salon:watch-bookings', salon.id, resolve)),
    ).toBe(false);

    const changed = once<{ id: number; queue: number }>(guest, 'salon:changed');
    const queued = once<{ salon_id: number }>(guest, 'queue:changed');
    await request(app)
      .post(`/salons/${salon.id}/queue/walk-in`)
      .set(auth(owner))
      .send({ customer_name: 'Walk-in' })
      .expect(201);
    expect(await changed).toMatchObject({ id: salon.id, queue: 1 });
    expect(await queued).toEqual({ salon_id: salon.id });
  });

  it('pushes taken slots to everyone and bookings to the salon owner', async () => {
    const url = await startServer();
    const owner = await signUp('o@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const salon = await createSalon(owner);

    const ownerSocket = open(url, owner.token);
    await once(ownerSocket, 'connect');
    const watching = await new Promise<boolean>((resolve) =>
      ownerSocket.emit('salon:watch-bookings', salon.id, resolve),
    );
    expect(watching).toBe(true);

    const customerSocket = open(url, customer.token);
    await once(customerSocket, 'connect');
    // Customers can't watch a salon's bookings.
    expect(
      await new Promise<boolean>((resolve) => customerSocket.emit('salon:watch-bookings', salon.id, resolve)),
    ).toBe(false);

    const slotEvent = once<{ salon_id: number; taken: boolean }>(customerSocket, 'slots:changed');
    const bookingEvent = once<{ customer_email: string }>(ownerSocket, 'booking:changed');
    await request(app)
      .post('/bookings')
      .set(auth(customer))
      .send({ salon_id: salon.id, slot_start: tomorrowAt(9), service_ids: [salon.services[0]!.id] })
      .expect(201);

    expect(await slotEvent).toMatchObject({ salon_id: salon.id, taken: true });
    expect(await bookingEvent).toMatchObject({ customer_email: 'c@example.com' });
  });

  it("tells a customer when their token is called, and nobody else", async () => {
    const url = await startServer();
    const owner = await signUp('o@example.com', Role.owner);
    const customer = await signUp('c@example.com');
    const other = await signUp('x@example.com');
    const salon = await createSalon(owner);
    const mine = open(url, customer.token);
    const theirs = open(url, other.token);
    await Promise.all([once(mine, 'connect'), once(theirs, 'connect')]);

    const joined = await request(app).post(`/salons/${salon.id}/queue`).set(auth(customer)).send({}).expect(201);
    let leaked = false;
    theirs.on('token:changed', () => (leaked = true));
    const called = once<{ id: string; status: string; chair_name: string }>(mine, 'token:changed');
    await request(app)
      .post(`/queue/${joined.body.id}/call`)
      .set(auth(owner))
      .send({ chair_id: salon.chairs[1]!.id })
      .expect(200);
    expect(await called).toMatchObject({ id: joined.body.id, status: 'called', chair_name: 'Chair 2' });
    expect(leaked).toBe(false);
  });

  it('pushes chair status changes to guests', async () => {
    const url = await startServer();
    const owner = await signUp('o@example.com', Role.owner);
    const salon = await createSalon(owner);
    const guest = open(url, '');
    await once(guest, 'connect');

    const changed = once<{ id: number; chairs: { id: number; status: string }[] }>(guest, 'salon:changed');
    await request(app)
      .patch(`/chairs/${salon.chairs[1]!.id}`)
      .set(auth(owner))
      .send({ status: 'busy' })
      .expect(200);
    const payload = await changed;
    expect(payload.id).toBe(salon.id);
    expect(payload.chairs.map((c) => c.status)).toEqual(['free', 'busy']);
  });
});
