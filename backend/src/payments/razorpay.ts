import { createHmac, timingSafeEqual } from 'node:crypto';

import Razorpay from 'razorpay';

import { config } from '../config.js';

let client: Razorpay | undefined;

export const paymentsEnabled = () => Boolean(config.razorpay);

function razorpay(): Razorpay {
  if (!config.razorpay) throw new Error('Razorpay is not configured.');
  client ??= new Razorpay({ key_id: config.razorpay.keyId, key_secret: config.razorpay.keySecret });
  return client;
}

export interface Order {
  id: string;
  amount: number; // paise
  currency: string;
}

/** Creates a Razorpay order for [totalRupees] (INR). */
export async function createOrder(bookingId: string, totalRupees: number): Promise<Order> {
  const order = await razorpay().orders.create({
    amount: totalRupees * 100,
    currency: 'INR',
    receipt: bookingId.slice(0, 40),
    notes: { booking_id: bookingId },
  });
  return { id: order.id, amount: Number(order.amount), currency: order.currency };
}

const safeEqualHex = (expectedHex: string, actual: string) => {
  const expected = Buffer.from(expectedHex, 'hex');
  const given = Buffer.from(actual, 'hex');
  return expected.length === given.length && timingSafeEqual(expected, given);
};

/** Checks the signature Razorpay Checkout returns after a payment. */
export function verifyCheckoutSignature(orderId: string, paymentId: string, signature: string) {
  if (!config.razorpay) return false;
  const expected = createHmac('sha256', config.razorpay.keySecret)
    .update(`${orderId}|${paymentId}`)
    .digest('hex');
  return safeEqualHex(expected, signature);
}

/** Checks the `X-Razorpay-Signature` header of a webhook call. */
export function verifyWebhookSignature(rawBody: Buffer, signature: string) {
  const secret = config.razorpay?.webhookSecret;
  if (!secret) return false;
  const expected = createHmac('sha256', secret).update(rawBody).digest('hex');
  return safeEqualHex(expected, signature);
}
