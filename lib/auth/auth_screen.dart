import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_api.dart';

enum _AuthMode { login, register }

const _ink = Color(0xFF0E0E10);
const _panel = Color(0xFF17171A);
const _gold = Color(0xFFD4AF37);
const _muted = Color(0xFF9A9AA2);
const _line = Color(0xFF34343A);

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.destinationBuilder});

  final Widget Function() destinationBuilder;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _codeController = TextEditingController();
  final _api = AuthApi();

  _AuthMode _mode = _AuthMode.register;
  bool _awaitingCode = false;
  bool _busy = false;
  bool _obscurePassword = true;
  int _resendSeconds = 0;
  Timer? _resendTimer;
  String _pendingEmail = '';

  bool get _isRegistering => _mode == _AuthMode.register;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _codeController.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  Future<void> _submitCredentials() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final email = _emailController.text.trim();
    try {
      if (_isRegistering) {
        await _api.register(email, _passwordController.text);
        if (!mounted) return;
        setState(() {
          _pendingEmail = email;
          _awaitingCode = true;
        });
        _startResendCooldown();
        _showMessage('A verification code was sent to $email.');
      } else {
        await _api.login(email, _passwordController.text);
        if (!mounted) return;
        _openDestination();
      }
    } on AuthApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_codeController.text.trim().length != 6) {
      _showMessage('Enter the 6-digit code from your email.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.verifyCode(
        _pendingEmail,
        _codeController.text.trim(),
      );
      if (!mounted) return;
      _openDestination();
    } on AuthApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openDestination() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => widget.destinationBuilder()),
      (_) => false,
    );
  }

  Future<void> _resendCode() async {
    if (_resendSeconds > 0 || _busy) return;
    setState(() => _busy = true);
    try {
      await _api.resendCode(_pendingEmail);
      if (mounted) {
        _startResendCooldown();
        _showMessage('A new code has been sent if the account exists.');
      }
    } on AuthApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _resendSeconds--;
        if (_resendSeconds == 0) {
          timer.cancel();
          _resendTimer = null;
        }
      });
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _changeMode(_AuthMode mode) {
    _resendTimer?.cancel();
    _resendTimer = null;
    setState(() {
      _mode = mode;
      _awaitingCode = false;
      _resendSeconds = 0;
      _codeController.clear();
      _formKey.currentState?.reset();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _ink,
      body: Stack(
        children: [
          Positioned(
            top: -145,
            right: -125,
            child: IgnorePointer(
              child: Container(
                width: 330,
                height: 330,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _gold.withValues(alpha: 0.07),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildBrand(),
                      const SizedBox(height: 38),
                      Text(
                        _awaitingCode
                            ? 'Check your inbox'
                            : _isRegistering
                            ? 'Your best look starts here.'
                            : 'Welcome back.',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.7,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _awaitingCode
                            ? 'Enter the 6-digit code we sent to $_pendingEmail.'
                            : _isRegistering
                            ? 'Create an account to discover and book nearby salons.'
                            : 'Sign in to find your next salon experience.',
                        style: const TextStyle(
                          color: _muted,
                          height: 1.5,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (_awaitingCode)
                        _buildOtpForm()
                      else ...[
                        _buildModeSwitch(),
                        const SizedBox(height: 24),
                        _buildCredentialsForm(),
                      ],
                      const SizedBox(height: 24),
                      const Row(
                        children: [
                          Expanded(child: Divider(color: _line)),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14),
                            child: Text(
                              'SALON FINDER',
                              style: TextStyle(
                                color: _muted,
                                fontSize: 10,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: _line)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrand() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: _gold.withValues(alpha: 0.3)),
          ),
          child: const Icon(Icons.content_cut_rounded, color: _gold, size: 23),
        ),
        const SizedBox(width: 12),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SALONÉ',
              style: TextStyle(
                color: Colors.white,
                letterSpacing: 2.4,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'YOUR STYLE, YOUR WAY',
              style: TextStyle(color: _muted, fontSize: 9, letterSpacing: 1.4),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildModeSwitch() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _modeButton('Create account', _AuthMode.register),
          _modeButton('Log in', _AuthMode.login),
        ],
      ),
    );
  }

  Widget _modeButton(String label, _AuthMode mode) {
    final selected = _mode == mode;
    return Expanded(
      child: TextButton(
        onPressed: _busy ? null : () => _changeMode(mode),
        style: TextButton.styleFrom(
          backgroundColor: selected ? _gold : Colors.transparent,
          foregroundColor: selected ? _ink : _muted,
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        child: Text(label),
      ),
    );
  }

  Widget _buildCredentialsForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('EMAIL ADDRESS'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: _inputDecoration(
              hint: 'you@example.com',
              icon: Icons.mail_outline_rounded,
            ),
            validator: (value) {
              final email = value?.trim() ?? '';
              return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)
                  ? null
                  : 'Enter a valid email address.';
            },
          ),
          const SizedBox(height: 19),
          _label('PASSWORD'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: _isRegistering
                ? TextInputAction.next
                : TextInputAction.done,
            autofillHints: [
              _isRegistering
                  ? AutofillHints.newPassword
                  : AutofillHints.password,
            ],
            onFieldSubmitted: (_) {
              if (!_isRegistering) _submitCredentials();
            },
            decoration: _inputDecoration(
              hint: 'At least 8 characters',
              icon: Icons.lock_outline_rounded,
              suffix: IconButton(
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: _muted,
                  size: 20,
                ),
              ),
            ),
            validator: (value) {
              final password = value ?? '';
              if (_isRegistering && password.length < 8) {
                return 'Use at least 8 characters.';
              }
              if (password.isEmpty) return 'Enter your password.';
              return null;
            },
          ),
          if (_isRegistering) ...[
            const SizedBox(height: 19),
            _label('CONFIRM PASSWORD'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _confirmPasswordController,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submitCredentials(),
              decoration: _inputDecoration(
                hint: 'Re-enter your password',
                icon: Icons.lock_outline_rounded,
              ),
              validator: (value) => value == _passwordController.text
                  ? null
                  : 'Passwords do not match.',
            ),
          ],
          const SizedBox(height: 26),
          _primaryButton(
            label: _isRegistering ? 'Create account' : 'Continue',
            onPressed: _submitCredentials,
          ),
          const SizedBox(height: 14),
          Text(
            _isRegistering
                ? 'We’ll email you a one-time code to verify your account.'
                : 'Sign in securely with your email and password.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildOtpForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _codeController,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          maxLength: 6,
          onSubmitted: (_) => _verifyCode(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            letterSpacing: 14,
            fontWeight: FontWeight.w700,
          ),
          decoration: _inputDecoration(
            hint: '------',
            icon: Icons.verified_user_outlined,
          ).copyWith(counterText: ''),
        ),
        const SizedBox(height: 20),
        _primaryButton(label: 'Verify email', onPressed: _verifyCode),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _busy || _resendSeconds > 0 ? null : _resendCode,
          child: Text(
            _resendSeconds > 0
                ? 'Resend code in ${_resendSeconds}s'
                : 'Didn’t receive a code? Resend',
            style: const TextStyle(color: _gold, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  _resendTimer?.cancel();
                  setState(() {
                    _resendTimer = null;
                    _resendSeconds = 0;
                    _awaitingCode = false;
                    _codeController.clear();
                  });
                },
          child: const Text(
            'Use a different email',
            style: TextStyle(color: _muted),
          ),
        ),
      ],
    );
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: _muted,
      fontWeight: FontWeight.w700,
      fontSize: 10,
      letterSpacing: 1.5,
    ),
  );

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF73737B), fontSize: 14),
      prefixIcon: Icon(icon, color: _muted, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: _panel,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _gold, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFE5484D)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFE5484D)),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 54,
      child: ElevatedButton(
        onPressed: _busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: _ink,
          disabledBackgroundColor: _gold.withValues(alpha: 0.55),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        child: _busy
            ? const SizedBox(
                width: 21,
                height: 21,
                child: CircularProgressIndicator(strokeWidth: 2, color: _ink),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
      ),
    );
  }
}
