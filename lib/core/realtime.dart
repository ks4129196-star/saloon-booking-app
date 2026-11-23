import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'api_client.dart';

/// One live update from the server.
///
/// [type] is one of `salon:changed`, `salon:deleted`, `slots:changed`,
/// `booking:changed`, `queue:changed` or `token:changed`; [data] is the JSON
/// payload.
class RealtimeEvent {
  const RealtimeEvent(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;

  /// The salon this event is about.
  int? get salonId {
    final id =
        data['salon_id'] ?? (type.startsWith('salon:') ? data['id'] : null);
    return id is num ? id.toInt() : null;
  }
}

/// Live queue, chair, slot and booking updates over Socket.IO.
///
/// Guests get salon, chair and slot changes; signed-in users also get their
/// bookings. The connection is remade when the user signs in or out so the
/// server puts it in the right rooms.
class Realtime {
  Realtime._() {
    ApiClient.instance.userId.addListener(_sessionChanged);
    _sessionChanged();
  }

  static final instance = Realtime._();

  static const _types = [
    'salon:changed',
    'salon:deleted',
    'slots:changed',
    'booking:changed',
    'queue:changed', // a salon's walk-in queue moved
    'token:changed', // the signed-in customer's own token
  ];

  final _events = StreamController<RealtimeEvent>.broadcast();
  final _watchedSalons = <int>{};
  io.Socket? _socket;

  Stream<RealtimeEvent> get events => _events.stream;

  /// Owners and admins: also receive [salonId]'s bookings.
  void watchSalonBookings(int salonId) {
    _watchedSalons.add(salonId);
    _socket?.emit('salon:watch-bookings', salonId);
  }

  void unwatchSalonBookings(int salonId) {
    _watchedSalons.remove(salonId);
    _socket?.emit('salon:unwatch-bookings', salonId);
  }

  /// Widget tests set this to false: there is no server to connect to.
  @visibleForTesting
  static bool enabled = true;

  String? _connectedAs;

  void _sessionChanged() {
    if (!enabled) return;
    final userId = ApiClient.instance.userId.value;
    if (_socket != null && userId == _connectedAs) return;
    _socket?.dispose();
    _socket = null;
    if (userId == null) _watchedSalons.clear();
    _connectedAs = userId;
    _connect();
  }

  void _connect() {
    final socket = io.io(
      apiUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableReconnection()
          // Read the token on every (re)connect: it is refreshed every 15 min.
          .setAuthFn(
            (callback) =>
                callback({'token': ApiClient.instance.accessToken ?? ''}),
          )
          .build(),
    );
    for (final type in _types) {
      socket.on(type, (payload) {
        if (payload is Map) {
          _events.add(RealtimeEvent(type, Map<String, dynamic>.from(payload)));
        }
      });
    }
    // Rooms are lost when the connection drops; join them again.
    socket.onConnect((_) {
      for (final salonId in _watchedSalons) {
        socket.emit('salon:watch-bookings', salonId);
      }
    });
    socket.onConnectError((error) {
      if (kDebugMode) debugPrint('Live updates unavailable: $error');
    });
    _socket = socket;
  }
}
