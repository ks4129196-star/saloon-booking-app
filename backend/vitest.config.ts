import { defineConfig } from 'vitest/config';

export const TEST_DB_PORT = 54329;

export default defineConfig({
  test: {
    globalSetup: ['tests/global-setup.ts'],
    fileParallelism: false, // one shared in-memory database
    testTimeout: 20_000,
    hookTimeout: 60_000,
    env: {
      NODE_ENV: 'test',
      DATABASE_URL: `postgresql://postgres:postgres@127.0.0.1:${TEST_DB_PORT}/postgres?sslmode=disable`,
      JWT_SECRET: 'test-jwt-secret-that-is-long-enough-1234567890',
      CODE_SECRET: 'test-code-secret-that-is-long-enough-1234567890',
      SMTP_HOST: '',
      RAZORPAY_KEY_ID: 'rzp_test_key',
      RAZORPAY_KEY_SECRET: 'rzp_test_secret',
      RAZORPAY_WEBHOOK_SECRET: 'rzp_webhook_secret',
      ANTHROPIC_API_KEY: '',
    },
  },
});
