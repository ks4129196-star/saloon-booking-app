// Gives an existing account the admin role:
//   npm run make-admin -- you@example.com
// Sign up in the app first. After that, assign roles in the app under
// "Users & roles".

import 'dotenv/config';

import { PrismaPg } from '@prisma/adapter-pg';

import { PrismaClient } from '../src/generated/prisma/client.js';

const email = process.argv[2]?.trim().toLowerCase();
if (!email) {
  console.error('Usage: npm run make-admin -- you@example.com');
  process.exit(1);
}

const prisma = new PrismaClient({
  adapter: new PrismaPg({ connectionString: process.env.DATABASE_URL! }),
});

try {
  const { count } = await prisma.user.updateMany({ where: { email }, data: { role: 'admin' } });
  console.log(count ? `${email} is now an admin.` : `No account found for ${email}. Sign up in the app first.`);
  if (!count) process.exitCode = 1;
} finally {
  await prisma.$disconnect();
}
