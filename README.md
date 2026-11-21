# Salone - Salon Finder

A Flutter app for finding nearby salons and booking a slot, with its own
Node.js server in [`backend/`](backend/).

| Part | Technology |
| --- | --- |
| App | Flutter (Android, iOS, web, Windows, macOS) |
| Server | Node.js + Express + TypeScript |
| Database | PostgreSQL with Prisma |
| Sign-in | Email + password (bcrypt) or a 6-digit emailed code; JWT access tokens with rotating refresh tokens |
| Permissions | Roles: customer, salon owner, admin (checked by the server on every request) |
| Live updates | Socket.IO: queue sizes, booked slots and bookings update without refreshing |
| Payments | Razorpay (UPI / cards), optional; customers can always pay at the salon |
| Assistant | Claude, called from the server so the API key never ships in the app |

## Run it on your computer

1. Start the server: follow [backend/README.md](backend/README.md). It runs on
   `http://localhost:4000`.
2. Run the app:

   ```powershell
   flutter pub get
   flutter run -d windows
   ```

   The app talks to `http://localhost:4000` by default. To use another server:

   ```powershell
   flutter run --dart-define=API_URL=https://api.yourdomain.com
   ```

   On the Android emulator, your computer is `10.0.2.2`:
   `--dart-define=API_URL=http://10.0.2.2:4000`.

Run the app's tests with `flutter test`, and the server's with `npm test` in
`backend/`.

## How it fits together

- **Sign-up:** the server emails a 6-digit code; the account works once the
  code is entered. **Log in** with an emailed code (default) or a password.
  The app stays signed in between launches (the refresh token is kept in the
  device's secure storage).
- **Roles:** every account starts as a customer. Owners create and manage
  their own salons (details, services, live queue, bookings). Admins manage
  everything and assign roles under **Users & roles**.
- **Booking:** the server works out the price, checks opening hours and
  makes sure a slot is booked only once.
- **Paying online** (Android and iOS): the slot is held for 15 minutes while
  the customer pays in Razorpay Checkout; the server checks Razorpay's
  signature before confirming.
- The old `supabase/` setup is no longer used.
