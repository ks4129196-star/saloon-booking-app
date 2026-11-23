import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Address of the Salon Finder API (the `backend/` folder).
///
/// Pass `--dart-define=API_URL=https://api.yourdomain.com` for real builds.
/// The default reaches a server running on this computer; the Android
/// emulator sees this computer as 10.0.2.2.
const apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://localhost:4000',
);

class ApiException implements Exception {
  const ApiException(this.message, {this.status, this.code});

  final String message;
  final int? status;
  final String? code;

  @override
  String toString() => message;
}

/// Talks to the API and keeps the signed-in session.
///
/// The access token lives in memory; the refresh token is kept in the
/// platform's secure storage so the user stays signed in between launches.
/// A request that gets 401 refreshes the tokens once and is retried.
class ApiClient {
  ApiClient._();

  static final instance = ApiClient._();

  static const _refreshKey = 'salon_finder.refresh_token';
  static const _timeout = Duration(seconds: 20);

  final _storage = const FlutterSecureStorage();
  final _http = http.Client();

  String? _accessToken;
  String? _refreshToken;
  Future<bool>? _refreshing;

  /// The signed-in user's id, or null when signed out.
  final userId = ValueNotifier<String?>(null);

  String? get accessToken => _accessToken;

  /// Restores the session saved on this device, if it is still valid.
  Future<void> restoreSession() async {
    try {
      _refreshToken = await _storage.read(key: _refreshKey);
    } catch (_) {
      _refreshToken = null;
    }
    if (_refreshToken == null) return;
    try {
      if (await _refresh()) {
        final me = await get('/me') as Map<String, dynamic>;
        userId.value = me['id'] as String;
      }
    } on ApiException {
      // Offline or the session expired: the user signs in again.
    }
  }

  /// Stores the tokens returned by a successful sign-in.
  Future<void> startSession(Map<String, dynamic> body) async {
    await _saveTokens(body);
    final user = body['user'] as Map<String, dynamic>;
    userId.value = user['id'] as String;
  }

  Future<void> endSession() async {
    final refresh = _refreshToken;
    await _clearTokens();
    if (refresh != null) {
      try {
        await _send('POST', '/auth/logout', body: {'refresh_token': refresh});
      } catch (_) {
        // Offline: the token is already gone from this device.
      }
    }
  }

  Future<Object?> get(String path, {Map<String, String>? query}) =>
      _authed('GET', path, query: query);

  Future<Object?> post(String path, [Object? body]) =>
      _authed('POST', path, body: body);

  Future<Object?> patch(String path, [Object? body]) =>
      _authed('PATCH', path, body: body);

  Future<Object?> delete(String path) => _authed('DELETE', path);

  /// A request that needs no session (sign-up, login, codes).
  Future<Object?> getPublic(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  Future<Object?> postPublic(String path, Object body) =>
      _send('POST', path, body: body);

  Future<Object?> _authed(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (_accessToken == null && !await _refresh()) {
      throw const ApiException('Please sign in again.', status: 401);
    }
    try {
      return await _send(method, path, body: body, query: query, auth: true);
    } on ApiException catch (error) {
      if (error.status != 401 || !await _refresh()) rethrow;
      return _send(method, path, body: body, query: query, auth: true);
    }
  }

  /// Gets a new token pair. Several callers share one refresh.
  Future<bool> _refresh() {
    return _refreshing ??= () async {
      try {
        final token = _refreshToken;
        if (token == null) return false;
        final body = await _send(
          'POST',
          '/auth/refresh',
          body: {'refresh_token': token},
        );
        await _saveTokens(body as Map<String, dynamic>);
        return true;
      } on ApiException catch (error) {
        if (error.status == 401) {
          await _clearTokens(); // revoked or expired: sign out
        }
        return false;
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<void> _saveTokens(Map<String, dynamic> body) async {
    _accessToken = body['access_token'] as String;
    _refreshToken = body['refresh_token'] as String;
    try {
      await _storage.write(key: _refreshKey, value: _refreshToken);
    } catch (error) {
      if (kDebugMode) debugPrint('Could not save the session: $error');
    }
  }

  Future<void> _clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    userId.value = null;
    try {
      await _storage.delete(key: _refreshKey);
    } catch (_) {}
  }

  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = false,
  }) async {
    final request = http.Request(
      method,
      Uri.parse('$apiUrl$path').replace(queryParameters: query),
    );
    request.headers['Accept'] = 'application/json';
    if (auth && _accessToken != null) {
      request.headers['Authorization'] = 'Bearer $_accessToken';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(_timeout),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('$method $path failed: $error');
      throw const ApiException(
        'Could not reach the server. Check your connection and try again.',
      );
    }

    final text = utf8.decode(response.bodyBytes);
    final Object? json = text.isEmpty ? null : _tryDecode(text);
    if (response.statusCode >= 200 && response.statusCode < 300) return json;

    final error = json is Map ? json : const {};
    throw ApiException(
      (error['error'] as String?) ?? 'Something went wrong. Please try again.',
      status: response.statusCode,
      code: error['code'] as String?,
    );
  }

  static Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}
