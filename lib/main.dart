// =============================================================================
// Salon Finder
//
//   lib/auth/       sign-up, login, session gate (stay signed in, logout)
//   lib/salons/     salon list and detail / booking
//   lib/bookings/   the signed-in user's bookings
//   lib/owner/      salon owners and admins manage salons, services, bookings
//   lib/admin/      admins assign roles
//   lib/data/       local in-memory data
//
// Roles (customer / owner / admin) are kept locally for this demo app.
// =============================================================================

import 'package:flutter/material.dart';

import 'auth/session_gate.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Salon Finder',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // Opens on the salon list; guests can browse, and sign in to book.
      home: const SessionGate(),
    );
  }
}
