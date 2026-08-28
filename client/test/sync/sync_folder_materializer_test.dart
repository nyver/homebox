import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/files/files_controller.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/sync/sync_engine.dart';
import 'package:homebox_client/features/syncfolder/sync_folder_materializer.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../support/memory_vault_key_storage.dart';
import 'fake_node_server.dart';

Future<ServerConnectionController> _connectedAndSignedIn(HttpServer httpServer) async {
  final controller = ServerConnectionController(
    deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
    serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
    sessionStore: SessionStore(MemorySessionStorage()),
  );
  await controller.discover('127.0.0.1:${httpServer.port}');
  await controller.confirmTrust();
  await controller.login('admin', 'correct horse battery staple');
  if (controller.status != ServerConnectionStatus.authenticated) {
    throw StateError('test setup failed to authenticate: ${controller.errorMessage}');
  }
  return controller;
}

/// See the identical helper in files_controller_test.dart: `pumpEventQueue`
/// alone is not reliably enough for several sequential real localhost
/// socket round trips, so this polls wall-clock time instead.
Future<void> _awaitBackgroundSync(SyncEngine engine) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (engine.status == SyncStatus.syncing) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('SyncEngine did not settle within the test timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('materialize mirrors folders and decrypted files onto disk, relocates renames, and prunes deletions', () async {
    final fakeServer = FakeNodeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);

    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(userId: FakeNodeServer.userId);
    recoverySecret.destroy();

    final syncEngine = SyncEngine(serverConnection: serverConnection, localDatabase: LocalDatabase.openInMemory());
    addTearDown(syncEngine.dispose);
    final filesController = FilesController(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(filesController.dispose);
    final materializer = SyncFolderMaterializer(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(materializer.dispose);

    final rootDir = await Directory.systemTemp.createTemp('homebox_syncfolder_root_');
    addTearDown(() => rootDir.delete(recursive: true));
    final sourceDir = await Directory.systemTemp.createTemp('homebox_syncfolder_source_');
    addTearDown(() => sourceDir.delete(recursive: true));

    expect(await filesController.createFolder('Docs'), isTrue);
    await _awaitBackgroundSync(syncEngine);
    final folder = filesController.entries.single;
    filesController.openFolder(folder);
    await pumpEventQueue();

    final sourceFile = File('${sourceDir.path}/note.txt');
    await sourceFile.writeAsBytes(utf8.encode('hello sync folder'));
    expect(await filesController.uploadFile(sourceFile.path), isTrue, reason: filesController.errorMessage);
    final uploaded = filesController.entries.single;

    await materializer.materialize(rootDir.path);
    expect(materializer.status, SyncFolderStatus.idle, reason: materializer.errorMessage);

    final materializedFile = File('${rootDir.path}/Docs/note.txt');
    expect(await materializedFile.exists(), isTrue);
    expect(await materializedFile.readAsString(), 'hello sync folder');

    // A second pass with nothing changed must not re-download the content;
    // corrupt the fake server's stored blob and confirm the local file (and
    // its bytes) are left untouched.
    fakeServer.corruptBlob(uploaded.node.id);
    await materializer.materialize(rootDir.path);
    expect(await materializedFile.readAsString(), 'hello sync folder');

    // Rename the file through the outbox; the materializer should relocate
    // the already-downloaded bytes rather than re-downloading (which would
    // now fail, since the stored blob is corrupted).
    expect(await filesController.renameNode(uploaded, 'renamed.txt'), isTrue);
    await _awaitBackgroundSync(syncEngine);
    await materializer.materialize(rootDir.path);
    expect(await materializedFile.exists(), isFalse, reason: 'the old path should be gone after the rename');
    final renamedFile = File('${rootDir.path}/Docs/renamed.txt');
    expect(await renamedFile.exists(), isTrue);
    expect(await renamedFile.readAsString(), 'hello sync folder');

    // Deleting the node should prune the mirrored file on the next pass.
    expect(await filesController.deleteNode(filesController.entries.single), isTrue);
    await _awaitBackgroundSync(syncEngine);
    await materializer.materialize(rootDir.path);
    expect(await renamedFile.exists(), isFalse);
  });
}
