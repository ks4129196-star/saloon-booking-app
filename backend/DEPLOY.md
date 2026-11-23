# Put the API online (free)

The API runs on **Render** (free web service) with the database on **Neon**
(free PostgreSQL). Neither needs a credit card. About 15 minutes.

> Render's free plan sleeps after 15 minutes without visitors. The first
> request after that takes about a minute while it wakes up; then it is fast.
> Upgrade the plan (or move to Railway/Fly.io with the same Dockerfile) before
> a real launch.

## 1. Database on Neon

1. Go to <https://neon.tech> and sign up (GitHub or Google login is fine).
2. Create a project: name `salon-finder`, region **AWS Asia Pacific
   (Singapore)**, Postgres version: the default.
3. On the project dashboard click **Connect**, and copy the connection
   string. It looks like
   `postgresql://user:password@ep-xxxx.ap-southeast-1.aws.neon.tech/neondb?sslmode=require`.
   Keep it private: anyone with it can read the database.

## 2. API on Render

1. Go to <https://render.com> and sign up **with GitHub**, so Render can see
   the `saloon-booking-app` repository.
2. Click **New → Blueprint**, pick `saloon-booking-app`, and choose the branch
   that has `render.yaml` (e.g. `main`).
3. Render reads `render.yaml` and asks for **DATABASE_URL**: paste the Neon
   connection string. Click **Apply**.
4. Wait for the deploy (5–10 minutes the first time). It creates the tables
   by itself. When it shows **Live**, open
   `https://salon-finder-api.onrender.com/health` (your exact address is at the
   top of the service page). You should see `"database":true`.

## 3. Demo salons and your admin account

In Render, open the service → **Shell** (or run these on your computer with
`DATABASE_URL` in `backend/.env` set to the Neon string):

```
npx prisma db seed
```

Then sign up in the app (step 4). The 6-digit code appears in Render's
**Logs** tab (`[dev mail] signup code for you@example.com: 123456`). Then in
the Shell:

```
npx tsx prisma/make-admin.ts you@example.com
```

## 4. Point the app at it

```
flutter run -d chrome --dart-define=API_URL=https://salon-finder-api.onrender.com
```

For a phone build use the same `--dart-define` with `flutter build apk`.

If you later host the **web** app (e.g. on Firebase Hosting or Netlify), add
its address in Render → Environment: `CORS_ORIGINS=https://your-web-app.web.app`.
Phone apps don't need this.

## 5. Before real customers: email

Customers need the sign-up code by email. Free options:

- **Brevo** (<https://brevo.com>, 300 emails/day free): Settings → SMTP & API →
  create an SMTP key. Host `smtp-relay.brevo.com`, port `587`.
- **Gmail**: turn on 2-step verification, then create an *App password* at
  <https://myaccount.google.com/apppasswords>. Host `smtp.gmail.com`, port
  `465`, user = your Gmail address, password = the app password.

In Render → Environment add `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`,
`SMTP_PASSWORD`, `MAIL_FROM` (e.g. `Salon Finder <you@gmail.com>`), and
**delete `LOGIN_CODES_IN_LOG`**. Render redeploys by itself.

## Optional

- **Payments**: add `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`,
  `RAZORPAY_WEBHOOK_SECRET`. **Assistant**: add `ANTHROPIC_API_KEY`.
- **Your own domain**: Render → Settings → Custom Domains → add
  `api.yourdomain.com`, then add the CNAME record it shows at your domain
  registrar.
- **Railway / Fly.io / Koyeb** also work: deploy `backend/` with its
  `Dockerfile` and set the same variables (`NODE_ENV=production`,
  `DATABASE_URL`, `JWT_SECRET`, `CODE_SECRET` of 32+ random characters).
