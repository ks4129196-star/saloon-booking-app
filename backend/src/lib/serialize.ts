// JSON shapes sent to the app. Field names are snake_case, the same as the
// rows Supabase returned, so the Flutter models keep working unchanged.

import type { Booking, Chair, QueueToken, Salon, Service, User } from '../generated/prisma/client.js';
import type { LiveInfo } from '../queue/live.js';

export const profileJson = (user: User) => ({
  id: user.id,
  email: user.email,
  full_name: user.fullName,
  role: user.role,
  email_verified: user.emailVerified,
});

export const serviceJson = (service: Service) => ({
  id: service.id,
  salon_id: service.salonId,
  name: service.name,
  price: service.price,
  minutes: service.minutes,
  category: service.category,
});

export const chairJson = (chair: Chair) => ({
  id: chair.id,
  salon_id: chair.salonId,
  name: chair.name,
  status: chair.status,
  status_since: chair.statusSince.toISOString(),
});

/**
 * [live] adds the walk-in queue: how many are waiting, the estimated wait for
 * someone joining now (null when closed or every chair is on break) and the
 * token numbers in the chairs.
 */
export const salonJson = (salon: Salon & { services?: Service[]; chairs?: Chair[] }, live?: LiveInfo) => ({
  id: salon.id,
  owner_id: salon.ownerId,
  name: salon.name,
  type: salon.type,
  address: salon.address,
  phone: salon.phone,
  rating: Number(salon.rating),
  reviews: salon.reviews,
  lat: salon.lat,
  lon: salon.lon,
  timezone: salon.timezone,
  open_min: salon.openMin,
  close_min: salon.closeMin,
  staff: salon.staff,
  queue: live?.waiting ?? 0,
  wait_minutes: live && live.open ? live.estimate.waitMinutes : null,
  queue_paused: live?.estimate.paused ?? false,
  now_serving: (live?.tokens ?? []).filter((t) => t.status === 'serving').map((t) => t.number),
  highlights: salon.highlights,
  services: (salon.services ?? []).map(serviceJson),
  chairs: (salon.chairs ?? []).map(chairJson),
});

export const bookingJson = (
  booking: Booking & { salon?: { name: string }; chair?: { name: string } | null },
) => ({
  id: booking.id,
  salon_id: booking.salonId,
  salons: booking.salon ? { name: booking.salon.name } : null,
  chair_id: booking.chairId,
  chair_name: booking.chair?.name ?? null,
  customer_email: booking.customerEmail,
  customer_name: booking.customerName,
  customer_phone: booking.customerPhone,
  notes: booking.notes,
  slot_start: booking.slotStart.toISOString(),
  services: booking.services,
  total: booking.total,
  minutes: booking.minutes,
  status: booking.status,
  payment_method: booking.paymentMethod,
  payment_status: booking.paymentStatus,
});

type TokenWithChair = QueueToken & { chair?: { name: string } | null; salon?: { name: string } };

/** What anyone may see of a token: its number, state and estimate. */
export const publicTokenJson = (token: TokenWithChair, estimatedStart?: Date) => ({
  number: token.number,
  status: token.status,
  chair_name: token.chair?.name ?? null,
  estimated_start: estimatedStart?.toISOString() ?? null,
});

/** The full token, for its customer and the salon's staff. */
export const tokenJson = (
  token: TokenWithChair,
  extra: { estimatedStart?: Date; ahead?: number } = {},
) => ({
  ...publicTokenJson(token, extra.estimatedStart),
  id: token.id,
  salon_id: token.salonId,
  salon_name: token.salon?.name ?? null,
  day: token.day,
  chair_id: token.chairId,
  customer_name: token.customerName,
  customer_phone: token.customerPhone,
  walk_in: token.customerId === null,
  services: token.services,
  minutes: token.minutes,
  /** People before this token who have not been called yet. */
  ahead: extra.ahead ?? null,
  created_at: token.createdAt.toISOString(),
  called_at: token.calledAt?.toISOString() ?? null,
  started_at: token.startedAt?.toISOString() ?? null,
  finished_at: token.finishedAt?.toISOString() ?? null,
});
