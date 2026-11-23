import { config } from '../config.js';

// `flutter run -d chrome` serves the app from a new random port each run, so
// outside production any localhost origin is accepted. Production only
// accepts the origins listed in CORS_ORIGINS.
const localOrigin = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;

export function isAllowedOrigin(origin: string | undefined): boolean {
  if (!origin) return true; // mobile apps and curl send no Origin header
  if (config.corsOrigins.includes(origin)) return true;
  return !config.isProduction && localOrigin.test(origin);
}

/** Origin check in the callback form both `cors` and Socket.IO accept. */
export function corsOrigin(
  origin: string | undefined,
  callback: (error: Error | null, allow?: boolean) => void,
) {
  callback(null, isAllowedOrigin(origin));
}
