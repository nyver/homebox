import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/main.dart';

void main() {
  testWidgets('setup requires a server fingerprint', (tester) async {
    await tester.pumpWidget(const HomeBoxApp());
    expect(find.text('Set up HomeBox'), findsOneWidget);
    final continueButton = find.widgetWithText(
      FilledButton,
      'Verify and continue',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(continueButton);
    await tester.pump();
    expect(
      find.text('Enter the 64-character SHA-256 fingerprint.'),
      findsOneWidget,
    );
  });
}
