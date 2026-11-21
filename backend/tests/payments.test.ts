import { createHmac } from 'node:crypto';

import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';

import { expireStaleHolds, PAYMENT_HOLD_MS } from '../src/bookings/service.js';
import { prisma } from '../src/db.js';
import { app, auth, createSalon, signUp, tomorrowAt } from './helpers.js';

// Never call the real Razorpay API from tests.
let orderCount = 0;
vi.mock('../src/payments/razorpay.js', async (importOriginal) => {
  const original = await importOriginal<typeof import('../src/payments/razorpay.js')>();
  return {
    ...original,
    createOrder: vi.fn(async (_bookingId: string, total: number) => ({
      id: `order_test_${++orderCount}`,
      amount: total * 100,
      currency: 'INR',
    })),
  };
});

const sign = (orderId: string, paymentId: string) =>
  createHmac('sha256', 'rzp_test_secret').update(`${orderId}|${paymentId}`).digest('hex');

async function bookOnline(slotHour = 16) {
  const customer = await signUp('c@example.com');
  const salon = await createSalon();
  const res = await request(app)
    .post('/bookings')
    .set(auth(customer))
    .send({
      salon_id: salon.id,
      slot_start: tomorrowAt(slotHour),
      service_ids: [salon.services[0]!.id],
      payment_method: 'online',
    })
    .expect(201);
  return { customer, salon, booking: res.body.booking, payment: res.body.payment };
}

describe('online payment with Razorpay', () => {
  it('holds the slot and confirms it after a verified payment', async () => {
    const { customer, booking, payment } = await bookOnline();
    expect(booking.status).toBe('pending_payment');
    expect(payment).toMatchObject({ key_id: 'rzp_test_key', amount: 30000, currency: 'INR' });

    await request(app)
      .post('/payments/verify')
      .set(auth(customer))
      .send({ razorpay_order_id: payment.order_id, razorpay_payment_id: 'pay_1', razorpay_signature: 'bad' })
      .expect(400);

    const res = await request(app)
      .post('/payments/verify')
      .set(auth(customer))
      .send({
        razorpay_order_id: payment.order_id,
        razorpay_payment_id: 'pay_1',
        razorpay_signature: sign(payment.order_id, 'pay_1'),
      })
      .expect(200);
    expect(res.body).toMatchObject({ status: 'confirmed', payment_status: 'paid' });
  });

  it('accepts the webhook only with a valid signature', async () => {
    const { payment } = await bookOnline();
    const body = JSON.stringify({
      event: 'payment.captured',
      payload: { payment: { entity: { id: 'pay_2', order_id: payment.order_id } } },
    });

    await request(app)
      .post('/payments/webhook')
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', 'forged')
      .send(body)
      .expect(400);

    await request(app)
      .post('/payments/webhook')
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', createHmac('sha256', 'rzp_webhook_secret').update(body).digest('hex'))
      .send(body)
      .expect(200);
    const booking = await prisma.booking.findUniqueOrThrow({ where: { razorpayOrderId: payment.order_id } });
    expect(booking).toMatchObject({ status: 'confirmed', paymentStatus: 'paid', razorpayPaymentId: 'pay_2' });
  });

  it('frees the slot when the payment is not made in 15 minutes', async () => {
    const { booking, salon } = await bookOnline(17);
    await prisma.booking.update({
      where: { id: booking.id },
      data: { createdAt: new Date(Date.now() - PAYMENT_HOLD_MS - 1000) },
    });
    await expireStaleHolds();
    expect((await prisma.booking.findUniqueOrThrow({ where: { id: booking.id } })).status).toBe('expired');

    const other = await signUp('d@example.com');
    await request(app)
      .post('/bookings')
      .set(auth(other))
      .send({ salon_id: salon.id, slot_start: tomorrowAt(17), service_ids: [salon.services[0]!.id] })
      .expect(201);
  });

  it('flags a refund when a paid booking is cancelled', async () => {
    const { customer, booking, payment } = await bookOnline();
    await request(app)
      .post('/payments/verify')
      .set(auth(customer))
      .send({
        razorpay_order_id: payment.order_id,
        razorpay_payment_id: 'pay_3',
        razorpay_signature: sign(payment.order_id, 'pay_3'),
      })
      .expect(200);
    const res = await request(app).post(`/bookings/${booking.id}/cancel`).set(auth(customer)).expect(200);
    expect(res.body).toMatchObject({ status: 'cancelled', payment_status: 'refund_due' });
  });

  it("customers can't confirm someone else's order", async () => {
    const { payment } = await bookOnline();
    const intruder = await signUp('x@example.com');
    await request(app)
      .post('/payments/verify')
      .set(auth(intruder))
      .send({
        razorpay_order_id: payment.order_id,
        razorpay_payment_id: 'pay_4',
        razorpay_signature: sign(payment.order_id, 'pay_4'),
      })
      .expect(403);
  });
});

describe('assistant', () => {
  it('is switched off without an Anthropic key', async () => {
    const user = await signUp('c@example.com');
    const res = await request(app)
      .post('/assistant/chat')
      .set(auth(user))
      .send({ messages: [{ role: 'user', content: 'Hi' }] })
      .expect(503);
    expect(res.body.error).toMatch(/not set up/);
  });
});
