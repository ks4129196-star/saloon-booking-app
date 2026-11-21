// Starts an in-memory PostgreSQL (PGlite) for the test run and applies the
// Prisma migrations to it.

import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { PGlite } from '@electric-sql/pglite';
import { PGLiteSocketServer } from '@electric-sql/pglite-socket';

import { TEST_DB_PORT } from '../vitest.config.js';

export default async function setup() {
  const db = await PGlite.create();
  const migrationsDir = join(import.meta.dirname, '..', 'prisma', 'migrations');
  for (const dir of readdirSync(migrationsDir, { withFileTypes: true })) {
    if (!dir.isDirectory()) continue;
    await db.exec(readFileSync(join(migrationsDir, dir.name, 'migration.sql'), 'utf8'));
  }

  const server = new PGLiteSocketServer({ db, port: TEST_DB_PORT, host: '127.0.0.1' });
  await server.start();

  return async () => {
    await server.stop();
    await db.close();
  };
}
