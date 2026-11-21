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
