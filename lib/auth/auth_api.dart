import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthApiException implements Exception {
  const AuthApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthApi {
  GoTrueClient get _auth => Supabase.instance.client.auth;

  Future<void> register(String email, String password) async {
    try {
      final response = await _auth.signUp(email: email, password: password);
      if (response.session != null) {
        await _auth.signOut();
        throw const AuthApiException(
          'Email confirmation is disabled in Supabase. Enable it in '
          'Authentication settings to require the verification code.',
        );
      }
    } on AuthApiException {
      rethrow;
    } on AuthException catch (error) {
      throw AuthApiException(error.message);
    } catch (error) {
      _logUnexpectedError(error);
      throw const AuthApiException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
  }

  Future<void> login(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (error) {
      throw AuthApiException(error.message);
    } catch (error) {
      _logUnexpectedError(error);
      throw const AuthApiException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
  }

  Future<void> resendCode(String email) async {
    try {
      await _auth.resend(type: OtpType.signup, email: email);
    } on AuthException catch (error) {
      throw AuthApiException(error.message);
    } catch (error) {
      _logUnexpectedError(error);
      throw const AuthApiException(
        'Could not resend the code. Check your connection and try again.',
      );
    }
  }

  Future<void> verifyCode(
    String email,
    String code,
  ) async {
    try {
      final response = await _auth.verifyOTP(
        type: OtpType.signup,
        email: email,
        token: code,
      );
      if (response.session == null) {
        throw const AuthApiException(
          'Email verification did not create a session. Please try again.',
        );
      }
    } on AuthApiException {
      rethrow;
    } on AuthException catch (error) {
      throw AuthApiException(error.message);
    } catch (error) {
      _logUnexpectedError(error);
      throw const AuthApiException(
        'Could not verify the code. Check your connection and try again.',
      );
    }
  }

  void _logUnexpectedError(Object error) {
    if (kDebugMode) debugPrint('Supabase authentication failed: $error');
  }
}
