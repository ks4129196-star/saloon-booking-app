// Live updates over Socket.IO.
//
// Every signed-in client joins "salons" (queue and salon changes, booked
// slots) and its own "user:<id>" room (its bookings). Owners and admins can
// also ask for a salon's booking feed with "salon:watch-bookings".

import type { Server as HttpServer } from 'node:http';

import { Server } from 'socket.io';

import { canManageSalon } from './auth/rbac.js';
import { verifyAccessToken } from './auth/tokens.js';
import { config } from './config.js';
import { prisma } from './db.js';
import type { Booking, Salon, Service } from './generated/prisma/client.js';
import { bookingJson, salonJson } from './lib/serialize.js';

let io: Server | undefined;

const ALL_SALONS = 'salons';
const userRoom = (userId: string) => `user:${userId}`;
const staffRoom = (salonId: number) => `salon-staff:${salonId}`;

export function attachRealtime(server: HttpServer): Server {
  io = new Server(server, {
    cors: { origin: config.corsOrigins.length ? config.corsOrigins : false },
  });

  // The client sends its access token in `auth.token` when connecting.
  io.use(async (socket, next) => {
    try {
      const token = socket.handshake.auth?.token;
      if (typeof token !== 'string') throw new Error('missing token');
      const user = await prisma.user.findUnique({ where: { id: verifyAccessToken(token) } });
      if (!user) throw new Error('unknown user');
      socket.data.userId = user.id;
      next();
    } catch {
      next(new Error('unauthorized'));
    }
  });

  io.on('connection', (socket) => {
    const userId = socket.data.userId as string;
    socket.join([ALL_SALONS, userRoom(userId)]);

    socket.on('salon:watch-bookings', async (salonId: unknown, ack?: (ok: boolean) => void) => {
      const id = Number(salonId);
      const [user, salon] = await Promise.all([
        prisma.user.findUnique({ where: { id: userId } }),
        Number.isInteger(id) ? prisma.salon.findUnique({ where: { id } }) : null,
      ]);
      const allowed = Boolean(user && salon && canManageSalon(user, salon));
      if (allowed) socket.join(staffRoom(id));
      if (typeof ack === 'function') ack(allowed);
    });

    socket.on('salon:unwatch-bookings', (salonId: unknown) => {
      socket.leave(staffRoom(Number(salonId)));
    });
  });

  return io;
}

export async function closeRealtime() {
  await io?.close();
  io = undefined;
}

// ----------------------------- Event emitters --------------------------------
// All are no-ops when Socket.IO is not attached (for example in tests).

export function emitSalonChanged(salon: Salon & { services: Service[] }) {
  io?.to(ALL_SALONS).emit('salon:changed', salonJson(salon));
}

export function emitSalonDeleted(salonId: number) {
  io?.to(ALL_SALONS).emit('salon:deleted', { id: salonId });
}

/** A slot became taken or free again. Never says who booked it. */
export function emitSlotChanged(salonId: number, slotStart: Date, taken: boolean) {
  io?.to(ALL_SALONS).emit('slots:changed', {
    salon_id: salonId,
    slot_start: slotStart.toISOString(),
    taken,
  });
}

export function emitBookingChanged(booking: Booking & { salon: { name: string } }) {
  const payload = bookingJson(booking);
  io?.to([userRoom(booking.customerId), staffRoom(booking.salonId)]).emit('booking:changed', payload);
}
