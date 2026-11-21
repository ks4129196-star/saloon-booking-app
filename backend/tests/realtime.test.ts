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
  it('refuses connections without a valid token', async () => {
    const url = await startServer();
    const socket = open(url, 'forged');
    const error = await once<Error>(socket, 'connect_error');
    expect(error.message).toBe('unauthorized');
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

  it('pushes queue changes', async () => {
    const url = await startServer();
    const owner = await signUp('o@example.com', Role.owner);
    const salon = await createSalon(owner);
    const socket = open(url, owner.token);
    await once(socket, 'connect');

    const changed = once<{ id: number; queue: number }>(socket, 'salon:changed');
    await request(app).patch(`/salons/${salon.id}/queue`).set(auth(owner)).send({ queue: 7 }).expect(200);
    expect(await changed).toMatchObject({ id: salon.id, queue: 7 });
  });
});
