// Live updates over Socket.IO.
//
// Every client, guests included, joins "salons" (queue, chair and salon
// changes, booked slots). Customers get their own queue token's changes in
// their "user:<id>" room. Signed-in clients also join their own "user:<id>"
// room (their bookings), and owners and admins can ask for a salon's booking
// feed with "salon:watch-bookings".

import type { Server as HttpServer } from 'node:http';

import { Server } from 'socket.io';

import { canManageSalon } from './auth/rbac.js';
import { verifyAccessToken } from './auth/tokens.js';
import { prisma } from './db.js';
import type { Booking, Chair, QueueToken, Salon, Service } from './generated/prisma/client.js';
import { corsOrigin } from './lib/cors.js';
import { bookingJson, salonJson, tokenJson } from './lib/serialize.js';
import type { LiveInfo } from './queue/live.js';

let io: Server | undefined;

const ALL_SALONS = 'salons';
const userRoom = (userId: string) => `user:${userId}`;
const staffRoom = (salonId: number) => `salon-staff:${salonId}`;

export function attachRealtime(server: HttpServer): Server {
  io = new Server(server, {
    cors: { origin: corsOrigin },
  });

  // A signed-in client sends its access token in `auth.token`. Guests send
  // none and only get the public "salons" feed (the same data GET /salons
  // shows anyone). A token that is present but invalid is rejected.
  io.use(async (socket, next) => {
    try {
      const token = socket.handshake.auth?.token;
      if (token === undefined || token === null || token === '') return next();
      if (typeof token !== 'string') throw new Error('bad token');
      const user = await prisma.user.findUnique({ where: { id: verifyAccessToken(token) } });
      if (!user) throw new Error('unknown user');
      socket.data.userId = user.id;
      next();
    } catch {
      next(new Error('unauthorized'));
    }
  });

  io.on('connection', (socket) => {
    const userId = socket.data.userId as string | undefined;
    socket.join(userId ? [ALL_SALONS, userRoom(userId)] : [ALL_SALONS]);

    socket.on('salon:watch-bookings', async (salonId: unknown, ack?: (ok: boolean) => void) => {
      if (!userId) {
        if (typeof ack === 'function') ack(false);
        return;
      }
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

/** Sent for any change to a salon, its services, chairs or queue. */
export function emitSalonChanged(salon: Salon & { services: Service[]; chairs: Chair[] }, live?: LiveInfo) {
  io?.to(ALL_SALONS).emit('salon:changed', salonJson(salon, live));
}

/** The walk-in queue of a salon changed. Clients fetch what they show. */
export function emitQueueChanged(salonId: number) {
  io?.to(ALL_SALONS).emit('queue:changed', { salon_id: salonId });
}

/** Tells a customer their own token changed (called, started, done...). */
export function emitTokenChanged(token: QueueToken & { chair?: { name: string } | null; salon?: { name: string } }) {
  if (token.customerId) io?.to(userRoom(token.customerId)).emit('token:changed', tokenJson(token));
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

export function emitBookingChanged(
  booking: Booking & { salon: { name: string }; chair?: { name: string } | null },
) {
  const payload = bookingJson(booking);
  io?.to([userRoom(booking.customerId), staffRoom(booking.salonId)]).emit('booking:changed', payload);
}
