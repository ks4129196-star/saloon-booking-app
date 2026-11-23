import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_first_app/auth/auth_screen.dart';
import 'package:flutter_first_app/core/realtime.dart';
import 'package:flutter_first_app/main.dart';

void main() {
  // No server in widget tests, so no live-updates connection.
  setUpAll(() => Realtime.enabled = false);

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

  testWidgets('starts directly on the salon browser without a login page', (
    WidgetTester tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({}); // nothing saved
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Salons near you'), findsOneWidget);
    expect(find.text('Create account'), findsNothing);
    expect(find.text('Log in'), findsNothing);
  });
}
