import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_first_app/models/profile.dart';
import 'package:flutter_first_app/models/salon.dart';

Salon _salon({int open = 10 * 60, int close = 12 * 60, int queue = 2}) =>
    Salon.fromJson({
      'id': 1,
      'owner_id': 'owner-1',
      'name': 'Test Salon',
      'lat': 28.6,
      'lon': 77.2,
      'open_min': open,
      'close_min': close,
      'staff': 2,
      'queue': queue,
      'services': [
        {'id': 2, 'salon_id': 1, 'name': 'B', 'price': 300, 'minutes': 40},
        {'id': 1, 'salon_id': 1, 'name': 'A', 'price': 100, 'minutes': 20},
      ],
    });

void main() {
  group('AppRole', () {
    test('parses known roles and defaults unknown values to customer', () {
      expect(AppRole.parse('admin'), AppRole.admin);
      expect(AppRole.parse('owner'), AppRole.owner);
      expect(AppRole.parse('superuser'), AppRole.customer);
      expect(AppRole.parse(null), AppRole.customer);
    });

    test('only owners and admins can manage salons', () {
      Profile p(AppRole r) => Profile(id: 'x', email: 'a@b.c', role: r);
      expect(p(AppRole.customer).canManageSalons, isFalse);
      expect(p(AppRole.owner).canManageSalons, isTrue);
      expect(p(AppRole.admin).canManageSalons, isTrue);
      expect(p(AppRole.owner).isAdmin, isFalse);
    });
  });

  group('Salon', () {
    test('parses services sorted by id and computes price and wait', () {
      final s = _salon();
      expect(s.services.map((e) => e.name), ['A', 'B']);
      expect(s.minPrice, 100);
      // 2 waiting × 30 min average ÷ 2 stylists
      expect(s.waitMinutes(DateTime(2026, 1, 1, 11)), 30);
      expect(s.waitMinutes(DateTime(2026, 1, 1, 13)), isNull);
    });

    test('marks booked slots as taken and skips past slots', () {
      final s = _salon();
      final now = DateTime(2026, 1, 1, 10, 15);
      final taken = {DateTime(2026, 1, 1, 11)};
      final slots = s.slotsToday(now, taken);
      expect(slots.map((e) => e.start.hour * 60 + e.start.minute), [
        10 * 60 + 30,
        11 * 60,
        11 * 60 + 30,
      ]);
      expect(slots.map((e) => e.taken), [false, true, false]);
    });

    test('handles a salon without services', () {
      final s = Salon.fromJson({
        'id': 9,
        'name': 'Empty',
        'lat': 0,
        'lon': 0,
        'open_min': 600,
        'close_min': 700,
      });
      expect(s.minPrice, isNull);
      expect(s.waitMinutes(DateTime(2026, 1, 1, 10, 30)), 0);
    });
  });

  test('Booking parses the joined salon name and status', () {
    final b = Booking.fromJson({
      'id': 5,
      'salon_id': 1,
      'salons': {'name': 'Test Salon'},
      'customer_email': 'c@test.local',
      'slot_start': '2030-01-01T06:30:00+00:00',
      'services': [
        {'name': 'A', 'price': 100, 'minutes': 20},
      ],
      'total': 100,
      'minutes': 20,
      'status': 'cancelled',
    });
    expect(b.salonName, 'Test Salon');
    expect(b.cancelled, isTrue);
    expect(b.isUpcoming(DateTime(2026)), isFalse);
    expect(b.slotStart.isUtc, isFalse);
  });
}
