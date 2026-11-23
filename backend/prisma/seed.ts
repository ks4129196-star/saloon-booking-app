// Demo salons around central New Delhi (fake names, phones and prices).
// Run with `npm run db:seed`. Does nothing if salons already exist.

import 'dotenv/config';

import { PrismaPg } from '@prisma/adapter-pg';

import { PrismaClient } from '../src/generated/prisma/client.js';

const prisma = new PrismaClient({
  adapter: new PrismaPg({ connectionString: process.env.DATABASE_URL! }),
});

const LAT0 = 28.6139;
const LON0 = 77.209;

type DemoService = [name: string, price: number, minutes: number, category: string];

const menu: Record<string, DemoService[]> = {
  unisex: [
    ["Men's Haircut", 250, 30, 'Hair'],
    ["Women's Haircut", 500, 45, 'Hair'],
    ['Hair Wash & Blow Dry', 350, 30, 'Hair'],
    ['Beard Trim', 150, 15, 'Grooming'],
    ['Fruit Facial', 800, 45, 'Skin'],
  ],
  barber: [
    ['Haircut', 200, 30, 'Hair'],
    ['Haircut + Beard', 300, 40, 'Hair'],
    ['Clean Shave', 120, 20, 'Grooming'],
    ['Beard Styling', 180, 20, 'Grooming'],
  ],
  parlour: [
    ['Hair Spa', 900, 60, 'Hair'],
    ['Gold Facial', 1500, 60, 'Skin'],
    ['Manicure', 500, 40, 'Nails'],
    ['Eyebrow Threading', 60, 10, 'Grooming'],
    ['Bridal Makeup', 12000, 180, 'Makeup'],
  ],
  premium: [
    ['Signature Haircut', 1200, 45, 'Hair'],
    ['Keratin Treatment', 6500, 150, 'Hair'],
    ['Swedish Massage (60 min)', 3000, 60, 'Spa'],
    ['Hydra Facial', 4000, 60, 'Skin'],
  ],
};

// name, type, menu, address, phone, rating, reviews, metres east, metres north,
// opens, closes (minutes from midnight), staff, queue, highlights
const salons: [string, string, keyof typeof menu, string, string, number, number, number, number, number, number, number, number, string[]][] = [
  ['Glow & Go Unisex Salon', 'Unisex Salon', 'unisex', 'Shop 12, Main Market Road', '+91 98765 00001', 4.6, 412, 300, 400, 600, 1260, 4, 2, ['AC', 'Card / UPI accepted', 'Parking']],
  ['The Royal Barber', 'Barber Shop', 'barber', '14, Station Road, Near Bus Stand', '+91 98765 00002', 4.4, 268, 700, -200, 540, 1320, 3, 5, ['Men only', 'UPI accepted', 'Walk-ins welcome']],
  ['Bella Beauty Parlour', 'Ladies Parlour', 'parlour', '2nd Floor, Lotus Complex, Garden Lane', '+91 98765 00003', 4.7, 530, -900, 600, 600, 1200, 3, 1, ['Women only', 'AC', 'Bridal specialists']],
  ['Style Studio', 'Unisex Salon', 'unisex', '5, City Square, Ring Road', '+91 98765 00004', 4.3, 190, 1500, 1200, 660, 1260, 5, 4, ['AC', 'Card / UPI accepted', 'Wi-Fi']],
  ['Gents Cut Corner', 'Barber Shop', 'barber', 'Opp. Post Office, Temple Street', '+91 98765 00005', 4.1, 96, -400, -1100, 480, 1230, 2, 0, ['Men only', 'No waiting usually', 'Cash only']],
  ['Pink Petals Ladies Parlour', 'Ladies Parlour', 'parlour', 'G-7, Shanti Nagar Market', '+91 98765 00006', 4.5, 321, 2200, -900, 600, 1140, 3, 3, ['Women only', 'Home service available', 'UPI accepted']],
  ["Urban Trim Men's Salon", "Men's Salon", 'barber', '27, Sector 4 Commercial Complex', '+91 98765 00007', 4.2, 154, -2500, 300, 570, 1290, 4, 6, ['Men only', 'AC', 'Card / UPI accepted']],
  ['Serenity Spa & Salon', 'Premium Salon & Spa', 'premium', 'Ground Floor, Crown Mall, Highway Road', '+91 98765 00008', 4.8, 702, 3500, 2000, 600, 1320, 6, 2, ['AC', 'Premium products', 'Parking', 'Card / UPI accepted']],
];

async function main() {
  if ((await prisma.salon.count()) > 0) {
    console.log('Salons already exist; skipping the demo seed.');
    return;
  }
  for (const [name, type, kind, address, phone, rating, reviews, dx, dy, openMin, closeMin, staff, queue, highlights] of salons) {
    await prisma.salon.create({
      data: {
        name,
        type,
        address,
        phone,
        rating,
        reviews,
        lat: LAT0 + dy / 111_320,
        lon: LON0 + dx / (111_320 * Math.cos((LAT0 * Math.PI) / 180)),
        openMin,
        closeMin,
        staff,
        highlights,
        services: {
          create: menu[kind]!.map(([serviceName, price, minutes, category]) => ({
            name: serviceName,
            price,
            minutes,
            category,
          })),
        },
        // One chair per stylist; the first few are busy when people queue.
        chairs: {
          create: Array.from({ length: staff }, (_, i) => ({
            name: `Chair ${i + 1}`,
            status: i < queue ? ('busy' as const) : ('free' as const),
          })),
        },
      },
    });
  }
  console.log(`Added ${salons.length} demo salons.`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
