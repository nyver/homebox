import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/syncfolder/sync_folder_store.dart';
import 'package:homebox_client/main.dart';

import 'support/memory_device_private_key_storage.dart';
import 'support/memory_pinned_server_storage.dart';
import 'support/memory_session_storage.dart';
import 'support/memory_sync_folder_storage.dart';
import 'support/memory_vault_key_storage.dart';

void main() {
  testWidgets('client starts locked and does not expose files', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('Vault locked'), findsOneWidget);
    expect(
      find.text('Connect to a server, sign in, and set up the vault in Settings to see your files.'),
      findsOneWidget,
    );
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

  testWidgets('Settings prepares a device without unlocking vault', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Prepare device'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('prepare-device')));
    await tester.pumpAndSettle();
    expect(find.text('Prepare this device?'), findsOneWidget);
    await tester.tap(find.text('Create identity'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Identity ready · Not provisioned'),
      findsOneWidget,
    );
    expect(find.text('Vault locked'), findsOneWidget);
  });
}

HomeBoxApp _testApp() {
  final deviceIdentityStore = DeviceIdentityStore(MemoryDevicePrivateKeyStorage());
  return HomeBoxApp(
    deviceIdentityStore: deviceIdentityStore,
    // In-memory-backed so widget tests never touch real OS secure storage
    // (which is unavailable — and, if it somehow weren't, would leak state
    // across test runs — in the plain WidgetTester environment).
    serverConnectionController: ServerConnectionController(
      deviceIdentityStore: deviceIdentityStore,
      serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
      sessionStore: SessionStore(MemorySessionStorage()),
    ),
    vaultKeyStore: VaultKeyStore(MemoryVaultKeyStorage()),
    syncFolderStore: SyncFolderStore(MemorySyncFolderStorage()),
  );
}
