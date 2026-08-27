import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/main.dart';

void main() {
  testWidgets('Windows client starts locked and does not expose files', (
    tester,
  ) async {
    await tester.pumpWidget(const HomeBoxApp());

    expect(find.text('Vault locked'), findsOneWidget);
    expect(find.text('Choose your HomeBox folder'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
  });

  testWidgets('sync page makes the locked state explicit', (tester) async {
    await tester.pumpWidget(const HomeBoxApp());

    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    expect(find.text('Sync paused'), findsOneWidget);
    expect(
      find.text(
        'Provision this device with a trusted device or Recovery Secret.',
      ),
      findsOneWidget,
    );
  });
}
