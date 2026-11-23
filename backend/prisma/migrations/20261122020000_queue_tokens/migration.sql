-- Walk-in queue tokens. The waiting count is now counted from tokens, so the
-- typed-in salons.queue number goes.
-- CreateEnum
CREATE TYPE "TokenStatus" AS ENUM ('waiting', 'called', 'serving', 'done', 'no_show', 'cancelled');

-- AlterTable
ALTER TABLE "salons" DROP COLUMN "queue";

-- CreateTable
CREATE TABLE "queue_tokens" (
    "id" UUID NOT NULL,
    "salon_id" INTEGER NOT NULL,
    "day" TEXT NOT NULL,
    "number" INTEGER NOT NULL,
    "customer_id" UUID,
    "customer_name" TEXT NOT NULL DEFAULT '',
    "customer_phone" TEXT NOT NULL DEFAULT '',
    "services" JSONB NOT NULL DEFAULT '[]',
    "minutes" INTEGER NOT NULL,
    "status" "TokenStatus" NOT NULL DEFAULT 'waiting',
    "chair_id" INTEGER,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "called_at" TIMESTAMPTZ,
    "started_at" TIMESTAMPTZ,
    "finished_at" TIMESTAMPTZ,

    CONSTRAINT "queue_tokens_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "queue_tokens_salon_id_day_status_idx" ON "queue_tokens"("salon_id", "day", "status");

-- CreateIndex
CREATE INDEX "queue_tokens_customer_id_status_idx" ON "queue_tokens"("customer_id", "status");

-- CreateIndex
CREATE UNIQUE INDEX "queue_tokens_salon_id_day_number_key" ON "queue_tokens"("salon_id", "day", "number");

-- AddForeignKey
ALTER TABLE "queue_tokens" ADD CONSTRAINT "queue_tokens_salon_id_fkey" FOREIGN KEY ("salon_id") REFERENCES "salons"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "queue_tokens" ADD CONSTRAINT "queue_tokens_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "queue_tokens" ADD CONSTRAINT "queue_tokens_chair_id_fkey" FOREIGN KEY ("chair_id") REFERENCES "chairs"("id") ON DELETE SET NULL ON UPDATE CASCADE;


-- A customer holds at most one active token at a time, in any salon.
CREATE UNIQUE INDEX "queue_tokens_one_active_per_customer"
  ON "queue_tokens" ("customer_id")
  WHERE "customer_id" IS NOT NULL AND "status" IN ('waiting', 'called', 'serving');

ALTER TABLE "queue_tokens"
  ADD CONSTRAINT "queue_tokens_number_positive" CHECK ("number" > 0),
  ADD CONSTRAINT "queue_tokens_minutes_range" CHECK ("minutes" BETWEEN 5 AND 600),
  ADD CONSTRAINT "queue_tokens_name_length" CHECK (length("customer_name") <= 80),
  ADD CONSTRAINT "queue_tokens_phone_length" CHECK (length("customer_phone") <= 30),
  ADD CONSTRAINT "queue_tokens_day_format" CHECK ("day" ~ '^\d{4}-\d{2}-\d{2}$');
