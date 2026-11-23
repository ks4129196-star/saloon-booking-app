import '../core/api_client.dart';
import '../models/profile.dart';
import '../models/salon.dart';

class RepositoryException implements Exception {
  const RepositoryException(this.message, {this.code});

  final String message;

  /// The server's error code, e.g. `appointment_clash`.
  final String? code;

  @override
  String toString() => message;
}

/// Razorpay Checkout details for a booking paid online.
class PaymentRequest {
  const PaymentRequest({
    required this.keyId,
    required this.orderId,
    required this.amount,
    required this.currency,
    required this.name,
    required this.email,
  });

  final String keyId;
  final String orderId;
  final int amount; // paise
  final String currency;
  final String name;
  final String email;

  factory PaymentRequest.fromJson(Map<String, dynamic> json) => PaymentRequest(
    keyId: json['key_id'] as String,
    orderId: json['order_id'] as String,
    amount: (json['amount'] as num).toInt(),
    currency: json['currency'] as String,
    name: json['name'] as String,
    email: json['prefill_email'] as String,
  );
}

/// All reads and writes for salons, bookings and profiles, through the
/// Salon Finder API. The server enforces every permission; a request the
/// user is not allowed to make fails here no matter what the UI shows.
class SalonRepository {
  SalonRepository([ApiClient? api]) : _api = api ?? ApiClient.instance;

  final ApiClient _api;

  // -------------------------------- Profiles ---------------------------------

  /// The signed-in user's profile ([userId] is checked against it).
  Future<Profile> fetchProfile(String userId) => _guard(() async {
    final profile = Profile.fromJson(await _map(_api.get('/me')));
    if (profile.id != userId) {
      throw const RepositoryException('Please sign in again.');
    }
    return profile;
  });

  /// Admins only.
  Future<List<Profile>> fetchProfiles() => _guard(
    () async =>
        (await _list(_api.get('/admin/users'))).map(Profile.fromJson).toList(),
  );

  Future<void> setUserRole(String userId, AppRole role) => _guard(
    () => _api.patch('/admin/users/$userId/role', {'role': role.name}),
  );

  // --------------------------------- Salons ----------------------------------

  Future<List<Salon>> fetchSalons() => _guard(
    () async =>
        (await _list(_api.getPublic('/salons'))).map(Salon.fromJson).toList(),
  );

  /// Salons this user may manage: all of them for admins, owned ones for
  /// owners.
  Future<List<Salon>> fetchManagedSalons(Profile profile) => _guard(
    () async =>
        (await _list(_api.get('/salons/managed'))).map(Salon.fromJson).toList(),
  );

  Future<Salon> fetchSalon(int id) => _guard(
    () async => Salon.fromJson(await _map(_api.getPublic('/salons/$id'))),
  );

  Future<int> createSalon(SalonDraft draft) => _guard(() async {
    final salon = await _map(_api.post('/salons', draft.toJson()));
    return (salon['id'] as num).toInt();
  });

  Future<void> updateSalon(int id, SalonDraft draft) =>
      _guard(() => _api.patch('/salons/$id', draft.toJson()));

  Future<void> deleteSalon(int id) => _guard(() => _api.delete('/salons/$id'));

  // -------------------------------- Services ---------------------------------

  Future<void> saveService({
    int? id,
    required int salonId,
    required String name,
    required int price,
    required int minutes,
    required String category,
  }) => _guard(() {
    final values = {
      'name': name,
      'price': price,
      'minutes': minutes,
      'category': category,
    };
    return id == null
        ? _api.post('/salons/$salonId/services', values)
        : _api.patch('/services/$id', values);
  });

  Future<void> deleteService(int id) =>
      _guard(() => _api.delete('/services/$id'));

  // --------------------------------- Chairs ----------------------------------

  /// Adds a chair; the server names it "Chair N" when [name] is null.
  Future<Chair> addChair(int salonId, {String? name}) => _guard(
    () async => Chair.fromJson(
      await _map(_api.post('/salons/$salonId/chairs', {'name': ?name})),
    ),
  );

  Future<Chair> updateChair(int id, {String? name, ChairStatus? status}) =>
      _guard(
        () async => Chair.fromJson(
          await _map(
            _api.patch('/chairs/$id', {'name': ?name, 'status': ?status?.wire}),
          ),
        ),
      );

  Future<void> deleteChair(int id) => _guard(() => _api.delete('/chairs/$id'));

  // ------------------------------ Walk-in queue ------------------------------

  /// The queue as anyone sees it: token numbers and estimates, no names.
  Future<QueueView> fetchQueue(int salonId) => _guard(
    () async => QueueView.fromJson(
      await _map(_api.getPublic('/salons/$salonId/queue')),
    ),
  );

  /// Takes a token for the signed-in customer.
  Future<QueueToken> joinQueue(
    int salonId, {
    Iterable<int> serviceIds = const [],
    String? customerName,
    String? customerPhone,
  }) => _guard(
    () async => QueueToken.fromJson(
      await _map(
        _api.post('/salons/$salonId/queue', {
          'service_ids': serviceIds.toList(),
          'customer_name': ?customerName,
          'customer_phone': ?customerPhone,
        }),
      ),
    ),
  );

  /// The signed-in customer's active token, if any.
  Future<QueueToken?> fetchMyToken() => _guard(() async {
    final tokens = (await _list(_api.get('/queue/mine')))
        .map(QueueToken.fromJson)
        .toList();
    return tokens.isEmpty ? null : tokens.first;
  });

  // Staff:

  /// Today's tokens with names (owner of the salon or admin).
  Future<QueueView> fetchManagedQueue(int salonId) => _guard(
    () async => QueueView.managed(
      await _map(_api.get('/salons/$salonId/queue/manage')),
    ),
  );

  /// Adds someone who walked in without the app.
  Future<QueueToken> addWalkIn(
    int salonId, {
    required String customerName,
    String? customerPhone,
    Iterable<int> serviceIds = const [],
    int? minutes,
  }) => _guard(
    () async => QueueToken.fromJson(
      await _map(
        _api.post('/salons/$salonId/queue/walk-in', {
          'customer_name': customerName,
          'customer_phone': ?customerPhone,
          'service_ids': serviceIds.toList(),
          'minutes': ?minutes,
        }),
      ),
    ),
  );

  /// `call`, `start`, `done`, `no_show` (staff) or `cancel`. [force] starts
  /// even though an appointment is due on that chair soon.
  Future<QueueToken> tokenAction(
    String tokenId,
    String action, {
    int? chairId,
    bool force = false,
  }) => _guard(
    () async => QueueToken.fromJson(
      await _map(
        _api.post('/queue/$tokenId/$action', {
          'chair_id': ?chairId,
          if (force) 'force': true,
        }),
      ),
    ),
  );

  // -------------------------------- Bookings ---------------------------------

  /// Booked slot start times (local), grouped by salon id.
  Future<Map<int, Set<DateTime>>> fetchTakenSlots(
    DateTime from,
    DateTime to, {
    int? salonId,
  }) => _guard(() async {
    final rows = await _list(
      _api.getPublic(
        '/bookings/taken-slots',
        query: {
          'from': from.toUtc().toIso8601String(),
          'to': to.toUtc().toIso8601String(),
          if (salonId != null) 'salon_id': '$salonId',
        },
      ),
    );
    final out = <int, Set<DateTime>>{};
    for (final row in rows) {
      out
          .putIfAbsent((row['salon_id'] as num).toInt(), () => {})
          .add(DateTime.parse(row['slot_start'] as String).toLocal());
    }
    return out;
  });

  /// Start times on [day] (the salon's calendar day) for an appointment of
  /// [minutes], each with the chairs free for all of it.
  Future<List<AvailableSlot>> fetchAvailability(
    int salonId,
    DateTime day,
    int minutes,
  ) => _guard(() async {
    final date =
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final body = await _map(
      _api.getPublic(
        '/salons/$salonId/availability',
        query: {'date': date, 'minutes': '$minutes'},
      ),
    );
    return ((body['slots'] as List?) ?? const [])
        .map((e) => AvailableSlot.fromJson(e as Map<String, dynamic>))
        .toList();
  });

  /// Books an appointment on [chairId], or any free chair when null.
  /// Returns the booking and, for [payOnline], the Razorpay details to open
  /// Checkout with; the chair is held for 15 minutes until paid.
  Future<(Booking, PaymentRequest?)> createBooking({
    required int salonId,
    required DateTime slotStart,
    required Iterable<int> serviceIds,
    bool payOnline = false,
    int? chairId,
    String? customerName,
    String? customerPhone,
    String? notes,
  }) => _guard(() async {
    final body = await _map(
      _api.post('/bookings', {
        'salon_id': salonId,
        'slot_start': slotStart.toUtc().toIso8601String(),
        'service_ids': serviceIds.toList(),
        'payment_method': payOnline ? 'online' : 'salon',
        'chair_id': ?chairId,
        'customer_name': ?customerName,
        'customer_phone': ?customerPhone,
        'notes': ?notes,
      }),
    );
    final payment = body['payment'];
    return (
      Booking.fromJson(body['booking'] as Map<String, dynamic>),
      payment is Map<String, dynamic> ? PaymentRequest.fromJson(payment) : null,
    );
  });

  /// Sends Razorpay Checkout's result to the server, which checks the
  /// signature and confirms the booking.
  Future<void> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) => _guard(
    () => _api.post('/payments/verify', {
      'razorpay_order_id': orderId,
      'razorpay_payment_id': paymentId,
      'razorpay_signature': signature,
    }),
  );

  Future<List<Booking>> fetchMyBookings(String userId) => _guard(
    () async =>
        (await _list(_api.get('/bookings/mine')))
            .map(Booking.fromJson)
            .toList(),
  );

  /// Bookings for one salon from [from] (until [to]); owner of that salon or
  /// admin only.
  Future<List<Booking>> fetchSalonBookings(
    int salonId,
    DateTime from, {
    DateTime? to,
  }) => _guard(
    () async => (await _list(
      _api.get(
        '/salons/$salonId/bookings',
        query: {
          'from': from.toUtc().toIso8601String(),
          if (to != null) 'to': to.toUtc().toIso8601String(),
        },
      ),
    )).map(Booking.fromJson).toList(),
  );

  Future<void> cancelBooking(String bookingId) =>
      _guard(() => _api.post('/bookings/$bookingId/cancel'));

  // --------------------------------- Helpers ---------------------------------

  static Future<Map<String, dynamic>> _map(Future<Object?> response) async =>
      (await response) as Map<String, dynamic>;

  static Future<List<Map<String, dynamic>>> _list(
    Future<Object?> response,
  ) async => ((await response) as List).cast<Map<String, dynamic>>();

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on ApiException catch (error) {
      throw RepositoryException(error.message, code: error.code);
    }
  }
}
