-- CreateEnum
CREATE TYPE "ChairStatus" AS ENUM ('free', 'busy', 'on_break');

-- CreateTable
CREATE TABLE "chairs" (
    "id" SERIAL NOT NULL,
    "salon_id" INTEGER NOT NULL,
    "name" TEXT NOT NULL,
    "status" "ChairStatus" NOT NULL DEFAULT 'free',
    "status_since" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "chairs_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "chairs_salon_id_idx" ON "chairs"("salon_id");

-- AddForeignKey
ALTER TABLE "chairs" ADD CONSTRAINT "chairs_salon_id_fkey" FOREIGN KEY ("salon_id") REFERENCES "salons"("id") ON DELETE CASCADE ON UPDATE CASCADE;


-- Backfill: give every existing salon one chair per stylist.
INSERT INTO "chairs" ("salon_id", "name")
SELECT s."id", 'Chair ' || n
FROM "salons" s, generate_series(1, GREATEST(s."staff", 1)) AS n
ORDER BY s."id", n;
