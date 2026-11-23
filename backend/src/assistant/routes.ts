import Anthropic from '@anthropic-ai/sdk';
import { Router } from 'express';
import { ipKeyGenerator, rateLimit } from 'express-rate-limit';
import { z } from 'zod';

import { currentUser, requireAuth } from '../auth/rbac.js';
import { config } from '../config.js';
import { ApiError } from '../lib/errors.js';

const SYSTEM_PROMPT =
  'You are the assistant inside Salon Finder, an app for finding nearby salons in India and ' +
  'booking a slot. Help with salon services, hair, skin and grooming styles, what to ask a ' +
  'stylist, and planning a visit. Prices in the app are in Indian rupees. You cannot see the ' +
  "user's bookings or make bookings; for that, point them to the salon page in the app. " +
  'Keep answers short and practical.';

const chatBody = z.object({
  messages: z
    .array(
      z.object({
        role: z.enum(['user', 'assistant']),
        content: z.string().trim().min(1).max(4000),
      }),
    )
    .min(1)
    .max(20)
    .refine((messages) => messages[0]?.role === 'user', 'The first message must be from the user.')
    .refine((messages) => messages.at(-1)?.role === 'user', 'The last message must be from the user.'),
});

let client: Anthropic | undefined;

const chatLimiter = rateLimit({
  windowMs: 60 * 1000,
  limit: 10,
  // Per signed-in user; the IP fallback groups IPv6 addresses by /56 subnet so
  // one client cannot dodge the limit by rotating addresses.
  keyGenerator: (req) => (req.user ? `user:${req.user.id}` : ipKeyGenerator(req.ip ?? '')),
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  skip: () => config.env === 'test',
  message: { error: 'You are sending messages too quickly. Wait a moment.', code: 'rate_limited' },
});

export const assistantRouter = Router();
assistantRouter.use(requireAuth);

assistantRouter.post('/chat', chatLimiter, async (req, res) => {
  if (!config.anthropic) {
    throw new ApiError(503, 'The assistant is not set up yet.', 'assistant_disabled');
  }
  const body = chatBody.parse(req.body);
  client ??= new Anthropic({ apiKey: config.anthropic.apiKey });

  let response;
  try {
    response = await client.beta.messages.create({
      model: config.anthropic.model,
      max_tokens: 16000,
      system: SYSTEM_PROMPT,
      messages: body.messages,
      output_config: { effort: 'low' },
      // If the model declines for safety reasons, the API retries on a
      // fallback model inside the same call.
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      metadata: { user_id: currentUser(req).id },
    });
  } catch (error) {
    if (error instanceof Anthropic.RateLimitError) {
      throw new ApiError(503, 'The assistant is busy. Please try again shortly.', 'assistant_busy');
    } else if (error instanceof Anthropic.APIError) {
      console.error(`Claude API error ${error.status}:`, error.message);
    } else {
      console.error('Claude request failed:', error);
    }
    throw new ApiError(502, 'Could not get a reply from the assistant.', 'assistant_failed');
  }

  if (response.stop_reason === 'refusal') {
    res.json({ reply: "Sorry, I can't help with that. Ask me about salons, services or styles." });
    return;
  }
  const reply = response.content
    .flatMap((block) => (block.type === 'text' ? [block.text] : []))
    .join('')
    .trim();
  if (!reply) throw new ApiError(502, 'The assistant returned an empty reply.', 'assistant_failed');
  res.json({ reply });
});
