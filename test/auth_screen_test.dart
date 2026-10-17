import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_first_app/main.dart';

void main() {
  testWidgets('shows the registration screen before salon access', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('SALONÉ'), findsOneWidget);
    expect(find.text('Create account'), findsWidgets);
    expect(find.text('EMAIL ADDRESS'), findsOneWidget);
    expect(find.text('SALON FINDER'), findsOneWidget);
    expect(find.text('Salons near you'), findsNothing);
  });

  testWidgets('explains when Supabase credentials are not configured', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp(supabaseConfigured: false));

    expect(find.text('Connect your Supabase project'), findsOneWidget);
    expect(find.text('Create account'), findsNothing);
  });
}
