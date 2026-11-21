import request from 'supertest';
import { afterAll, beforeEach } from 'vitest';

import { createApp } from '../src/app.js';
import { setMailer } from '../src/auth/mailer.js';
import { prisma } from '../src/db.js';
import { Role } from '../src/generated/prisma/enums.js';

export const app = createApp();

/** The last code emailed to each address. */
export const sentCodes = new Map<string, string>();
export let mailShouldFail = false;
export const setMailShouldFail = (value: boolean) => {
  mailShouldFail = value;
};

setMailer({
  async sendCode(to, code) {
    if (mailShouldFail) throw new Error('SMTP 535 Authentication failed');
    sentCodes.set(to, code);
  },
});

beforeEach(async () => {
  sentCodes.clear();
  mailShouldFail = false;
  await prisma.$executeRawUnsafe(
    'TRUNCATE "bookings", "services", "salons", "email_codes", "refresh_tokens", "users" RESTART IDENTITY CASCADE',
  );
});

afterAll(async () => {
  await prisma.$disconnect();
});

export interface TestUser {
  id: string;
  email: string;
  token: string;
  refreshToken: string;
}

/** Registers, verifies and signs in a user, optionally with a role. */
export async function signUp(email: string, role: Role = Role.customer): Promise<TestUser> {
  await request(app).post('/auth/register').send({ email, password: 'correct-horse-1' }).expect(202);
  const res = await request(app)
    .post('/auth/register/verify')
    .send({ email, code: sentCodes.get(email) })
    .expect(200);
  if (role !== Role.customer) {
    await prisma.user.update({ where: { id: res.body.user.id }, data: { role } });
  }
  return {
    id: res.body.user.id,
    email,
    token: res.body.access_token,
    refreshToken: res.body.refresh_token,
  };
}

export const auth = (user: TestUser) => ({ Authorization: `Bearer ${user.token}` });

/** A salon open around the clock (UTC) with two services. */
export async function createSalon(owner: TestUser | null = null) {
  return prisma.salon.create({
    data: {
      ownerId: owner?.id ?? null,
      name: 'Test Salon',
      lat: 28.6,
      lon: 77.2,
      timezone: 'UTC',
      openMin: 0,
      closeMin: 1440,
      services: {
        create: [
          { name: 'Haircut', price: 300, minutes: 30, category: 'Hair' },
          { name: 'Shave', price: 150, minutes: 15, category: 'Grooming' },
        ],
      },
    },
    include: { services: { orderBy: { id: 'asc' } } },
  });
}

/** Tomorrow at [hour]:00 UTC, as an ISO string. */
export function tomorrowAt(hour: number): string {
  const date = new Date();
  date.setUTCDate(date.getUTCDate() + 1);
  date.setUTCHours(hour, 0, 0, 0);
  return date.toISOString();
}
