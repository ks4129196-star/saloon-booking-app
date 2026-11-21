import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'api_client.dart';

/// One live update from the server.
///
/// [type] is one of `salon:changed`, `salon:deleted`, `slots:changed` or
/// `booking:changed`; [data] is the JSON payload.
class RealtimeEvent {
  const RealtimeEvent(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;

  /// The salon this event is about.
  int? get salonId {
    final id = data['salon_id'] ?? (type.startsWith('salon:') ? data['id'] : null);
    return id is num ? id.toInt() : null;
  }
}

/// Live queue, slot and booking updates over Socket.IO while signed in.
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

  void _sessionChanged() {
    final signedIn = ApiClient.instance.userId.value != null;
    if (signedIn && _socket == null) {
      _connect();
    } else if (!signedIn && _socket != null) {
      _socket!.dispose();
      _socket = null;
      _watchedSalons.clear();
    }
  }

  void _connect() {
    final socket = io.io(
      apiUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableReconnection()
          // Read the token on every (re)connect: it is refreshed every 15 min.
          .setAuthFn((callback) => callback({
                'token': ApiClient.instance.accessToken ?? '',
              }))
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
