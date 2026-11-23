import 'dart:math' as math;

/// Length of one bookable slot.
const slotMinutes = 30;

class Service {
  const Service({
    required this.id,
    required this.salonId,
    required this.name,
    required this.price,
    required this.minutes,
    required this.category,
  });

  final int id;
  final int salonId;
  final String name;
  final int price; // INR
  final int minutes;
  final String category;

  factory Service.fromJson(Map<String, dynamic> json) => Service(
    id: (json['id'] as num).toInt(),
    salonId: (json['salon_id'] as num).toInt(),
    name: json['name'] as String,
    price: (json['price'] as num).toInt(),
    minutes: (json['minutes'] as num).toInt(),
    category: (json['category'] as String?) ?? 'Other',
  );

  @override
  bool operator ==(Object other) => other is Service && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// What a chair (and the stylist working it) is doing right now.
enum ChairStatus {
  free('free', 'Free'),
  busy('busy', 'Busy'),
  onBreak('on_break', 'On break');

  const ChairStatus(this.wire, this.label);

  /// The value the API uses.
  final String wire;
  final String label;

  static ChairStatus fromWire(String? value) => ChairStatus.values.firstWhere(
    (s) => s.wire == value,
    orElse: () => ChairStatus.free,
  );
}

class Chair {
  const Chair({
    required this.id,
    required this.salonId,
    required this.name,
    required this.status,
    required this.statusSince,
  });

  final int id;
  final int salonId;
  final String name;
  final ChairStatus status;

  /// When [status] last changed (local time).
  final DateTime statusSince;

  factory Chair.fromJson(Map<String, dynamic> json) => Chair(
    id: (json['id'] as num).toInt(),
    salonId: (json['salon_id'] as num).toInt(),
    name: json['name'] as String,
    status: ChairStatus.fromWire(json['status'] as String?),
    statusSince:
        DateTime.tryParse(json['status_since'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
  );

  Chair copyWith({String? name, ChairStatus? status}) => Chair(
    id: id,
    salonId: salonId,
    name: name ?? this.name,
    status: status ?? this.status,
    statusSince: status != null && status != this.status
        ? DateTime.now()
        : statusSince,
  );
}

class Slot {
  const Slot(this.start, {required this.taken});

  final DateTime start;
  final bool taken;
}

class Salon {
  Salon({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.type,
    required this.address,
    required this.phone,
    required this.rating,
    required this.reviews,
    required this.lat,
    required this.lon,
    required this.openMin,
    required this.closeMin,
    required this.staff,
    required this.queue,
    this.liveWait,
    this.hasLiveWait = false,
    this.queuePaused = false,
    this.nowServing = const [],
    required this.highlights,
    required this.services,
    this.chairs = const [],
  });

  final int id;
  final String? ownerId;
  final String name;
  final String type;
  final String address;
  final String phone;
  final double rating;
  final int reviews;
  final double lat;
  final double lon;
  final int openMin; // minutes from midnight
  final int closeMin;
  final int staff;
  final int queue; // tokens waiting or called

  /// The server's estimate for someone joining the queue now (minutes), or
  /// null when closed or paused. Only meaningful when [hasLiveWait].
  final int? liveWait;
  final bool hasLiveWait;

  /// Every chair is on break: the queue is not moving.
  final bool queuePaused;

  /// Token numbers in the chairs right now.
  final List<int> nowServing;
  final List<String> highlights;
  final List<Service> services;
  final List<Chair> chairs;

  /// Metres from the user; filled in by the home screen.
  double distance = 0;

  factory Salon.fromJson(Map<String, dynamic> json) {
    final services =
        ((json['services'] as List?) ?? const [])
            .map((e) => Service.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return Salon(
      id: (json['id'] as num).toInt(),
      ownerId: json['owner_id'] as String?,
      name: json['name'] as String,
      type: (json['type'] as String?) ?? 'Salon',
      address: (json['address'] as String?) ?? '',
      phone: (json['phone'] as String?) ?? '',
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      reviews: (json['reviews'] as num?)?.toInt() ?? 0,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      openMin: (json['open_min'] as num).toInt(),
      closeMin: (json['close_min'] as num).toInt(),
      staff: (json['staff'] as num?)?.toInt() ?? 1,
      queue: (json['queue'] as num?)?.toInt() ?? 0,
      liveWait: (json['wait_minutes'] as num?)?.toInt(),
      hasLiveWait: json.containsKey('wait_minutes'),
      queuePaused: json['queue_paused'] == true,
      nowServing: ((json['now_serving'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
      highlights: ((json['highlights'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      services: services,
      chairs:
          ((json['chairs'] as List?) ?? const [])
              .map((e) => Chair.fromJson(e as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id)),
    );
  }

  int get freeChairs =>
      chairs.where((c) => c.status == ChairStatus.free).length;

  /// Chairs taking customers (free or busy, not on break).
  int get workingChairs =>
      chairs.where((c) => c.status != ChairStatus.onBreak).length;

  /// Every chair is on break, so nobody is being served.
  bool get allChairsOnBreak =>
      queuePaused || (chairs.isNotEmpty && workingChairs == 0);

  bool isOpen(DateTime now) {
    final m = now.hour * 60 + now.minute;
    return m >= openMin && m < closeMin;
  }

  double get avgServiceMinutes => services.isEmpty
      ? slotMinutes.toDouble()
      : services.map((s) => s.minutes).reduce((a, b) => a + b) /
            services.length;

  /// Estimated waiting time in minutes for a walk-in (null when closed).
  ///
  /// The server works this out from the chairs, who is in them, the queue
  /// and booked appointments ([liveWait]). Without it (older server), a rough
  /// guess: the people waiting are shared between the working chairs.
  int? waitMinutes(DateTime now) {
    if (!isOpen(now)) return null;
    if (hasLiveWait) return liveWait;
    if (chairs.isEmpty) {
      return ((queue * avgServiceMinutes) / math.max(staff, 1)).ceil();
    }
    if (freeChairs > queue) return 0;
    return ((queue * avgServiceMinutes) / math.max(workingChairs, 1)).ceil();
  }

  int? get minPrice =>
      services.isEmpty ? null : services.map((s) => s.price).reduce(math.min);

  /// Remaining slots for today. [taken] holds start times already booked.
  List<Slot> slotsToday(DateTime now, Set<DateTime> taken) {
    final day = DateTime(now.year, now.month, now.day);
    final out = <Slot>[];
    for (var m = openMin; m + slotMinutes <= closeMin; m += slotMinutes) {
      final start = day.add(Duration(minutes: m));
      if (!start.isAfter(now)) continue;
      out.add(Slot(start, taken: taken.contains(start)));
    }
    return out;
  }
}

class BookedService {
  const BookedService(this.name, this.price, this.minutes);

  final String name;
  final int price;
  final int minutes;
}

class Booking {
  const Booking({
    required this.id,
    required this.salonId,
    required this.salonName,
    required this.customerEmail,
    required this.slotStart,
    required this.services,
    required this.total,
    required this.minutes,
    required this.status,
    this.paymentStatus = 'unpaid',
    this.chairId,
    this.chairName,
    this.customerName = '',
    this.customerPhone = '',
    this.notes = '',
  });

  final String id;
  final int salonId;
  final String salonName;
  final String customerEmail;

  /// The chair the appointment is on (null for old bookings).
  final int? chairId;
  final String? chairName;
  final String customerName;
  final String customerPhone;
  final String notes;
  final DateTime slotStart; // local time
  final List<BookedService> services;
  final int total;
  final int minutes;

  /// `confirmed`, `pending_payment`, `cancelled` or `expired`.
  final String status;

  /// `unpaid`, `paid` or `refund_due`.
  final String paymentStatus;

  /// Cancelled, or an online payment that was never completed.
  bool get cancelled => status == 'cancelled' || status == 'expired';
  bool get awaitingPayment => status == 'pending_payment';
  bool get paid => paymentStatus == 'paid';

  DateTime get end => slotStart.add(Duration(minutes: minutes));

  /// Holds its chair: confirmed, or waiting for an online payment.
  bool get active => status == 'confirmed' || status == 'pending_payment';

  /// The name to show staff: the one given in the form, else the email.
  String get customerLabel =>
      customerName.trim().isNotEmpty ? customerName.trim() : customerEmail;

  bool isUpcoming(DateTime now) => !cancelled && slotStart.isAfter(now);

  factory Booking.fromJson(Map<String, dynamic> json) {
    final salon = json['salons'];
    return Booking(
      id: json['id'].toString(),
      salonId: (json['salon_id'] as num).toInt(),
      salonName: salon is Map ? (salon['name'] as String? ?? '') : '',
      customerEmail: (json['customer_email'] as String?) ?? '',
      slotStart: DateTime.parse(json['slot_start'] as String).toLocal(),
      services: ((json['services'] as List?) ?? const []).map((e) {
        final m = e as Map<String, dynamic>;
        return BookedService(
          m['name'] as String? ?? '',
          (m['price'] as num?)?.toInt() ?? 0,
          (m['minutes'] as num?)?.toInt() ?? 0,
        );
      }).toList(),
      total: (json['total'] as num).toInt(),
      minutes: (json['minutes'] as num).toInt(),
      status: (json['status'] as String?) ?? 'confirmed',
      paymentStatus: (json['payment_status'] as String?) ?? 'unpaid',
      chairId: (json['chair_id'] as num?)?.toInt(),
      chairName: json['chair_name'] as String?,
      customerName: (json['customer_name'] as String?) ?? '',
      customerPhone: (json['customer_phone'] as String?) ?? '',
      notes: (json['notes'] as String?) ?? '',
    );
  }
}

/// A start time the server says can be booked, with the chairs free for the
/// whole appointment. Empty [chairIds] means fully booked.
class AvailableSlot {
  const AvailableSlot(this.start, this.chairIds);

  final DateTime start; // local time
  final List<int> chairIds;

  bool get available => chairIds.isNotEmpty;

  factory AvailableSlot.fromJson(Map<String, dynamic> json) => AvailableSlot(
    DateTime.parse(json['start'] as String).toLocal(),
    ((json['chair_ids'] as List?) ?? const [])
        .map((e) => (e as num).toInt())
        .toList(),
  );
}

/// Fields an owner or admin can edit.
class SalonDraft {
  SalonDraft({
    required this.ownerId,
    required this.name,
    required this.type,
    required this.address,
    required this.phone,
    required this.lat,
    required this.lon,
    required this.openMin,
    required this.closeMin,
    required this.staff,
    required this.highlights,
  });

  String? ownerId;
  String name;
  String type;
  String address;
  String phone;
  double lat;
  double lon;
  int openMin;
  int closeMin;
  int staff;
  List<String> highlights;

  Map<String, dynamic> toJson() => {
    'owner_id': ownerId,
    'name': name,
    'type': type,
    'address': address,
    'phone': phone,
    'lat': lat,
    'lon': lon,
    'open_min': openMin,
    'close_min': closeMin,
    'staff': staff,
    'highlights': highlights,
  };
}

/// Where a walk-in queue token is.
enum TokenStatus {
  waiting('waiting', 'Waiting'),
  called('called', 'Called'),
  serving('serving', 'In the chair'),
  done('done', 'Done'),
  noShow('no_show', 'No-show'),
  cancelled('cancelled', 'Cancelled');

  const TokenStatus(this.wire, this.label);

  final String wire;
  final String label;

  bool get active => this == waiting || this == called || this == serving;

  static TokenStatus fromWire(String? value) => TokenStatus.values.firstWhere(
    (s) => s.wire == value,
    orElse: () => TokenStatus.waiting,
  );
}

/// A walk-in queue token. The public queue view fills only [number],
/// [status], [chairName] and [estimatedStart]; customers (their own token)
/// and staff get the rest.
class QueueToken {
  const QueueToken({
    required this.number,
    required this.status,
    this.id = '',
    this.salonId,
    this.salonName,
    this.chairId,
    this.chairName,
    this.customerName = '',
    this.customerPhone = '',
    this.walkIn = false,
    this.services = const [],
    this.minutes = 0,
    this.ahead,
    this.estimatedStart,
    this.startedAt,
  });

  final String id;
  final int number;
  final TokenStatus status;
  final int? salonId;
  final String? salonName;
  final int? chairId;
  final String? chairName;
  final String customerName;
  final String customerPhone;

  /// Added by staff for someone at the door, not taken in the app.
  final bool walkIn;
  final List<BookedService> services;
  final int minutes;

  /// People before this token still to be called (null once called).
  final int? ahead;

  /// When this token should get a chair (local time).
  final DateTime? estimatedStart;
  final DateTime? startedAt;

  String get label => '#$number';

  /// The name staff call out: the customer's, else the token number.
  String get callName =>
      customerName.trim().isNotEmpty ? customerName.trim() : 'Token $label';

  DateTime? get expectedEnd => startedAt?.add(Duration(minutes: minutes));

  /// Minutes until [estimatedStart], never negative.
  int? waitFrom(DateTime now) {
    final start = estimatedStart;
    if (start == null) return null;
    final m = (start.difference(now).inSeconds / 60).ceil();
    return m < 0 ? 0 : m;
  }

  factory QueueToken.fromJson(Map<String, dynamic> json) {
    DateTime? time(String key) =>
        DateTime.tryParse(json[key] as String? ?? '')?.toLocal();
    return QueueToken(
      id: (json['id'] as String?) ?? '',
      number: (json['number'] as num).toInt(),
      status: TokenStatus.fromWire(json['status'] as String?),
      salonId: (json['salon_id'] as num?)?.toInt(),
      salonName: json['salon_name'] as String?,
      chairId: (json['chair_id'] as num?)?.toInt(),
      chairName: json['chair_name'] as String?,
      customerName: (json['customer_name'] as String?) ?? '',
      customerPhone: (json['customer_phone'] as String?) ?? '',
      walkIn: json['walk_in'] == true,
      services: ((json['services'] as List?) ?? const []).map((e) {
        final m = e as Map<String, dynamic>;
        return BookedService(
          m['name'] as String? ?? '',
          (m['price'] as num?)?.toInt() ?? 0,
          (m['minutes'] as num?)?.toInt() ?? 0,
        );
      }).toList(),
      minutes: (json['minutes'] as num?)?.toInt() ?? 0,
      ahead: (json['ahead'] as num?)?.toInt(),
      estimatedStart: time('estimated_start'),
      startedAt: time('started_at'),
    );
  }
}

/// A salon's walk-in queue right now.
class QueueView {
  const QueueView({
    required this.open,
    required this.paused,
    required this.waiting,
    required this.waitMinutes,
    required this.nowServing,
    required this.queue,
  });

  final bool open;
  final bool paused;
  final int waiting;

  /// For someone joining now; null when closed or paused.
  final int? waitMinutes;
  final List<QueueToken> nowServing;

  /// Waiting and called tokens, in order. In the staff view
  /// ([QueueView.managed]) every token of the day, finished ones included.
  final List<QueueToken> queue;

  static List<QueueToken> _tokens(Object? list) => ((list as List?) ?? const [])
      .map((e) => QueueToken.fromJson(e as Map<String, dynamic>))
      .toList();

  factory QueueView.fromJson(Map<String, dynamic> json) => QueueView(
    open: json['open'] == true,
    paused: json['paused'] == true,
    waiting: (json['waiting'] as num?)?.toInt() ?? 0,
    waitMinutes: (json['wait_minutes'] as num?)?.toInt(),
    nowServing: _tokens(json['now_serving']),
    queue: _tokens(json['queue']),
  );

  /// The staff view: all of today's tokens with names.
  factory QueueView.managed(Map<String, dynamic> json) {
    final tokens = _tokens(json['tokens']);
    return QueueView(
      open: json['open'] == true,
      paused: json['paused'] == true,
      waiting: (json['waiting'] as num?)?.toInt() ?? 0,
      waitMinutes: (json['wait_minutes'] as num?)?.toInt(),
      nowServing: tokens.where((t) => t.status == TokenStatus.serving).toList(),
      queue: tokens,
    );
  }
}
