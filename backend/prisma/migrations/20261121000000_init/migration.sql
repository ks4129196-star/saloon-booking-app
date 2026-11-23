-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "public";

-- CreateEnum
CREATE TYPE "Role" AS ENUM ('customer', 'owner', 'admin');

-- CreateEnum
CREATE TYPE "CodePurpose" AS ENUM ('signup', 'login');

-- CreateEnum
CREATE TYPE "BookingStatus" AS ENUM ('pending_payment', 'confirmed', 'cancelled', 'expired');

-- CreateEnum
CREATE TYPE "PaymentMethod" AS ENUM ('salon', 'online');

-- CreateEnum
CREATE TYPE "PaymentStatus" AS ENUM ('unpaid', 'paid', 'refund_due');

-- CreateTable
CREATE TABLE "users" (
    "id" UUID NOT NULL,
    "email" TEXT NOT NULL,
    "password_hash" TEXT NOT NULL,
    "full_name" TEXT,
    "role" "Role" NOT NULL DEFAULT 'customer',
    "email_verified" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "email_codes" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "purpose" "CodePurpose" NOT NULL,
    "code_hash" TEXT NOT NULL,
    "expires_at" TIMESTAMPTZ NOT NULL,
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "consumed_at" TIMESTAMPTZ,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "email_codes_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "refresh_tokens" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "token_hash" TEXT NOT NULL,
    "expires_at" TIMESTAMPTZ NOT NULL,
    "revoked_at" TIMESTAMPTZ,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "refresh_tokens_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "salons" (
    "id" SERIAL NOT NULL,
    "owner_id" UUID,
    "name" TEXT NOT NULL,
    "type" TEXT NOT NULL DEFAULT 'Salon',
    "address" TEXT NOT NULL DEFAULT '',
    "phone" TEXT NOT NULL DEFAULT '',
    "rating" DECIMAL(2,1) NOT NULL DEFAULT 0,
    "reviews" INTEGER NOT NULL DEFAULT 0,
    "lat" DOUBLE PRECISION NOT NULL,
    "lon" DOUBLE PRECISION NOT NULL,
    "timezone" TEXT NOT NULL DEFAULT 'Asia/Kolkata',
    "open_min" INTEGER NOT NULL,
    "close_min" INTEGER NOT NULL,
    "staff" INTEGER NOT NULL DEFAULT 1,
    "queue" INTEGER NOT NULL DEFAULT 0,
    "highlights" TEXT[] DEFAULT ARRAY[]::TEXT[],
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "salons_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "services" (
    "id" SERIAL NOT NULL,
    "salon_id" INTEGER NOT NULL,
    "name" TEXT NOT NULL,
    "price" INTEGER NOT NULL,
    "minutes" INTEGER NOT NULL,
    "category" TEXT NOT NULL DEFAULT 'Other',

    CONSTRAINT "services_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "bookings" (
    "id" UUID NOT NULL,
    "salon_id" INTEGER NOT NULL,
    "customer_id" UUID NOT NULL,
    "customer_email" TEXT NOT NULL DEFAULT '',
    "slot_start" TIMESTAMPTZ NOT NULL,
    "active_slot" TIMESTAMPTZ,
    "services" JSONB NOT NULL DEFAULT '[]',
    "total" INTEGER NOT NULL,
    "minutes" INTEGER NOT NULL,
    "status" "BookingStatus" NOT NULL DEFAULT 'confirmed',
    "payment_method" "PaymentMethod" NOT NULL DEFAULT 'salon',
    "payment_status" "PaymentStatus" NOT NULL DEFAULT 'unpaid',
    "razorpay_order_id" TEXT,
    "razorpay_payment_id" TEXT,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "bookings_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "users_email_key" ON "users"("email");

-- CreateIndex
CREATE INDEX "email_codes_user_id_purpose_idx" ON "email_codes"("user_id", "purpose");

-- CreateIndex
CREATE UNIQUE INDEX "refresh_tokens_token_hash_key" ON "refresh_tokens"("token_hash");

-- CreateIndex
CREATE INDEX "refresh_tokens_user_id_idx" ON "refresh_tokens"("user_id");

-- CreateIndex
CREATE INDEX "salons_owner_id_idx" ON "salons"("owner_id");

-- CreateIndex
CREATE INDEX "services_salon_id_idx" ON "services"("salon_id");

-- CreateIndex
CREATE UNIQUE INDEX "bookings_razorpay_order_id_key" ON "bookings"("razorpay_order_id");

-- CreateIndex
CREATE INDEX "bookings_salon_id_slot_start_idx" ON "bookings"("salon_id", "slot_start");

-- CreateIndex
CREATE INDEX "bookings_customer_id_idx" ON "bookings"("customer_id");

-- CreateIndex
CREATE UNIQUE INDEX "bookings_salon_id_active_slot_key" ON "bookings"("salon_id", "active_slot");

-- AddForeignKey
ALTER TABLE "email_codes" ADD CONSTRAINT "email_codes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "refresh_tokens" ADD CONSTRAINT "refresh_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "salons" ADD CONSTRAINT "salons_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "services" ADD CONSTRAINT "services_salon_id_fkey" FOREIGN KEY ("salon_id") REFERENCES "salons"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "bookings" ADD CONSTRAINT "bookings_salon_id_fkey" FOREIGN KEY ("salon_id") REFERENCES "salons"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "bookings" ADD CONSTRAINT "bookings_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- Data checks (ported from supabase/migrations).
ALTER TABLE "salons"
  ADD CONSTRAINT "salons_name_length" CHECK (length(trim("name")) BETWEEN 2 AND 80),
  ADD CONSTRAINT "salons_rating_range" CHECK ("rating" BETWEEN 0 AND 5),
  ADD CONSTRAINT "salons_reviews_positive" CHECK ("reviews" >= 0),
  ADD CONSTRAINT "salons_lat_range" CHECK ("lat" BETWEEN -90 AND 90),
  ADD CONSTRAINT "salons_lon_range" CHECK ("lon" BETWEEN -180 AND 180),
  ADD CONSTRAINT "salons_open_range" CHECK ("open_min" BETWEEN 0 AND 1439),
  ADD CONSTRAINT "salons_close_range" CHECK ("close_min" BETWEEN 1 AND 1440),
  ADD CONSTRAINT "salons_hours_order" CHECK ("close_min" > "open_min"),
  ADD CONSTRAINT "salons_staff_range" CHECK ("staff" BETWEEN 1 AND 100),
  ADD CONSTRAINT "salons_queue_range" CHECK ("queue" BETWEEN 0 AND 500);

ALTER TABLE "services"
  ADD CONSTRAINT "services_price_range" CHECK ("price" BETWEEN 0 AND 1000000),
  ADD CONSTRAINT "services_minutes_range" CHECK ("minutes" BETWEEN 5 AND 600);
