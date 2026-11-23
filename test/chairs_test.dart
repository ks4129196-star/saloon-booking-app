import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_first_app/models/salon.dart';

Map<String, dynamic> _salonJson({
  int queue = 0,
  int staff = 2,
  List<String> chairs = const [],
}) => {
  'id': 1,
  'name': 'Test',
  'lat': 0,
  'lon': 0,
  'open_min': 0,
  'close_min': 1440,
  'staff': staff,
  'queue': queue,
  'services': [
    {'id': 1, 'salon_id': 1, 'name': 'Cut', 'price': 200, 'minutes': 30},
  ],
  'chairs': [
    for (var i = 0; i < chairs.length; i++)
      {
        'id': i + 1,
        'salon_id': 1,
        'name': 'Chair ${i + 1}',
        'status': chairs[i],
        'status_since': '2026-11-22T10:00:00.000Z',
      },
  ],
};

void main() {
  final noon = DateTime(2026, 11, 22, 12);

  test('reads chairs and their status from the API', () {
    final salon = Salon.fromJson(
      _salonJson(chairs: ['free', 'busy', 'on_break']),
    );
    expect(salon.chairs.map((c) => c.status), [
      ChairStatus.free,
      ChairStatus.busy,
      ChairStatus.onBreak,
    ]);
    expect(salon.freeChairs, 1);
    expect(salon.workingChairs, 2);
    expect(salon.allChairsOnBreak, isFalse);
    expect(salon.chairs.first.statusSince.isUtc, isFalse);
  });

  test('an unknown status is treated as free', () {
    final salon = Salon.fromJson(_salonJson(chairs: ['asleep']));
    expect(salon.chairs.single.status, ChairStatus.free);
  });

  test('no wait while more chairs are free than people queue', () {
    final salon = Salon.fromJson(
      _salonJson(queue: 1, chairs: ['free', 'free', 'busy']),
    );
    expect(salon.waitMinutes(noon), 0);
  });

  test('the queue is shared between working chairs, not ones on break', () {
    final salon = Salon.fromJson(
      _salonJson(queue: 4, chairs: ['busy', 'busy', 'on_break']),
    );
    // 4 people x 30 min / 2 working chairs.
    expect(salon.waitMinutes(noon), 60);
  });

  test('salons without chairs still use the stylist count', () {
    final salon = Salon.fromJson(_salonJson(queue: 4, staff: 4));
    expect(salon.chairs, isEmpty);
    expect(salon.waitMinutes(noon), 30);
  });

  test('all chairs on break is reported', () {
    final salon = Salon.fromJson(_salonJson(chairs: ['on_break', 'on_break']));
    expect(salon.allChairsOnBreak, isTrue);
  });

  test('changing status resets when it started; renaming does not', () {
    final chair = Salon.fromJson(_salonJson(chairs: ['free'])).chairs.single;
    expect(chair.copyWith(name: 'Ravi').statusSince, chair.statusSince);
    expect(
      chair
          .copyWith(status: ChairStatus.busy)
          .statusSince
          .isAfter(chair.statusSince),
      isTrue,
    );
  });
}
