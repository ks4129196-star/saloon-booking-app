import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { prisma } from '../src/db.js';
import { app, auth, sentCodes, setMailShouldFail, signUp } from './helpers.js';

const email = 'asha@example.com';
const password = 'correct-horse-1';

describe('sign-up with an emailed code', () => {
  it('creates a customer only after the code is verified', async () => {
    await request(app).post('/auth/register').send({ email: ' Asha@Example.com ', password }).expect(202);
    const code = sentCodes.get(email);
    expect(code).toMatch(/^\d{6}$/);

    // Not verified yet: password login is refused.
    const early = await request(app).post('/auth/login').send({ email, password }).expect(403);
    expect(early.body.error).toMatch(/not verified/);

    const res = await request(app).post('/auth/register/verify').send({ email, code }).expect(200);
    expect(res.body.user).toMatchObject({ email, role: 'customer', email_verified: true });
    expect(res.body.access_token).toBeTruthy();
    expect(res.body.refresh_token).toBeTruthy();

    const me = await request(app).get('/me').set('Authorization', `Bearer ${res.body.access_token}`);
    expect(me.body.email).toBe(email);
  });

  it('stores a bcrypt hash, never the password', async () => {
    await signUp(email);
    const user = await prisma.user.findUniqueOrThrow({ where: { email } });
    expect(user.passwordHash).toMatch(/^\$2[aby]\$12\$/);
    expect(user.passwordHash).not.toContain(password);
  });

  it('rejects a second account for a verified email', async () => {
    await signUp(email);
    const res = await request(app).post('/auth/register').send({ email, password }).expect(409);
    expect(res.body.error).toMatch(/already exists/);
  });

  it('rejects weak passwords and bad emails', async () => {
    await request(app).post('/auth/register').send({ email, password: 'short' }).expect(400);
    await request(app).post('/auth/register').send({ email: 'not-an-email', password }).expect(400);
  });

  it('locks a code after 5 wrong attempts', async () => {
    await request(app).post('/auth/register').send({ email, password }).expect(202);
    const code = sentCodes.get(email)!;
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) {
      await request(app).post('/auth/register/verify').send({ email, code: wrong }).expect(400);
    }
    const res = await request(app).post('/auth/register/verify').send({ email, code }).expect(400);
    expect(res.body.error).toMatch(/wrong or has expired/);
  });

  it('makes the user wait 60 seconds between codes', async () => {
    await request(app).post('/auth/register').send({ email, password }).expect(202);
    const res = await request(app).post('/auth/register/resend').send({ email }).expect(429);
    expect(res.body.error).toMatch(/Please wait \d+ seconds/);
  });

  it('reports an email failure and lets the user retry at once', async () => {
    setMailShouldFail(true);
    const res = await request(app).post('/auth/register').send({ email, password }).expect(502);
    expect(res.body.error).toMatch(/could not send the email/);

    setMailShouldFail(false);
    await request(app).post('/auth/register/resend').send({ email }).expect(202);
    expect(sentCodes.get(email)).toBeTruthy();
  });
});

describe('log in', () => {
  it('works with a password', async () => {
    await signUp(email);
    await request(app).post('/auth/login').send({ email, password }).expect(200);
    const wrong = await request(app).post('/auth/login').send({ email, password: 'wrong-password' }).expect(401);
    expect(wrong.body.error).toBe('Wrong email or password.');
  });

  it('works with an emailed code and never creates accounts', async () => {
    await request(app).post('/auth/login/code').send({ email }).expect(404);

    await signUp(email);
    sentCodes.clear();
    await request(app).post('/auth/login/code').send({ email }).expect(202);
    const res = await request(app)
      .post('/auth/login/code/verify')
      .send({ email, code: sentCodes.get(email) })
      .expect(200);
    expect(res.body.user.email).toBe(email);
  });

  it('a sign-up code cannot be used as a login code', async () => {
    await request(app).post('/auth/register').send({ email, password }).expect(202);
    await request(app)
      .post('/auth/login/code/verify')
      .send({ email, code: sentCodes.get(email) })
      .expect(400);
  });
});

describe('tokens', () => {
  it('rejects missing and forged access tokens', async () => {
    await request(app).get('/me').expect(401);
    await request(app).get('/me').set('Authorization', 'Bearer not-a-jwt').expect(401);
  });

  it('rotates refresh tokens and revokes everything when an old one is reused', async () => {
    const user = await signUp(email);
    const first = await request(app).post('/auth/refresh').send({ refresh_token: user.refreshToken }).expect(200);
    expect(first.body.refresh_token).not.toBe(user.refreshToken);

    // Reusing the rotated token looks like theft: every session ends.
    await request(app).post('/auth/refresh').send({ refresh_token: user.refreshToken }).expect(401);
    await request(app).post('/auth/refresh').send({ refresh_token: first.body.refresh_token }).expect(401);
  });

  it('logout revokes the refresh token', async () => {
    const user = await signUp(email);
    await request(app).post('/auth/logout').send({ refresh_token: user.refreshToken }).expect(204);
    await request(app).post('/auth/refresh').send({ refresh_token: user.refreshToken }).expect(401);
  });

  it('lets users set their name but not their role', async () => {
    const user = await signUp(email);
    const res = await request(app)
      .patch('/me')
      .set(auth(user))
      .send({ full_name: 'Asha', role: 'admin' })
      .expect(200);
    expect(res.body).toMatchObject({ full_name: 'Asha', role: 'customer' });
  });
});
