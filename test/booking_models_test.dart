import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_first_app/models/salon.dart';

Map<String, dynamic> _booking({
  String status = 'confirmed',
  String name = '',
  int? chairId = 3,
}) => {
  'id': 'b1',
  'salon_id': 1,
  'salons': {'name': 'Test'},
  'chair_id': chairId,
  'chair_name': chairId == null ? null : 'Chair 2',
  'customer_email': 'asha@example.com',
  'customer_name': name,
  'customer_phone': '+91 98765 43210',
  'notes': 'Short on the sides',
  'slot_start': '2026-11-23T04:30:00.000Z',
  'services': [
    {'name': 'Cut', 'price': 300, 'minutes': 45},
  ],
  'total': 300,
  'minutes': 45,
  'status': status,
  'payment_status': 'unpaid',
};

void main() {
  test('reads the chair and customer details of a booking', () {
    final b = Booking.fromJson(_booking(name: 'Asha Verma'));
    expect(b.chairId, 3);
    expect(b.chairName, 'Chair 2');
    expect(b.customerLabel, 'Asha Verma');
    expect(b.customerPhone, '+91 98765 43210');
    expect(b.notes, 'Short on the sides');
    expect(b.slotStart.isUtc, isFalse);
    expect(b.end.difference(b.slotStart), const Duration(minutes: 45));
  });

  test('staff see the email when no name was given', () {
    expect(Booking.fromJson(_booking()).customerLabel, 'asha@example.com');
  });

  test('old bookings without a chair still load', () {
    final b = Booking.fromJson(_booking(chairId: null)..remove('notes'));
    expect(b.chairId, isNull);
    expect(b.chairName, isNull);
    expect(b.notes, '');
  });

  test('only confirmed and unpaid-hold bookings hold their chair', () {
    expect(Booking.fromJson(_booking()).active, isTrue);
    expect(
      Booking.fromJson(_booking(status: 'pending_payment')).active,
      isTrue,
    );
    expect(Booking.fromJson(_booking(status: 'cancelled')).active, isFalse);
    expect(Booking.fromJson(_booking(status: 'expired')).active, isFalse);
  });

  test('reads available start times in local time', () {
    final free = AvailableSlot.fromJson({
      'start': '2026-11-23T04:30:00.000Z',
      'chair_ids': [5, 7],
    });
    expect(free.start, DateTime.utc(2026, 11, 23, 4, 30).toLocal());
    expect(free.chairIds, [5, 7]);
    expect(free.available, isTrue);

    final full = AvailableSlot.fromJson({
      'start': '2026-11-23T05:00:00.000Z',
      'chair_ids': <int>[],
    });
    expect(full.available, isFalse);
  });
}
