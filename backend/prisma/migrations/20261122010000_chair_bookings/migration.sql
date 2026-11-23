-- Bookings now sit on a chair and hold every 30-minute block they need.

-- AlterTable
ALTER TABLE "bookings"
ADD COLUMN     "chair_id" INTEGER,
ADD COLUMN     "customer_name" TEXT NOT NULL DEFAULT '',
ADD COLUMN     "customer_phone" TEXT NOT NULL DEFAULT '',
ADD COLUMN     "notes" TEXT NOT NULL DEFAULT '';

-- CreateTable
CREATE TABLE "booking_slots" (
    "chair_id" INTEGER NOT NULL,
    "slot_start" TIMESTAMPTZ NOT NULL,
    "booking_id" UUID NOT NULL,

    CONSTRAINT "booking_slots_pkey" PRIMARY KEY ("chair_id","slot_start")
);

-- CreateIndex
CREATE INDEX "booking_slots_booking_id_idx" ON "booking_slots"("booking_id");

-- CreateIndex
CREATE INDEX "bookings_chair_id_idx" ON "bookings"("chair_id");

-- AddForeignKey
ALTER TABLE "booking_slots" ADD CONSTRAINT "booking_slots_chair_id_fkey" FOREIGN KEY ("chair_id") REFERENCES "chairs"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "booking_slots" ADD CONSTRAINT "booking_slots_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "bookings"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "bookings" ADD CONSTRAINT "bookings_chair_id_fkey" FOREIGN KEY ("chair_id") REFERENCES "chairs"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- Backfill: every booking goes on its salon's first chair; bookings still
-- holding their slot keep holding it there.
UPDATE "bookings" b
SET "chair_id" = (SELECT min(c."id") FROM "chairs" c WHERE c."salon_id" = b."salon_id");

INSERT INTO "booking_slots" ("chair_id", "slot_start", "booking_id")
SELECT b."chair_id", b."active_slot", b."id"
FROM "bookings" b
WHERE b."active_slot" IS NOT NULL AND b."chair_id" IS NOT NULL
ON CONFLICT DO NOTHING;

-- The one-booking-per-salon-slot rule is replaced by booking_slots.
DROP INDEX "bookings_salon_id_active_slot_key";
ALTER TABLE "bookings" DROP COLUMN "active_slot";

-- Same limits the API applies.
ALTER TABLE "bookings"
  ADD CONSTRAINT "bookings_customer_name_length" CHECK (length("customer_name") <= 80),
  ADD CONSTRAINT "bookings_customer_phone_length" CHECK (length("customer_phone") <= 30),
  ADD CONSTRAINT "bookings_notes_length" CHECK (length("notes") <= 500);
