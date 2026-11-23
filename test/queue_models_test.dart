import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_first_app/models/salon.dart';
import 'package:flutter_first_app/queue/queue_widgets.dart';

Map<String, dynamic> _salon(Map<String, dynamic> extra) => {
  'id': 1,
  'name': 'Test',
  'lat': 0,
  'lon': 0,
  'open_min': 0,
  'close_min': 1440,
  'staff': 2,
  'queue': 3,
  ...extra,
};

void main() {
  final noon = DateTime(2026, 11, 22, 12);

  test("the salon's wait comes from the server when it sends one", () {
    final salon = Salon.fromJson(
      _salon({
        'wait_minutes': 42,
        'queue_paused': false,
        'now_serving': [4, 5],
      }),
    );
    expect(salon.waitMinutes(noon), 42);
    expect(salon.nowServing, [4, 5]);

    // The server says no estimate (closed or paused).
    final none = Salon.fromJson(_salon({'wait_minutes': null}));
    expect(none.waitMinutes(noon), isNull);

    final paused = Salon.fromJson(
      _salon({'wait_minutes': null, 'queue_paused': true}),
    );
    expect(paused.allChairsOnBreak, isTrue);
  });

  test('reads a customer token with its place and estimate', () {
    final t = QueueToken.fromJson({
      'id': 't1',
      'number': 7,
      'status': 'waiting',
      'salon_id': 1,
      'salon_name': 'Test',
      'chair_id': null,
      'chair_name': null,
      'customer_name': 'Asha',
      'walk_in': false,
      'services': [
        {'name': 'Cut', 'price': 300, 'minutes': 30},
      ],
      'minutes': 30,
      'ahead': 2,
      'estimated_start': '2026-11-22T10:25:00.000Z',
    });
    expect(t.label, '#7');
    expect(t.status, TokenStatus.waiting);
    expect(t.status.active, isTrue);
    expect(t.ahead, 2);
    expect(t.callName, 'Asha');
    expect(t.estimatedStart!.isUtc, isFalse);
    final before = DateTime.utc(2026, 11, 22, 10, 0).toLocal();
    expect(t.waitFrom(before), 25);
    expect(t.waitFrom(before.add(const Duration(hours: 1))), 0);
  });

  test('public tokens have only a number and status', () {
    final t = QueueToken.fromJson({
      'number': 3,
      'status': 'serving',
      'chair_name': 'Chair 1',
      'estimated_start': null,
    });
    expect(t.callName, 'Token #3');
    expect(t.status.label, 'In the chair');
    expect(t.waitFrom(DateTime.now()), isNull);
  });

  test('the staff view splits out who is in a chair', () {
    final q = QueueView.managed({
      'open': true,
      'paused': false,
      'waiting': 1,
      'wait_minutes': 15,
      'tokens': [
        {'number': 1, 'status': 'done'},
        {'number': 2, 'status': 'serving', 'chair_id': 9},
        {'number': 3, 'status': 'waiting'},
      ],
    });
    expect(q.nowServing.map((t) => t.number), [2]);
    expect(q.queue, hasLength(3));
    expect(TokenStatus.fromWire('no_show'), TokenStatus.noShow);
  });

  test('waits read naturally', () {
    expect(fmtWait(0), 'now');
    expect(fmtWait(12), 'about 12 min');
    expect(fmtWait(60), 'about 1 h');
    expect(fmtWait(95), 'about 1 h 35 min');
  });
}
