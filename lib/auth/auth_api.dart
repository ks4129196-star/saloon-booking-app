import '../core/api_client.dart';

class AuthApiException implements Exception {
  const AuthApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Sign-up and login against the Salon Finder API. Codes are emailed by the
/// server; a successful sign-in is stored in [ApiClient].
class AuthApi {
  ApiClient get _api => ApiClient.instance;

  /// Creates the account and emails a 6-digit verification code.
  Future<void> register(String email, String password) =>
      _call(() => _api.postPublic('/auth/register', {
            'email': email,
            'password': password,
          }));

  Future<void> login(String email, String password) => _signIn(
        () => _api.postPublic('/auth/login', {
          'email': email,
          'password': password,
        }),
      );

  /// Emails a 6-digit login code. Never creates an account.
  Future<void> sendLoginCode(String email) =>
      _call(() => _api.postPublic('/auth/login/code', {'email': email}));

  Future<void> verifyLoginCode(String email, String code) => _signIn(
        () => _api.postPublic('/auth/login/code/verify', {
          'email': email,
          'code': code,
        }),
      );

  /// Sends a new sign-up code.
  Future<void> resendCode(String email) =>
      _call(() => _api.postPublic('/auth/register/resend', {'email': email}));

  /// Checks the sign-up code and signs the user in.
  Future<void> verifyCode(String email, String code) => _signIn(
        () => _api.postPublic('/auth/register/verify', {
          'email': email,
          'code': code,
        }),
      );

  Future<void> signOut() => _api.endSession();

  Future<void> _signIn(Future<Object?> Function() request) async {
    final body = await _call(request);
    await _api.startSession(body as Map<String, dynamic>);
  }

  Future<Object?> _call(Future<Object?> Function() request) async {
    try {
      return await request();
    } on ApiException catch (error) {
      throw AuthApiException(error.message);
    }
  }
}
