import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_first_app/auth/auth_screen.dart';
import 'package:flutter_first_app/main.dart';

void main() {
  testWidgets('log in uses an email code by default, password on request', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();

    expect(find.text('EMAIL ADDRESS'), findsOneWidget);
    expect(find.text('PASSWORD'), findsNothing);
    expect(find.text('Send code'), findsOneWidget);

    await tester.ensureVisible(find.text('Use password instead'));
    await tester.tap(find.text('Use password instead'));
    await tester.pumpAndSettle();

    expect(find.text('PASSWORD'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Email me a code instead'), findsOneWidget);
  });

  testWidgets('shows the registration screen when no session is saved', (
    WidgetTester tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({}); // nothing saved
    await tester.pumpWidget(const MyApp());
    // Checks the device for a saved session first.
    await tester.pumpAndSettle();

    expect(find.text('SALONÉ'), findsOneWidget);
    expect(find.text('Create account'), findsWidgets);
    expect(find.text('EMAIL ADDRESS'), findsOneWidget);
  });
}
