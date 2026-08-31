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

Future<ServerConnectionController> _connectedAndSignedIn(
  HttpServer httpServer,
) async {
  final controller = ServerConnectionController(
    deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
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
  return controller;
}

DeviceProvisioningController _controllerFor(
  ServerConnectionController serverConnection,
) => DeviceProvisioningController(
  deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
  vaultKeyStore: VaultKeyStore(MemoryVaultKeyStorage()),
  serverConnection: serverConnection,
);

void main() {
  test(
    'accountDevices reports every signed-in device with its real approval state',
    () async {
      final fakeServer = FakeDeviceServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));

      final trusted = await _connectedAndSignedIn(httpServer);
      addTearDown(trusted.dispose);
      final newDevice = await _connectedAndSignedIn(httpServer);
      addTearDown(newDevice.dispose);
      final controller = _controllerFor(trusted);
      addTearDown(controller.dispose);

      final beforeApproval = await controller.accountDevices();
      expect(beforeApproval, hasLength(2));
      expect(beforeApproval.every((d) => !d.hasVaultKey), isTrue);

      fakeServer.setHasVaultKey(newDevice.session!.device.id, true);
      final afterApproval = await controller.accountDevices();
      expect(
        afterApproval
            .singleWhere((d) => d.id == newDevice.session!.device.id)
            .hasVaultKey,
        isTrue,
      );
      expect(
        afterApproval
            .singleWhere((d) => d.id == trusted.session!.device.id)
            .hasVaultKey,
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
      addTearDown(trusted.dispose);
      final newDevice = await _connectedAndSignedIn(httpServer);
      addTearDown(newDevice.dispose);
      final controller = _controllerFor(trusted);
      addTearDown(controller.dispose);

      final devices = await controller.accountDevices();
      final self = devices.singleWhere(
        (d) => d.id == trusted.session!.device.id,
      );
      final other = devices.singleWhere(
        (d) => d.id == newDevice.session!.device.id,
      );

      expect(await controller.revokeDevice(self), isFalse);
      expect(fakeServer.revokeRequestCount, 0);

      expect(await controller.revokeDevice(other), isTrue);
      expect(fakeServer.revokeRequestCount, 1);

      await expectLater(
        newDevice.api!.listDevices(newDevice.session!.accessToken),
        throwsA(isA<transport.HomeBoxApiException>()),
      );
    },
  );
}
