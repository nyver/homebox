import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/localization/app_locale_controller.dart';
import 'package:homebox_client/core/platform/app_lock_preferences.dart';
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

/// The header's vault-lock indicator is icon-only; this is its tooltip
/// while locked (see _VaultStateChip in main.dart), used here via
/// find.byTooltip since there is no longer a visible "Vault locked" Text.
const _vaultLockedTooltip =
    'Create or restore this account\'s vault in Settings to unlock E2EE data.';

void main() {
  testWidgets('client starts locked and does not expose files', (tester) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.byTooltip(_vaultLockedTooltip), findsOneWidget);
    // A new device sees the setup guide, starting at the server step.
    expect(find.text('Welcome to HomeBox'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-connect')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-sign-in')), findsNothing);
    expect(find.byKey(const ValueKey('setup-create-vault')), findsNothing);
  });

  testWidgets('sync page makes the locked state explicit', (tester) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    // The header duplicates the sync status next to "Vault locked" from any
    // section, not just the Sync page itself.
    expect(find.text('Sync not set up'), findsOneWidget);

    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    expect(find.text('Sync not set up'), findsNWidgets(2));
    expect(
      find.text(
        'Sync starts once this device is connected to a server and its vault is unlocked.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the whole shell follows the Russian language setting', (
    tester,
  ) async {
    final locale = AppLocaleController(_MemoryLanguageStorage());
    addTearDown(locale.dispose);
    await locale.setLanguage(AppLanguage.russian);

    await tester.pumpWidget(_testApp(localeController: locale));
    await tester.pumpAndSettle();

    expect(find.text('Синхронизация не настроена'), findsOneWidget);
    expect(find.text('Добро пожаловать в HomeBox'), findsOneWidget);
    expect(find.text('Подключитесь к серверу'), findsOneWidget);

    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Это устройство'), findsOneWidget);
    expect(find.text('Подготовить'), findsOneWidget);
    expect(find.text('Сервер'), findsOneWidget);
    expect(find.text('Подключить'), findsOneWidget);

    await locale.setLanguage(AppLanguage.english);
  });

  testWidgets('header statuses and empty states lead to where to act', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    // The header's sync status opens the Sync page.
    await tester.tap(find.text('Sync not set up'));
    await tester.pumpAndSettle();
    expect(find.text('Local sync folder'), findsOneWidget);

    // The vault lock opens Settings.
    await tester.tap(find.byTooltip(_vaultLockedTooltip));
    await tester.pumpAndSettle();
    expect(find.text('This device'), findsOneWidget);

    // The setup guide offers a direct way to Settings too.
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    final settingsLink = find.text('All options are also in Settings');
    await tester.scrollUntilVisible(
      settingsLink,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(settingsLink);
    await tester.pumpAndSettle();
    expect(find.text('This device'), findsOneWidget);
  });

  testWidgets('the Sync page lets Android users choose a local sync folder', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    expect(find.text('Local sync folder'), findsOneWidget);
    expect(find.text('Choose'), findsOneWidget);
    expect(find.text('Change'), findsNothing);
    expect(
      find.textContaining('Choose a folder to mirror server files'),
      findsOneWidget,
    );

    // Reset inline rather than relying solely on addTearDown: the
    // framework's post-test invariant check runs before registered
    // tearDowns fire, so leaving this to addTearDown alone trips it.
    debugDefaultTargetPlatformOverride = null;
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
    expect(find.byTooltip(_vaultLockedTooltip), findsOneWidget);
  });

  testWidgets(
    'Android keeps content hidden until biometrics pass at launch, and does not re-lock in the background',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final authenticator = _ControlledBiometricAuthenticator();

      await tester.pumpWidget(_testApp(biometricAuthenticator: authenticator));
      await tester.pump();
      await tester.pump();

      expect(authenticator.authenticationCalls, 1);
      expect(find.text('HomeBox locked'), findsOneWidget);
      expect(find.byTooltip(_vaultLockedTooltip), findsNothing);

      authenticator.completeAuthentication(true);
      await tester.pumpAndSettle();

      expect(find.byTooltip(_vaultLockedTooltip), findsOneWidget);

      // Backgrounding must not re-engage the lock: many in-app flows (the
      // system file/save picker, camera capture) pause the app as part of
      // their own normal operation, and re-locking on each of those both
      // interrupts whatever was in progress and re-prompts far more often
      // than a user expects — see BiometricAuthenticator's doc comment.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.byTooltip(_vaultLockedTooltip), findsOneWidget);
      expect(find.text('HomeBox locked'), findsNothing);
      expect(
        authenticator.authenticationCalls,
        1,
        reason: 'resuming from the background must not prompt again',
      );

      // Reset inline rather than relying solely on addTearDown: the
      // framework's post-test invariant check runs before registered
      // tearDowns fire, so leaving this to addTearDown alone trips it.
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'Android locks again after longer in the background than allowed',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final authenticator = _ControlledBiometricAuthenticator();
      var now = DateTime.utc(2026, 1, 1, 12);
      final lock = AppLockPreferences(_MemoryLockStorage());
      addTearDown(lock.dispose);
      await lock.setAutoLock(AppAutoLock.after1Minute);

      await tester.pumpWidget(
        _testApp(
          biometricAuthenticator: authenticator,
          appLockPreferences: lock,
          clock: () => now,
        ),
      );
      await tester.pump();
      await tester.pump();
      authenticator.completeAuthentication(true);
      await tester.pumpAndSettle();
      expect(find.text('HomeBox locked'), findsNothing);

      // Thirty seconds away (e.g. a file picker) keeps it unlocked.
      _sendToBackground(tester);
      now = now.add(const Duration(seconds: 30));
      _bringToForeground(tester);
      await tester.pump();
      expect(find.text('HomeBox locked'), findsNothing);
      expect(authenticator.authenticationCalls, 1);

      // Two minutes away locks and prompts again.
      _sendToBackground(tester);
      now = now.add(const Duration(minutes: 2));
      _bringToForeground(tester);
      await tester.pump();
      expect(find.text('HomeBox locked'), findsOneWidget);
      expect(authenticator.authenticationCalls, 2);

      authenticator.completeAuthentication(true);
      await tester.pumpAndSettle();
      expect(find.text('HomeBox locked'), findsNothing);

      // A relock also hides whatever is open above the page, without
      // closing it: here the server dialog of the setup guide.
      await tester.tap(find.byKey(const ValueKey('setup-connect')));
      await tester.pumpAndSettle();
      final dialogTitle = find.text('Connect to a HomeBox server');
      expect(dialogTitle.hitTestable(), findsOneWidget);
      _sendToBackground(tester);
      now = now.add(const Duration(minutes: 2));
      _bringToForeground(tester);
      await tester.pump();
      expect(dialogTitle.hitTestable(), findsNothing);
      expect(find.text('HomeBox locked').hitTestable(), findsOneWidget);

      authenticator.completeAuthentication(true);
      await tester.pumpAndSettle();
      expect(dialogTitle.hitTestable(), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    },
  );
}

/// Walks the real lifecycle sequence, which framework listeners assert on.
void _sendToBackground(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _bringToForeground(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

HomeBoxApp _testApp({
  BiometricAuthenticator? biometricAuthenticator,
  AppLocaleController? localeController,
  AppLockPreferences? appLockPreferences,
  DateTime Function()? clock,
}) {
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
    localeController: localeController,
    appLockPreferences:
        appLockPreferences ?? AppLockPreferences(_MemoryLockStorage()),
    clock: clock,
  );
}

final class _MemoryLockStorage implements AppLockStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class _MemoryLanguageStorage implements AppLanguageStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String languageCode) async => value = languageCode;
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
