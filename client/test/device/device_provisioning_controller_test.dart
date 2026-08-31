import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/transport/homebox_api_client.dart' as transport;
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/device/device_provisioning_controller.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../support/memory_vault_key_storage.dart';
import 'fake_device_server.dart';

final class _SignedInDevice {
  _SignedInDevice(this.serverConnection, this.deviceIdentityStore);

  final ServerConnectionController serverConnection;
  final DeviceIdentityStore deviceIdentityStore;
}

/// Mirrors main.dart's wiring: a single device signs in with one
/// [DeviceIdentityStore] shared between [ServerConnectionController] and
/// [DeviceProvisioningController] — selfApprove() needs to read the same
/// identity that logged this device in to wrap the vault key for it.
Future<_SignedInDevice> _connectedAndSignedIn(HttpServer httpServer) async {
  final deviceIdentityStore = DeviceIdentityStore(
    MemoryDevicePrivateKeyStorage(),
  );
  final controller = ServerConnectionController(
    deviceIdentityStore: deviceIdentityStore,
    serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
    sessionStore: SessionStore(MemorySessionStorage()),
  );
  await controller.discover('127.0.0.1:${httpServer.port}');
  await controller.confirmTrust();
  await controller.login('admin', 'correct horse battery staple');
  if (controller.status != ServerConnectionStatus.authenticated) {
    throw StateError(
      'test setup failed to authenticate: ${controller.errorMessage}',
    );
  }
  return _SignedInDevice(controller, deviceIdentityStore);
}

DeviceProvisioningController _controllerFor(
  _SignedInDevice device, {
  VaultKeyStore? vaultKeyStore,
}) => DeviceProvisioningController(
  deviceIdentityStore: device.deviceIdentityStore,
  vaultKeyStore: vaultKeyStore ?? VaultKeyStore(MemoryVaultKeyStorage()),
  serverConnection: device.serverConnection,
);

void main() {
  test(
    'accountDevices reports every signed-in device with its real approval state',
    () async {
      final fakeServer = FakeDeviceServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));

      final trusted = await _connectedAndSignedIn(httpServer);
      addTearDown(trusted.serverConnection.dispose);
      final newDevice = await _connectedAndSignedIn(httpServer);
      addTearDown(newDevice.serverConnection.dispose);
      final controller = _controllerFor(trusted);
      addTearDown(controller.dispose);

      final beforeApproval = await controller.accountDevices();
      expect(beforeApproval, hasLength(2));
      expect(beforeApproval.every((d) => !d.hasVaultKey), isTrue);

      final newDeviceId = newDevice.serverConnection.session!.device.id;
      final trustedDeviceId = trusted.serverConnection.session!.device.id;
      fakeServer.setHasVaultKey(newDeviceId, true);
      final afterApproval = await controller.accountDevices();
      expect(
        afterApproval.singleWhere((d) => d.id == newDeviceId).hasVaultKey,
        isTrue,
      );
      expect(
        afterApproval.singleWhere((d) => d.id == trustedDeviceId).hasVaultKey,
        isFalse,
      );
    },
  );

  test(
    'revokeDevice signs the target device out and refuses to revoke the caller\'s own device',
    () async {
      final fakeServer = FakeDeviceServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));

      final trusted = await _connectedAndSignedIn(httpServer);
      addTearDown(trusted.serverConnection.dispose);
      final newDevice = await _connectedAndSignedIn(httpServer);
      addTearDown(newDevice.serverConnection.dispose);
      final controller = _controllerFor(trusted);
      addTearDown(controller.dispose);

      final devices = await controller.accountDevices();
      final self = devices.singleWhere(
        (d) => d.id == trusted.serverConnection.session!.device.id,
      );
      final other = devices.singleWhere(
        (d) => d.id == newDevice.serverConnection.session!.device.id,
      );

      expect(await controller.revokeDevice(self), isFalse);
      expect(fakeServer.revokeRequestCount, 0);

      expect(await controller.revokeDevice(other), isTrue);
      expect(fakeServer.revokeRequestCount, 1);

      await expectLater(
        newDevice.serverConnection.api!.listDevices(
          newDevice.serverConnection.session!.accessToken,
        ),
        throwsA(isA<transport.HomeBoxApiException>()),
      );
    },
  );

  test(
    'selfApprove records this vault-creating device as approved on its own',
    () async {
      final fakeServer = FakeDeviceServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));

      final creator = await _connectedAndSignedIn(httpServer);
      addTearDown(creator.serverConnection.dispose);
      final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
      final recoverySecret = await vaultKeyStore.createVault(
        userId: FakeDeviceServer.userId,
      );
      recoverySecret.destroy();
      final controller = _controllerFor(creator, vaultKeyStore: vaultKeyStore);
      addTearDown(controller.dispose);

      final beforeApproval = await controller.accountDevices();
      expect(beforeApproval.single.hasVaultKey, isFalse);

      expect(await controller.selfApprove(), isTrue);
      expect(
        fakeServer.uploadedEnvelopeTargetIds,
        contains(creator.serverConnection.session!.device.id),
      );

      final afterApproval = await controller.accountDevices();
      expect(afterApproval.single.hasVaultKey, isTrue);
    },
  );
}
