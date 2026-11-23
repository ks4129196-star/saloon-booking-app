import { createServer } from 'node:http';

import { createApp } from './app.js';
import { expireStaleHolds } from './bookings/service.js';
import { config } from './config.js';
import { databaseReachable, prisma } from './db.js';
import { closeStaleTokens } from './queue/service.js';
import { attachRealtime, closeRealtime } from './realtime.js';

const server = createServer(createApp());
attachRealtime(server);

// Free slots whose online payment was never completed, and close queue
// tokens left over from an earlier day.
const sweeper = setInterval(() => {
  expireStaleHolds().catch((error) => console.error('Expiring unpaid holds failed:', error));
  closeStaleTokens().catch((error) => console.error('Closing old queue tokens failed:', error));
}, 60_000);

server.on('error', (error: NodeJS.ErrnoException) => {
  if (error.code === 'EADDRINUSE') {
    console.error(
      `Port ${config.port} is already in use: the API is probably already running in another ` +
        'terminal. Stop that one (Ctrl+C) or set a different PORT in backend/.env.',
    );
    process.exit(1);
  }
  throw error;
});

server.listen(config.port, () => {
  console.log(`Salon Finder API listening on port ${config.port} (${config.env})`);
  if (!config.smtp) console.log('SMTP is not set: login codes are printed here instead of emailed.');
  void databaseReachable().then((ok) => {
    if (!ok) {
      console.error(
        'Cannot use the database. Check DATABASE_URL in backend/.env (user, password, ' +
          'database name) and that PostgreSQL is running. Requests will fail until this is fixed.',
      );
    }
  });
});

async function shutdown(signal: string) {
  console.log(`${signal} received, shutting down.`);
  clearInterval(sweeper);
  await closeRealtime();
  server.close();
  await prisma.$disconnect();
  process.exit(0);
}
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
