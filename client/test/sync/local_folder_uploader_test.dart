import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/metadata_cipher.dart';
import 'package:homebox_client/core/e2ee/opaque_id.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/files/file_transfer.dart';
import 'package:homebox_client/features/files/files_controller.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/sync/sync_engine.dart';
import 'package:homebox_client/features/syncfolder/local_folder_uploader.dart';
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
  test('scan uploads a new local file placed directly into an already-known folder', () async {
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
    final uploader = LocalFolderUploader(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(uploader.dispose);

    final rootDir = await Directory.systemTemp.createTemp('homebox_uploader_root_');
    addTearDown(() => rootDir.delete(recursive: true));

    expect(await filesController.createFolder('Docs'), isTrue);
    await _awaitBackgroundSync(syncEngine);
    final folder = filesController.entries.single;
    await materializer.materialize(rootDir.path); // creates the physical Docs directory.
    expect(await Directory('${rootDir.path}/Docs').exists(), isTrue);

    // Drop a brand new file directly on disk, bypassing the app entirely.
    final newFile = File('${rootDir.path}/Docs/dropped.txt');
    await newFile.writeAsBytes(utf8.encode('dropped by the user'));

    await uploader.scan(rootDir.path);
    expect(uploader.status, LocalUploadStatus.idle, reason: uploader.errorMessage);

    final children = syncEngine.nodeCache.listChildren(folder.node.id);
    expect(children, hasLength(1));
    final uploadedNode = children.single;
    expect(uploadedNode.isDirectory, isFalse);
    expect(uploadedNode.currentVersionId, isNotNull);

    final session = serverConnection.session!;
    final downloaded = await downloadAndDecryptFile(
      api: serverConnection.api!,
      accessToken: session.accessToken,
      vaultKey: (await vaultKeyStore.loadVaultKey())!,
      vaultId: uuidStringToBytes(session.user.id),
      nodeId: uploadedNode.id,
    );
    expect(utf8.decode(downloaded), 'dropped by the user');
  });

  test('scan uploads a locally-edited tracked file as a new version', () async {
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
    final uploader = LocalFolderUploader(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(uploader.dispose);

    final rootDir = await Directory.systemTemp.createTemp('homebox_uploader_root_');
    addTearDown(() => rootDir.delete(recursive: true));
    final sourceDir = await Directory.systemTemp.createTemp('homebox_uploader_source_');
    addTearDown(() => sourceDir.delete(recursive: true));

    final sourceFile = File('${sourceDir.path}/note.txt');
    await sourceFile.writeAsBytes(utf8.encode('original content'));
    expect(await filesController.uploadFile(sourceFile.path), isTrue, reason: filesController.errorMessage);
    final uploaded = filesController.entries.single;

    await materializer.materialize(rootDir.path);
    final localFile = File('${rootDir.path}/note.txt');
    expect(await localFile.readAsString(), 'original content');

    // Edit the file directly on disk.
    await localFile.writeAsString('edited by the user');

    await uploader.scan(rootDir.path);
    expect(uploader.status, LocalUploadStatus.idle, reason: uploader.errorMessage);

    final updatedNode = syncEngine.nodeCache.getById(uploaded.node.id)!;
    expect(updatedNode.currentVersionId, isNot(uploaded.node.currentVersionId));

    final session = serverConnection.session!;
    final versions = await serverConnection.api!.listFileVersions(session.accessToken, uploaded.node.id);
    expect(versions, hasLength(2), reason: 'the original version must remain retrievable');
    final downloaded = await downloadAndDecryptFile(
      api: serverConnection.api!,
      accessToken: session.accessToken,
      vaultKey: (await vaultKeyStore.loadVaultKey())!,
      vaultId: uuidStringToBytes(session.user.id),
      nodeId: uploaded.node.id,
    );
    expect(utf8.decode(downloaded), 'edited by the user');
  });

  test('scan deletes server-side when a previously-materialized file disappears locally', () async {
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
    final uploader = LocalFolderUploader(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(uploader.dispose);

    final rootDir = await Directory.systemTemp.createTemp('homebox_uploader_root_');
    addTearDown(() => rootDir.delete(recursive: true));
    final sourceDir = await Directory.systemTemp.createTemp('homebox_uploader_source_');
    addTearDown(() => sourceDir.delete(recursive: true));

    final sourceFile = File('${sourceDir.path}/note.txt');
    await sourceFile.writeAsBytes(utf8.encode('will be deleted locally'));
    expect(await filesController.uploadFile(sourceFile.path), isTrue, reason: filesController.errorMessage);
    final uploaded = filesController.entries.single;

    await materializer.materialize(rootDir.path);
    final localFile = File('${rootDir.path}/note.txt');
    expect(await localFile.exists(), isTrue);
    await localFile.delete();

    await uploader.scan(rootDir.path);
    expect(uploader.status, LocalUploadStatus.idle, reason: uploader.errorMessage);

    expect(syncEngine.nodeCache.getById(uploaded.node.id)!.isDeleted, isTrue);
  });

  test('scan never deletes a tracked file that this device has not yet successfully downloaded', () async {
    final fakeServer = FakeNodeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(userId: FakeNodeServer.userId);
    recoverySecret.destroy();
    final vaultKey = (await vaultKeyStore.loadVaultKey())!;
    final syncEngine = SyncEngine(serverConnection: serverConnection, localDatabase: LocalDatabase.openInMemory());
    addTearDown(syncEngine.dispose);
    final filesController = FilesController(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(filesController.dispose);
    final materializer = SyncFolderMaterializer(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(materializer.dispose);
    final uploader = LocalFolderUploader(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(uploader.dispose);

    final rootDir = await Directory.systemTemp.createTemp('homebox_uploader_root_');
    addTearDown(() => rootDir.delete(recursive: true));

    // A file node that was created (e.g. by another device) but whose
    // content upload never completed - `currentVersionId` stays null, so
    // materialize() never attempts (or succeeds at) writing anything for
    // it. This must never be mistaken for "the user deleted the local
    // copy": there never was one.
    final nodeId = generateUuidV4();
    final vaultId = uuidStringToBytes(FakeNodeServer.userId);
    final envelope = await MetadataCipher().encrypt(
      metadata: SensitiveNodeMetadata(fileName: 'pending-upload.txt'),
      metadataKey: vaultKey,
      keyVersion: homeBoxPersonalVaultKeyVersion,
      nodeType: MetadataNodeType.file,
      scopeId: vaultId,
      nodeId: uuidStringToBytes(nodeId),
    );
    fakeServer.remoteCreate(
      id: nodeId,
      nodeType: 'FILE',
      metadataCiphertext: base64Encode(envelope.encode()),
    );
    await syncEngine.runOnce();
    expect(syncEngine.nodeCache.getById(nodeId), isNotNull);

    await materializer.materialize(rootDir.path); // no content to download; writes nothing for this node.
    expect(syncEngine.materializedFiles.getById(nodeId), isNull);

    await uploader.scan(rootDir.path);
    expect(uploader.status, LocalUploadStatus.idle, reason: uploader.errorMessage);

    expect(syncEngine.nodeCache.getById(nodeId)!.isDeleted, isFalse, reason: 'a never-downloaded file must never be treated as user-deleted');
  });

  test('scan ignores files placed inside a brand-new, untracked local subfolder', () async {
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
    final uploader = LocalFolderUploader(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore, syncEngine: syncEngine);
    addTearDown(uploader.dispose);

    final rootDir = await Directory.systemTemp.createTemp('homebox_uploader_root_');
    addTearDown(() => rootDir.delete(recursive: true));
    final newSubfolder = await Directory('${rootDir.path}/New Folder').create();
    await File('${newSubfolder.path}/inside.txt').writeAsBytes(utf8.encode('should not be uploaded'));

    await uploader.scan(rootDir.path);
    expect(uploader.status, LocalUploadStatus.idle, reason: uploader.errorMessage);
    expect(syncEngine.nodeCache.listChildren(null), isEmpty, reason: 'new subfolders are out of scope for this slice');
  });
}
