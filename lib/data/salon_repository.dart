import '../core/api_client.dart';
import '../models/profile.dart';
import '../models/salon.dart';

class RepositoryException implements Exception {
  const RepositoryException(this.message);

  final String message;

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
  Future<List<Profile>> fetchProfiles() =>
      _guard(() async => (await _list(_api.get('/admin/users')))
          .map(Profile.fromJson)
          .toList());

  Future<void> setUserRole(String userId, AppRole role) => _guard(
    () => _api.patch('/admin/users/$userId/role', {'role': role.name}),
  );

  // --------------------------------- Salons ----------------------------------

  Future<List<Salon>> fetchSalons() => _guard(
    () async => (await _list(_api.get('/salons'))).map(Salon.fromJson).toList(),
  );

  /// Salons this user may manage: all of them for admins, owned ones for
  /// owners.
  Future<List<Salon>> fetchManagedSalons(Profile profile) => _guard(
    () async => (await _list(
      _api.get('/salons/managed'),
    )).map(Salon.fromJson).toList(),
  );

  Future<Salon> fetchSalon(int id) =>
      _guard(() async => Salon.fromJson(await _map(_api.get('/salons/$id'))));

  Future<int> createSalon(SalonDraft draft) => _guard(() async {
    final salon = await _map(_api.post('/salons', draft.toJson()));
    return (salon['id'] as num).toInt();
  });

  Future<void> updateSalon(int id, SalonDraft draft) =>
      _guard(() => _api.patch('/salons/$id', draft.toJson()));

  Future<void> setQueue(int salonId, int queue) =>
      _guard(() => _api.patch('/salons/$salonId/queue', {'queue': queue}));

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

  // -------------------------------- Bookings ---------------------------------

  /// Booked slot start times (local), grouped by salon id.
  Future<Map<int, Set<DateTime>>> fetchTakenSlots(
    DateTime from,
    DateTime to, {
    int? salonId,
  }) => _guard(() async {
    final rows = await _list(
      _api.get(
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

  /// Books a slot. For [payOnline], returns the Razorpay details to open
  /// Checkout with; the slot is held for 15 minutes until paid.
  Future<PaymentRequest?> createBooking({
    required int salonId,
    required DateTime slotStart,
    required Iterable<int> serviceIds,
    bool payOnline = false,
  }) => _guard(() async {
    final body = await _map(
      _api.post('/bookings', {
        'salon_id': salonId,
        'slot_start': slotStart.toUtc().toIso8601String(),
        'service_ids': serviceIds.toList(),
        'payment_method': payOnline ? 'online' : 'salon',
      }),
    );
    final payment = body['payment'];
    return payment is Map<String, dynamic>
        ? PaymentRequest.fromJson(payment)
        : null;
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
    () async => (await _list(
      _api.get('/bookings/mine'),
    )).map(Booking.fromJson).toList(),
  );

  /// Bookings for one salon from [from] onwards (owner of that salon or
  /// admin only).
  Future<List<Booking>> fetchSalonBookings(int salonId, DateTime from) =>
      _guard(
        () async => (await _list(
          _api.get(
            '/salons/$salonId/bookings',
            query: {'from': from.toUtc().toIso8601String()},
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
      throw RepositoryException(error.message);
    }
  }
}
