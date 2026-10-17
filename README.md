# Salone — Salon Finder

A Flutter salon finder with email/password registration and login. Supabase
Auth sends a signup verification code, and the app opens the salon finder
after signup verification or a successful password login.

## Configure Supabase

1. Create a Supabase project.
2. In **Project Settings → API**, copy the **Project URL** and the
   **anon/publishable key**.
3. In **Authentication → Providers → Email**, enable email signup and turn on
   **Confirm email**. The app depends on this setting to keep signup locked
   until the OTP is verified.
4. In **Authentication → Emails → Confirm signup**, replace the default
   confirmation-link template with a code template. This app verifies the
   six-digit OTP; it does not handle confirmation links.

   ```html
   <h2>Confirm your signup</h2>
   <p>Your verification code is: {{ .Token }}</p>
   ```

   Use `{{ .Token }}` rather than `{{ .ConfirmationURL }}`. Make sure this
   template is configured in the same Supabase project whose URL and key you
   pass to the app.

5. Supabase's built-in email sender is intended for testing and has low
   sending limits. Configure a custom SMTP provider in Supabase for sustained
   testing or production.

The app includes the project's URL and anon/publishable key as defaults; pass
`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` at run time to override them.
Do not use a Supabase `service_role` key in the Flutter app.

## Run the app

From the repository root, you can run with the default project:

```powershell
flutter pub get
flutter run -d windows
```

To use another project, add `--dart-define=SUPABASE_URL=https://your-project-id.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=your-anon-or-publishable-key`.
For another target, replace `-d windows` with the target you use.

## Authentication flow

- **Register:** `signUp` creates the Supabase user and triggers the Confirm
  signup email OTP.
- **Login:** `signInWithPassword` checks the credentials and the app opens the
  salon finder using the authenticated session. Login does not send a magic
  link or OTP email.
- **Verify:** signup codes use `OtpType.signup`; Supabase stores the resulting
  session after successful verification.
- **Resend:** signup uses Supabase `resend`.

Run Flutter tests with `flutter test` from the repository root.
