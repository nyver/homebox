import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/files/files_controller.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/sync/sync_engine.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../support/memory_vault_key_storage.dart';
import '../sync/fake_node_server.dart';

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

/// A Files controller showing a folder with [imageCount] uploaded images.
Future<(FakeNodeServer, FilesController)> _folderWithImages(
  int imageCount,
) async {
  final fakeServer = FakeNodeServer();
  final httpServer = await fakeServer.start();
  addTearDown(() => httpServer.close(force: true));
  final serverConnection = await _connectedAndSignedIn(httpServer);
  addTearDown(serverConnection.dispose);
  final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
  final recoverySecret = await vaultKeyStore.createVault(
    userId: FakeNodeServer.userId,
  );
  recoverySecret.destroy();
  final syncEngine = SyncEngine(
    serverConnection: serverConnection,
    localDatabase: LocalDatabase.openInMemory(),
  );
  addTearDown(syncEngine.dispose);
  final controller = FilesController(
    serverConnection: serverConnection,
    vaultKeyStore: vaultKeyStore,
    syncEngine: syncEngine,
  );
  addTearDown(controller.dispose);
  final sourceDir = await Directory.systemTemp.createTemp(
    'homebox_preview_source_',
  );
  addTearDown(() => sourceDir.delete(recursive: true));
  final paths = <String>[];
  for (var i = 0; i < imageCount; i++) {
    final file = File('${sourceDir.path}/photo-$i.jpg');
    await file.writeAsBytes(Uint8List.fromList(List.filled(64, i)));
    paths.add(file.path);
  }
  final result = await controller.uploadFiles(paths);
  expect(result.succeeded, imageCount, reason: controller.errorMessage);
  return (fakeServer, controller);
}

void main() {
  test('previews beyond the concurrency limit are queued, cached, and never rebuild the whole list', () async {
    final (fakeServer, controller) = await _folderWithImages(12);
    final entries = controller.entries;
    var notifications = 0;
    controller.addListener(() => notifications++);
    final downloadsBefore = fakeServer.contentDownloadCount;

    final previews = await Future.wait(entries.map(controller.imagePreview));

    for (var i = 0; i < entries.length; i++) {
      final expected = int.parse(
        RegExp(r'photo-(\d+)').firstMatch(entries[i].name)!.group(1)!,
      );
      expect(previews[i], List.filled(64, expected));
      expect(controller.cachedImagePreview(entries[i]), previews[i]);
    }
    expect(fakeServer.contentDownloadCount - downloadsBefore, 12);
    expect(
      notifications,
      0,
      reason: 'a finished thumbnail must not notify every list row',
    );

    // More images than the old 8-entry cache: a second look is served
    // entirely from memory instead of downloading in a loop.
    await Future.wait(entries.map(controller.imagePreview));
    expect(fakeServer.contentDownloadCount - downloadsBefore, 12);
  });

  test(
    'a preview released before its download starts is dropped from the queue',
    () async {
      final (fakeServer, controller) = await _folderWithImages(3);
      final entries = controller.entries;
      final gate = Completer<void>();
      fakeServer.contentResponseGate = gate;
      final downloadsBefore = fakeServer.contentDownloadCount;

      final first = controller.imagePreview(entries[0]);
      final second = controller.imagePreview(entries[1]);
      final third = controller.imagePreview(entries[2]);
      controller.releaseImagePreview(entries[2]);
      expect(await third, isNull);

      gate.complete();
      expect(await first, isNotNull);
      expect(await second, isNotNull);
      expect(fakeServer.contentDownloadCount - downloadsBefore, 2);
      expect(controller.cachedImagePreview(entries[2]), isNull);

      // A later request for the dropped image still downloads it.
      expect(await controller.imagePreview(entries[2]), isNotNull);
      expect(fakeServer.contentDownloadCount - downloadsBefore, 3);
    },
  );
}
