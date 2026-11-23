import { PrismaPg } from '@prisma/adapter-pg';

import { config } from './config.js';
import { PrismaClient } from './generated/prisma/client.js';

export const prisma = new PrismaClient({
  adapter: new PrismaPg({
    connectionString: config.databaseUrl,
    // Tests run against an in-memory database that takes one connection.
    ...(config.env === 'test' ? { max: 1 } : {}),
  }),
});

export type Db = typeof prisma;

/** True when a trivial query succeeds; logs the reason when it does not. */
export async function databaseReachable(): Promise<boolean> {
  try {
    await prisma.$queryRaw`SELECT 1`;
    return true;
  } catch (error) {
    const reason = error instanceof Error ? error.message.trim().split('\n').pop() : String(error);
    console.error(`Database check failed: ${reason}`);
    return false;
  }
}
