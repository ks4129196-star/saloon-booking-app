// JSON shapes sent to the app. Field names are snake_case, the same as the
// rows Supabase returned, so the Flutter models keep working unchanged.

import type { Booking, Salon, Service, User } from '../generated/prisma/client.js';

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

export const salonJson = (salon: Salon & { services?: Service[] }) => ({
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
  queue: salon.queue,
  highlights: salon.highlights,
  services: (salon.services ?? []).map(serviceJson),
});

export const bookingJson = (booking: Booking & { salon?: { name: string } }) => ({
  id: booking.id,
  salon_id: booking.salonId,
  salons: booking.salon ? { name: booking.salon.name } : null,
  customer_email: booking.customerEmail,
  slot_start: booking.slotStart.toISOString(),
  services: booking.services,
  total: booking.total,
  minutes: booking.minutes,
  status: booking.status,
  payment_method: booking.paymentMethod,
  payment_status: booking.paymentStatus,
});
