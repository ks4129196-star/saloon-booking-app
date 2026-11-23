import cors from 'cors';
import express from 'express';
import helmet from 'helmet';

import { adminRouter } from './admin/routes.js';
import { assistantRouter } from './assistant/routes.js';
import { authRouter, meRouter } from './auth/routes.js';
import { bookingsRouter, salonBookingsRouter } from './bookings/routes.js';
import { config } from './config.js';
import { databaseReachable } from './db.js';
import { corsOrigin } from './lib/cors.js';
import { errorHandler, notFoundHandler } from './lib/errors.js';
import { paymentsEnabled } from './payments/razorpay.js';
import { paymentsRouter } from './payments/routes.js';
import { queueRouter, salonQueueRouter } from './queue/routes.js';
import { chairsRouter, salonsRouter, servicesRouter } from './salons/routes.js';

export function createApp() {
  const app = express();
  app.set('trust proxy', 1); // behind the host's load balancer
  app.use(helmet());
  app.use(cors({ origin: corsOrigin }));

  // The webhook needs the raw body, so payments parse their own bodies.
  app.use('/payments', paymentsRouter);
  app.use(express.json({ limit: '100kb' }));

  app.get('/health', async (_req, res) => {
    const database = await databaseReachable();
    res.status(database ? 200 : 503).json({
      ok: database,
      database,
      payments: paymentsEnabled(),
      assistant: Boolean(config.anthropic),
    });
  });

  app.use('/auth', authRouter);
  app.use('/me', meRouter);
  app.use('/salons/:id/bookings', salonBookingsRouter);
  app.use('/salons/:id/queue', salonQueueRouter);
  app.use('/queue', queueRouter);
  app.use('/salons', salonsRouter);
  app.use('/services', servicesRouter);
  app.use('/chairs', chairsRouter);
  app.use('/bookings', bookingsRouter);
  app.use('/admin', adminRouter);
  app.use('/assistant', assistantRouter);

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}
