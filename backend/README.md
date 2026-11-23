# Salon Finder API

Node.js + Express + TypeScript server for the Salon Finder app: sign-up and
login with emailed codes, roles, salons, bookings, live updates (Socket.IO),
Razorpay payments and the Claude assistant.

## 1. Run it locally

You need Node.js 20+ and a PostgreSQL database.

**Database.** Any of these works:

- Docker: `docker run -d --name salon-pg -e POSTGRES_USER=salon -e POSTGRES_PASSWORD=salon -e POSTGRES_DB=salon -p 5432:5432 postgres:17-alpine`
- PostgreSQL installed on Windows: put the user, password and database name
  you want in `DATABASE_URL`, then run `npm run db:setup-local`. It asks for
  the `postgres` admin password, creates that user and database, creates the
  tables and adds the demo salons. Run it again whenever the server logs
  `password authentication failed`.
- A free hosted database from [Neon](https://neon.tech), Railway or Render.
  Copy its connection string.

Use a **new, empty** database. The tables are named `users`, `salons`,
`services` and `bookings`, so don't point it at the old Supabase database,
which already has tables with those names.

**Set up and start:**

```powershell
cd backend
npm install
copy .env.example .env      # then edit .env (see below)
npm run db:migrate          # creates the tables
npm run db:seed             # adds 8 demo salons around New Delhi
npm run dev                 # http://localhost:4000
```

In `.env`, set at least `DATABASE_URL`, `JWT_SECRET` and `CODE_SECRET`.
Make each secret with:

```powershell
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

While `SMTP_HOST` is empty, sign-up and login codes are **printed in the
server's terminal** instead of emailed, so you can test without email.

**Make yourself admin:** sign up in the app, then run

```powershell
npm run make-admin -- you@example.com
```

and give other people roles in the app under **Users & roles**.

## 2. Send code emails from your GoDaddy domain (Resend)

1. Create an account at [resend.com](https://resend.com) and go to
   **Domains → Add domain**. Enter your domain (e.g. `yourdomain.com`).
2. Resend shows 3–4 DNS records (an MX and a TXT record for the `send`
   subdomain, and a TXT record named `resend._domainkey`). In GoDaddy, open
   **My Products → your domain → DNS → Add New Record** and add each one:
   - **Type:** as shown (MX or TXT)
   - **Name:** only the part before your domain, e.g. `send` or
     `resend._domainkey` (GoDaddy adds `.yourdomain.com` itself)
   - **Value:** copy exactly from Resend. For MX, priority `10`.
   - Optional but recommended, a TXT record named `_dmarc` with value
     `v=DMARC1; p=none;`
3. Click **Verify** in Resend. DNS can take from a few minutes to a few hours.
4. In Resend, create an **API key** (Sending access).
5. In `.env`:

   ```
   SMTP_HOST=smtp.resend.com
   SMTP_PORT=465
   SMTP_USER=resend
   SMTP_PASSWORD=re_your_api_key
   MAIL_FROM="Salon Finder <no-reply@yourdomain.com>"
   ```

Any other SMTP provider (Brevo, Gmail with an App Password) works with the
same five settings.

If an email can't be sent, the API answers
`502 We could not send the email right now` and the server log shows the
provider's error (for example `535 Authentication failed` means the
username or password is wrong).

## 3. Razorpay (optional)

1. In the [Razorpay dashboard](https://dashboard.razorpay.com), switch to
   **Test mode** and create API keys (**Settings → API Keys**).
2. Add a webhook (**Settings → Webhooks**): URL
   `https://api.yourdomain.com/payments/webhook`, events `payment.captured`
   and `order.paid`, and a secret of your choice.
3. In `.env` set `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` and
   `RAZORPAY_WEBHOOK_SECRET`.

Without these keys, online payment is off and customers pay at the salon.
Checkout opens on Android and iOS only. A paid booking that is later
cancelled is marked `refund_due`; refund it from the Razorpay dashboard.
Switch to live keys only after testing with test keys.

## 4. Claude assistant (optional)

Set `ANTHROPIC_API_KEY` in `.env` (from
[console.anthropic.com](https://console.anthropic.com)). The model defaults to
`claude-opus-5-5`; change it with `ANTHROPIC_MODEL`. Without a key, the
assistant screen shows "The assistant is not set up yet."

## 5. Put it online

Step-by-step free hosting (Render + Neon): see [DEPLOY.md](DEPLOY.md). The
`Dockerfile` here also works on Railway, Fly.io and Koyeb.

The server needs a host that keeps it running (not serverless functions),
because Socket.IO keeps connections open and a timer releases unpaid slot
holds every minute.

## API overview

All routes except `/auth/*`, `/health` and the Razorpay webhook need
`Authorization: Bearer <access token>`. Errors look like
`{ "error": "message for the user", "code": "machine_code" }`.

| Method & path | Who | What |
| --- | --- | --- |
| `POST /auth/register` | anyone | Create account, email a sign-up code |
| `POST /auth/register/resend` | anyone | New sign-up code (60 s cooldown) |
| `POST /auth/register/verify` | anyone | Check sign-up code, sign in |
| `POST /auth/login` | anyone | Sign in with password |
| `POST /auth/login/code` | anyone | Email a login code |
| `POST /auth/login/code/verify` | anyone | Sign in with the code |
| `POST /auth/refresh` | anyone | Swap a refresh token for new tokens |
| `POST /auth/logout` | anyone | Revoke a refresh token |
| `GET / PATCH /me` | signed in | Own profile (name only) |
| `GET /salons` · `GET /salons/:id` | signed in | Browse salons with services |
| `GET /salons/managed` | owner, admin | Salons you manage |
| `POST /salons` · `PATCH /salons/:id` · `DELETE /salons/:id` | owner (own), admin | Manage salons |
| `GET /salons/:id/availability` | anyone | Free start times and chairs for a day |
| `GET /salons/:id/queue` | anyone | Walk-in queue: numbers and estimates, no names |
| `POST /salons/:id/queue` | signed in | Take a queue token |
| `POST /salons/:id/queue/walk-in` · `GET /salons/:id/queue/manage` | owner (own), admin | Add a walk-in; today's tokens with names |
| `GET /queue/mine` | signed in | Your active token |
| `POST /queue/:id/{call,start,done,no_show,cancel}` | owner (own), admin; cancel also the token's customer | Serve the queue |
| `POST /salons/:id/chairs` · `PATCH /chairs/:id` · `DELETE /chairs/:id` | owner (own), admin | Chairs and their live status |
| `POST /salons/:id/services` · `PATCH /services/:id` · `DELETE /services/:id` | owner (own), admin | Manage services |
| `GET /bookings/taken-slots` | signed in | Booked times only |
| `POST /bookings` | signed in | Book (`payment_method`: `salon` or `online`) |
| `GET /bookings/mine` | signed in | Your bookings |
| `POST /bookings/:id/cancel` | customer (own, upcoming), owner (own salon), admin | Cancel |
| `GET /salons/:id/bookings` | owner (own), admin | A salon's bookings |
| `POST /payments/verify` | signed in | Confirm a Razorpay Checkout payment |
| `POST /payments/webhook` | Razorpay | Payment captured |
| `GET /admin/users` · `PATCH /admin/users/:id/role` | admin | Users and roles |
| `POST /assistant/chat` | signed in | Ask Claude |

**Socket.IO events** (connect with `auth: { token: <access token> }`):
`salon:changed`, `salon:deleted`, `slots:changed` (salon id, time, taken —
never who booked), `booking:changed` (to the customer and to owners who sent
`salon:watch-bookings` with the salon id).

## Security notes

- Passwords are hashed with bcrypt (12 rounds). Codes and refresh tokens are
  stored only as hashes.
- Codes expire after 10 minutes and lock after 5 wrong tries.
- A refresh token works once. Reusing an old one signs that user out
  everywhere, since it means the token was copied.
- Roles are read from the database on every request, so a role change applies
  immediately.
- Sign-in routes are rate limited per IP address.

## Tests

`npm test` runs 38 tests against an in-memory PostgreSQL (no setup needed):
sign-up and login, tokens, roles, booking rules, double-booking, payments,
webhooks and live updates.
