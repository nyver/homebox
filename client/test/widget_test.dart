import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/main.dart';

import 'support/memory_device_private_key_storage.dart';

void main() {
  testWidgets('Windows client starts locked and does not expose files', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('Vault locked'), findsOneWidget);
    expect(find.text('Choose your HomeBox folder'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
  });

  testWidgets('sync page makes the locked state explicit', (tester) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

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

  testWidgets('Settings prepares a Windows device without unlocking vault', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('This Windows device'), findsOneWidget);
    expect(find.text('Prepare device'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('prepare-device')));
    await tester.pumpAndSettle();
    expect(find.text('Prepare this Windows device?'), findsOneWidget);
    await tester.tap(find.text('Create identity'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Identity ready · Not provisioned'),
      findsOneWidget,
    );
    expect(find.text('Vault locked'), findsOneWidget);
  });
}

HomeBoxApp _testApp() => HomeBoxApp(
  deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
);
