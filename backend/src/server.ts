import { createServer } from 'node:http';

import { createApp } from './app.js';
import { expireStaleHolds } from './bookings/service.js';
import { config } from './config.js';
import { prisma } from './db.js';
import { attachRealtime, closeRealtime } from './realtime.js';

const server = createServer(createApp());
attachRealtime(server);

// Free slots whose online payment was never completed.
const sweeper = setInterval(() => {
  expireStaleHolds().catch((error) => console.error('Expiring unpaid holds failed:', error));
}, 60_000);

server.listen(config.port, () => {
  console.log(`Salon Finder API listening on port ${config.port} (${config.env})`);
  if (!config.smtp) console.log('SMTP is not set: login codes are printed here instead of emailed.');
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
