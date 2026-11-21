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
    required this.highlights,
    required this.services,
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
  final int queue; // people currently waiting
  final List<String> highlights;
  final List<Service> services;

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
      highlights: ((json['highlights'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      services: services,
    );
  }

  bool isOpen(DateTime now) {
    final m = now.hour * 60 + now.minute;
    return m >= openMin && m < closeMin;
  }

  double get avgServiceMinutes => services.isEmpty
      ? slotMinutes.toDouble()
      : services.map((s) => s.minutes).reduce((a, b) => a + b) /
            services.length;

  /// Estimated waiting time in minutes (null when closed).
  int? waitMinutes(DateTime now) {
    if (!isOpen(now)) return null;
    return ((queue * avgServiceMinutes) / math.max(staff, 1)).ceil();
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
  });

  final String id;
  final int salonId;
  final String salonName;
  final String customerEmail;
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
    );
  }
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
