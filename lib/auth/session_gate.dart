import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../salons/home_screen.dart';
import 'auth_api.dart';
import 'auth_screen.dart';

/// Shown while nobody is signed in: anyone can browse salons and chairs.
const guestProfile = Profile(
  id: 'guest',
  email: 'Guest',
  role: AppRole.customer,
);

/// Root of the app.
///
/// Signed out, it shows the salon list as a guest; booking or managing a
/// salon asks the user to sign in ([showSignIn]). The session is saved on
/// the device, so a returning user is signed in straight away. Signing in or
/// out is picked up from [ApiClient.userId], and the user's profile (with
/// their role) is loaded from the API.
class SessionGate extends StatefulWidget {
  const SessionGate({super.key});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  final _repository = SalonRepository();
  final _session = ApiClient.instance.userId;
  bool _restoring = true;
  String? _userId;
  Profile? _profile;
  String? _error;

  @override
  void initState() {
    super.initState();
    Realtime.instance; // connects while signed in
    _session.addListener(_authChanged);
    ApiClient.instance.restoreSession().whenComplete(() {
      if (!mounted) return;
      setState(() => _restoring = false);
      _authChanged();
    });
  }

  @override
  void dispose() {
    _session.removeListener(_authChanged);
    super.dispose();
  }

  void _authChanged() {
    if (!mounted || _restoring) return;
    final userId = _session.value;
    if (userId == _userId) return;
    // Just signed in from the sign-in screen: close it and show the app.
    if (userId != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    setState(() {
      _userId = userId;
      _profile = null;
      _error = null;
    });
    if (userId != null) _loadProfile();
  }

  Future<void> _loadProfile() async {
    final userId = _userId;
    if (userId == null) return;
    setState(() => _error = null);
    try {
      final profile = await _repository.fetchProfile(userId);
      if (!mounted || userId != _userId) return;
      setState(() => _profile = profile);
    } on RepositoryException catch (error) {
      if (!mounted || userId != _userId) return;
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppColors.gold)),
      );
    }
    if (_userId == null) {
      return HomeScreen(
        key: const ValueKey('guest'),
        profile: guestProfile,
        onReloadProfile: () async {},
      );
    }

    final profile = _profile;
    if (profile != null && profile.id == _userId) {
      return HomeScreen(
        key: ValueKey(profile.id),
        profile: profile,
        onReloadProfile: _loadProfile,
      );
    }

    return Scaffold(
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator(color: AppColors.gold)
            : Padding(
                padding: const EdgeInsets.all(AppSpacing.l),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_rounded,
                      color: AppColors.textSecondary,
                      size: 40,
                    ),
                    const SizedBox(height: AppSpacing.m),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.m),
                    ElevatedButton(
                      onPressed: _loadProfile,
                      child: const Text('Try again'),
                    ),
                    TextButton(
                      onPressed: () => signOut(context),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Opens sign-up / login over the current screen. [SessionGate] closes it
/// once the user is signed in.
Future<void> showSignIn(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => Stack(
      children: [
        const AuthScreen(),
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Builder(
              builder: (context) => IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);

/// Asks for confirmation, closes any open screens and signs out. The
/// [SessionGate] then shows the salon list as a guest.
Future<void> signOut(BuildContext context, {bool confirm = false}) async {
  if (confirm) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Log out?'),
        content: const Text('You will need to sign in again to book.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }

  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  navigator.popUntil((route) => route.isFirst);
  await AuthApi().signOut();
  messenger.showSnackBar(
    const SnackBar(content: Text('Signed out on this device.')),
  );
}
