import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/platform/biometric_authenticator.dart';
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
  testWidgets('client starts locked and does not expose files', (tester) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('Vault locked'), findsOneWidget);
    expect(
      find.text(
        'Connect to a server, sign in, and set up the vault in Settings to see your files.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('sync page makes the locked state explicit', (tester) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    // The header duplicates the sync status next to "Vault locked" from any
    // section, not just the Sync page itself.
    expect(find.text('Sync paused'), findsOneWidget);

    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    expect(find.text('Sync paused'), findsNWidgets(2));
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

  testWidgets(
    'Android keeps content hidden until biometrics pass and locks in background',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final authenticator = _ControlledBiometricAuthenticator();

      await tester.pumpWidget(_testApp(biometricAuthenticator: authenticator));
      await tester.pump();
      await tester.pump();

      expect(authenticator.authenticationCalls, 1);
      expect(find.text('HomeBox locked'), findsOneWidget);
      expect(find.text('Vault locked'), findsNothing);

      authenticator.completeAuthentication(true);
      await tester.pumpAndSettle();

      expect(find.text('Vault locked'), findsOneWidget);

      // Flutter disables frame scheduling while paused (matching a real
      // backgrounded app, which cannot draw), so the lock re-engaging while
      // paused is only observable once a frame actually renders again —
      // i.e. on resume, which is also the security-relevant moment: content
      // must never flash before the lock screen when the app comes back.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text('HomeBox locked'), findsOneWidget);

      // Settle the still-pending second authentication prompt so no async
      // work is left outstanding when the test ends.
      authenticator.completeAuthentication(true);
      await tester.pumpAndSettle();

      // Reset inline rather than relying solely on addTearDown: the
      // framework's post-test invariant check runs before registered
      // tearDowns fire, so leaving this to addTearDown alone trips it.
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

HomeBoxApp _testApp({BiometricAuthenticator? biometricAuthenticator}) {
  final deviceIdentityStore = DeviceIdentityStore(
    MemoryDevicePrivateKeyStorage(),
  );
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
    biometricAuthenticator:
        biometricAuthenticator ?? const _UnavailableBiometricAuthenticator(),
  );
}

final class _UnavailableBiometricAuthenticator
    implements BiometricAuthenticator {
  const _UnavailableBiometricAuthenticator();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate() async => false;
}

final class _ControlledBiometricAuthenticator
    implements BiometricAuthenticator {
  // A fresh Completer per call (once the previous one settled) so each
  // simulated prompt — e.g. the one re-triggered on resume after a
  // background re-lock — waits for its own explicit completeAuthentication
  // call, matching a real biometric prompt shown again from scratch.
  Completer<bool> _authentication = Completer<bool>();
  int authenticationCalls = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate() {
    authenticationCalls++;
    if (_authentication.isCompleted) {
      _authentication = Completer<bool>();
    }
    return _authentication.future;
  }

  void completeAuthentication(bool authenticated) =>
      _authentication.complete(authenticated);
}
