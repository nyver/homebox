import '../support/test_key_ring.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
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
import 'package:homebox_client/features/sync/outbox_conflict_resolver.dart';
import 'package:homebox_client/features/sync/sync_engine.dart';
import 'package:homebox_client/features/syncfolder/local_folder_uploader.dart';
import 'package:homebox_client/features/syncfolder/sync_folder_materializer.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../support/memory_vault_key_storage.dart';
import 'fake_node_server.dart';

/// The device label every conflict test embeds in conflict-copy names.
const String conflictTestDeviceName = 'test-pc';

/// Matches a conflict copy of `<base><extension>` made by this test device.
RegExp conflictCopyPattern(String base, String extension) => RegExp(
  '^${RegExp.escape(base)} \\(conflict - $conflictTestDeviceName - '
  r'\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2} UTC\)'
  '${RegExp.escape(extension)}\$',
);

/// One device wired end to end against [FakeNodeServer], plus helpers that
/// play "another device" by mutating the server through the real API.
final class ConflictHarness {
  ConflictHarness._({
    required this.fakeServer,
    required this.serverConnection,
    required this.vaultKeyStore,
    required this.engine,
    required this.files,
    required this.materializer,
    required this.uploader,
    required this.root,
  });

  final FakeNodeServer fakeServer;
  final ServerConnectionController serverConnection;
  final VaultKeyStore vaultKeyStore;
  final SyncEngine engine;
  final FilesController files;
  final SyncFolderMaterializer materializer;
  final LocalFolderUploader uploader;
  final Directory root;

  static Future<ConflictHarness> create() async {
    final fakeServer = FakeNodeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
      sessionStore: SessionStore(MemorySessionStorage()),
    );
    addTearDown(serverConnection.dispose);
    await serverConnection.discover('127.0.0.1:${httpServer.port}');
    await serverConnection.confirmTrust();
    await serverConnection.login('admin', 'correct horse battery staple');
    expect(
      serverConnection.status,
      ServerConnectionStatus.authenticated,
      reason: serverConnection.errorMessage,
    );
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    (await vaultKeyStore.createVault(userId: FakeNodeServer.userId)).destroy();
    final engine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
      conflictResolver: VaultOutboxConflictResolver(vaultKeyStore),
    );
    addTearDown(engine.dispose);
    final files = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: engine,
    );
    addTearDown(files.dispose);
    final materializer = SyncFolderMaterializer(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: engine,
      deviceName: conflictTestDeviceName,
    );
    addTearDown(materializer.dispose);
    final uploader = LocalFolderUploader(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: engine,
      deviceName: conflictTestDeviceName,
    );
    addTearDown(uploader.dispose);
    final root = await Directory.systemTemp.createTemp('homebox_conflicts_');
    addTearDown(() => root.delete(recursive: true));
    return ConflictHarness._(
      fakeServer: fakeServer,
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      engine: engine,
      files: files,
      materializer: materializer,
      uploader: uploader,
      root: root,
    );
  }

  String get _accessToken => serverConnection.session!.accessToken;
  Uint8List get _vaultId => uuidStringToBytes(FakeNodeServer.userId);

  /// Uploads a new root file named [name] through the Files page.
  Future<FileEntry> uploadRootFile(String name, String content) async {
    final source = await Directory.systemTemp.createTemp('homebox_src_');
    addTearDown(() => source.delete(recursive: true));
    final file = File('${source.path}/$name');
    await file.writeAsString(content);
    expect(
      await files.uploadFile(file.path),
      isTrue,
      reason: files.errorMessage,
    );
    await files.refresh();
    return files.entries.firstWhere((entry) => entry.name == name);
  }

  /// Another device replaces [nodeId]'s content with [content].
  Future<void> remoteReplaceContent(String nodeId, String content) async {
    final api = serverConnection.api!;
    final vaultKey = (await vaultKeyStore.loadVaultKey())!;
    final node = await api.getNode(_accessToken, nodeId);
    final current = await serverMetadata(nodeId);
    final bytes = Uint8List.fromList(utf8.encode(content));
    final metadata = await MetadataCipher().encrypt(
      metadata: SensitiveNodeMetadata(
        fileName: current.fileName,
        plaintextSha256: sha256Hex(content),
        plaintextSize: bytes.length,
      ),
      metadataKey: vaultKey,
      keyVersion: homeBoxPersonalVaultKeyVersion,
      nodeType: MetadataNodeType.file,
      scopeId: _vaultId,
      nodeId: uuidStringToBytes(nodeId),
    );
    await uploadFileVersion(
      api: api,
      accessToken: _accessToken,
      key: vaultScopedKey(vaultKey, FakeNodeServer.userId),
      targetNodeId: nodeId,
      expectedRevision: node.revision,
      bytes: bytes,
      metadataCiphertext: metadata.encode(),
    );
  }

  /// Another device renames [nodeId] to [newName], keeping its content.
  Future<void> remoteRename(String nodeId, String newName) async {
    final api = serverConnection.api!;
    final vaultKey = (await vaultKeyStore.loadVaultKey())!;
    final node = await api.getNode(_accessToken, nodeId);
    final current = await serverMetadata(nodeId);
    final metadata = await MetadataCipher().encrypt(
      metadata: SensitiveNodeMetadata(
        fileName: newName,
        plaintextSha256: current.plaintextSha256,
        plaintextSize: current.plaintextSize,
      ),
      metadataKey: vaultKey,
      keyVersion: homeBoxPersonalVaultKeyVersion,
      nodeType: node.nodeType == 'DIRECTORY'
          ? MetadataNodeType.directory
          : MetadataNodeType.file,
      scopeId: _vaultId,
      nodeId: uuidStringToBytes(nodeId),
    );
    await api.updateNode(
      _accessToken,
      nodeId,
      operationId: generateUuidV4(),
      expectedRevision: node.revision,
      metadataCiphertext: metadata.encode(),
      metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
      moveParent: false,
      parentId: node.parentId,
    );
  }

  /// The server's current decrypted metadata for [nodeId].
  Future<SensitiveNodeMetadata> serverMetadata(String nodeId) async {
    final node = await serverConnection.api!.getNode(_accessToken, nodeId);
    return MetadataCipher().decrypt(
      envelope: EncryptedMetadataEnvelope.decode(node.metadataCiphertext),
      metadataKey: (await vaultKeyStore.loadVaultKey())!,
      nodeType: node.nodeType == 'DIRECTORY'
          ? MetadataNodeType.directory
          : MetadataNodeType.file,
      scopeId: _vaultId,
      nodeId: uuidStringToBytes(nodeId),
    );
  }

  /// The server's current plaintext of [nodeId].
  Future<String> serverContent(String nodeId) async => utf8.decode(
    await downloadAndDecryptFile(
      api: serverConnection.api!,
      accessToken: _accessToken,
      keys: vaultOnlyKeyRing(
        (await vaultKeyStore.loadVaultKey())!,
        FakeNodeServer.userId,
      ),
      nodeId: nodeId,
    ),
  );

  /// Names of the plain files directly inside the sync-folder root.
  Future<List<String>> rootFileNames() async {
    final names = <String>[];
    await for (final entity in root.list()) {
      if (entity is File) {
        names.add(entity.uri.pathSegments.last);
      }
    }
    return names..sort();
  }
}

String sha256Hex(String content) =>
    crypto.sha256.convert(utf8.encode(content)).toString();
