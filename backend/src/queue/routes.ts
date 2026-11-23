import { Router } from 'express';
import { z } from 'zod';

import { canManageSalon, currentUser, requireAuth } from '../auth/rbac.js';
import { prisma } from '../db.js';
import { TokenStatus } from '../generated/prisma/enums.js';
import { forbidden, notFound } from '../lib/errors.js';
import { publicTokenJson, tokenJson } from '../lib/serialize.js';
import { ACTIVE_TOKEN, loadLiveOne } from './live.js';
import { closeStaleTokens, describeToken, joinQueue, type TokenAction, tokenAction } from './service.js';

const phone = z
  .string()
  .trim()
  .max(30)
  .regex(/^[0-9+()\- ]*$/, 'Enter a valid phone number.');

const joinBody = z.object({
  service_ids: z.array(z.number().int().positive()).max(20).optional(),
  customer_name: z.string().trim().max(80).optional(),
  customer_phone: phone.optional(),
});

const walkInBody = joinBody.extend({
  customer_name: z.string().trim().min(1, 'Enter a name to call the walk-in by.').max(80),
  minutes: z.number().int().min(5).max(600).optional(),
});

const actionBody = z.object({
  chair_id: z.number().int().positive().optional(),
  force: z.boolean().optional(),
});

const ACTIONS: TokenAction[] = ['call', 'start', 'done', 'no_show', 'cancel'];

const salonDetails = {
  services: { orderBy: { id: 'asc' as const } },
  chairs: { orderBy: { id: 'asc' as const } },
};

async function loadSalon(value: unknown) {
  const id = Number(value);
  const salon = Number.isInteger(id) && id > 0
    ? await prisma.salon.findUnique({ where: { id }, include: salonDetails })
    : null;
  if (!salon) throw notFound('This salon no longer exists.');
  return salon;
}

const described = (d: Awaited<ReturnType<typeof describeToken>>) =>
  tokenJson(d.token, { estimatedStart: d.estimatedStart, ahead: d.ahead });

// ---------------------------- /salons/:id/queue ------------------------------

export const salonQueueRouter = Router({ mergeParams: true });
const salonId = (req: { params: unknown }) => (req.params as { id?: string }).id;

/** The queue as anyone may see it: numbers and estimates, never names. */
salonQueueRouter.get('/', async (req, res) => {
  const salon = await loadSalon(salonId(req));
  const live = await loadLiveOne(salon);
  res.json({
    salon_id: salon.id,
    day: live.day,
    open: live.open,
    paused: live.estimate.paused,
    waiting: live.waiting,
    wait_minutes: live.open ? live.estimate.waitMinutes : null,
    closes_at: live.closesAt.toISOString(),
    now_serving: live.tokens.filter((t) => t.status === TokenStatus.serving).map((t) => publicTokenJson(t)),
    queue: live.tokens
      .filter((t) => t.status !== TokenStatus.serving)
      .map((t) => publicTokenJson(t, live.estimate.starts.get(t.id))),
  });
});

/** A signed-in customer takes a token. */
salonQueueRouter.post('/', requireAuth, async (req, res) => {
  const salon = await loadSalon(salonId(req));
  const body = joinBody.parse(req.body ?? {});
  const token = await joinQueue(salon.id, currentUser(req), {
    serviceIds: body.service_ids,
    customerName: body.customer_name,
    customerPhone: body.customer_phone,
  });
  res.status(201).json(described(token));
});

/** Staff add someone who walked in without the app. */
salonQueueRouter.post('/walk-in', requireAuth, async (req, res) => {
  const salon = await loadSalon(salonId(req));
  if (!canManageSalon(currentUser(req), salon)) throw forbidden();
  const body = walkInBody.parse(req.body);
  const token = await joinQueue(salon.id, null, {
    serviceIds: body.service_ids,
    minutes: body.minutes,
    customerName: body.customer_name,
    customerPhone: body.customer_phone,
  });
  res.status(201).json(described(token));
});

/** Today's tokens with names, for the salon's staff. */
salonQueueRouter.get('/manage', requireAuth, async (req, res) => {
  const salon = await loadSalon(salonId(req));
  if (!canManageSalon(currentUser(req), salon)) throw forbidden();
  const live = await loadLiveOne(salon);
  const tokens = await prisma.queueToken.findMany({
    where: { salonId: salon.id, day: live.day },
    include: { chair: { select: { name: true } } },
    orderBy: { number: 'asc' },
  });
  let ahead = 0;
  res.json({
    day: live.day,
    open: live.open,
    paused: live.estimate.paused,
    waiting: live.waiting,
    wait_minutes: live.open ? live.estimate.waitMinutes : null,
    tokens: tokens.map((t) => {
      const json = tokenJson(t, {
        estimatedStart: live.estimate.starts.get(t.id),
        ahead: t.status === TokenStatus.waiting || t.status === TokenStatus.called ? ahead : undefined,
      });
      if (t.status === TokenStatus.waiting || t.status === TokenStatus.called) ahead++;
      return json;
    }),
  });
});

// --------------------------------- /queue ------------------------------------

export const queueRouter = Router();
queueRouter.use(requireAuth);

/** The signed-in customer's active token, if any, with their place and wait. */
queueRouter.get('/mine', async (req, res) => {
  const user = currentUser(req);
  await closeStaleTokens({ customerId: user.id });
  const tokens = await prisma.queueToken.findMany({
    where: { customerId: user.id, status: { in: ACTIVE_TOKEN } },
    select: { id: true },
  });
  res.json(await Promise.all(tokens.map(async (t) => described(await describeToken(t.id)))));
});

/** call, start, done, no_show (staff) or cancel (staff or the token's customer). */
queueRouter.post('/:id/:action', async (req, res) => {
  const id = z.uuid().safeParse(req.params.id);
  if (!id.success) throw notFound('Token not found.');
  const action = req.params.action as TokenAction;
  if (!ACTIONS.includes(action)) throw notFound();
  const body = actionBody.parse(req.body ?? {});
  const result = await tokenAction(currentUser(req), id.data, action, {
    chairId: body.chair_id,
    force: body.force,
  });
  res.json(described(result));
});
