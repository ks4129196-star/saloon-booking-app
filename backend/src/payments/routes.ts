import express, { Router } from 'express';
import { z } from 'zod';

import { currentUser, requireAuth } from '../auth/rbac.js';
import { confirmPayment } from '../bookings/service.js';
import { prisma } from '../db.js';
import { badRequest, forbidden, notFound } from '../lib/errors.js';
import { bookingJson } from '../lib/serialize.js';
import { verifyCheckoutSignature, verifyWebhookSignature } from './razorpay.js';

const checkoutResult = z.object({
  razorpay_order_id: z.string().min(1),
  razorpay_payment_id: z.string().min(1),
  razorpay_signature: z.string().min(1),
});

export const paymentsRouter = Router();

/** Called by the app after Razorpay Checkout reports success. */
paymentsRouter.post('/verify', express.json(), requireAuth, async (req, res) => {
  const body = checkoutResult.parse(req.body);
  if (!verifyCheckoutSignature(body.razorpay_order_id, body.razorpay_payment_id, body.razorpay_signature)) {
    throw badRequest('The payment could not be verified.');
  }
  const booking = await prisma.booking.findUnique({ where: { razorpayOrderId: body.razorpay_order_id } });
  if (!booking) throw notFound('Booking not found for this payment.');
  if (booking.customerId !== currentUser(req).id) throw forbidden();

  const updated = await confirmPayment(body.razorpay_order_id, body.razorpay_payment_id);
  res.json(bookingJson(updated));
});

/**
 * Razorpay calls this when a payment is captured, in case the app closed
 * before /verify. Needs the raw body to check the signature.
 */
paymentsRouter.post('/webhook', express.raw({ type: 'application/json', limit: '1mb' }), async (req, res) => {
  const signature = req.header('x-razorpay-signature') ?? '';
  const raw = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
  if (!verifyWebhookSignature(raw, signature)) {
    res.status(400).json({ error: 'Invalid signature.' });
    return;
  }

  const event = JSON.parse(raw.toString('utf8'));
  const payment = event?.payload?.payment?.entity;
  if (
    (event?.event === 'payment.captured' || event?.event === 'order.paid') &&
    typeof payment?.order_id === 'string' &&
    typeof payment?.id === 'string'
  ) {
    try {
      await confirmPayment(payment.order_id, payment.id);
    } catch (error) {
      // An order we do not know (e.g. from another app on the same account).
      console.warn('Razorpay webhook for an unknown order:', payment.order_id, error);
    }
  }
  res.json({ ok: true });
});
