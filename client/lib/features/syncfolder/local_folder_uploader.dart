// Constructor parameters are named to give callers readable arguments
// instead of the backing private field names (matches SyncEngine/FilesController).
// ignore_for_file: prefer_initializing_formals
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/materialized_files_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/local_path.dart';
import '../files/file_transfer.dart';
import '../server/server_connection_controller.dart';
import '../sync/sync_engine.dart';

enum LocalUploadStatus { idle, scanning, error }

/// Scans a local sync folder for changes made directly on disk and uploads
/// them (the push direction of Milestone 8; the pull direction is
/// [SyncFolderMaterializer]): a file with no matching node is uploaded as
/// one, an existing tracked file whose content no longer matches the
/// node's recorded hash is uploaded as a new version, and a tracked file
/// that has disappeared is deleted server-side.
///
/// Callers MUST always run [SyncFolderMaterializer.materialize] to
/// completion before calling [scan] on the same root, and never run the
/// two concurrently. [scan] tells "not yet downloaded" apart from "the
/// user deleted this" by checking [MaterializedFilesStore] — a node this
/// device has never successfully written to disk is left alone even if it
/// has no local file, rather than treated as a deletion. If a
/// materialization pass were still in flight (or skipped) when [scan]
/// runs, a file merely pending its first download would be
/// indistinguishable from one the user removed, and would be deleted
/// server-side by mistake.
///
/// A brand-new local subfolder is created remotely, then scanned recursively
/// so its initial tree is uploaded too. Local directory deletes remain
/// intentionally conservative: no directory-level materialization record
/// exists yet, so automatically deleting a remote subtree could mistake an
/// incomplete pull for user intent. A local rename is still seen as a delete
/// plus a new node rather than recognized as a rename of the existing one.
final class LocalFolderUploader extends ChangeNotifier {
  LocalFolderUploader({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required SyncEngine syncEngine,
  }) : _serverConnection = serverConnection,
       _vaultKeyStore = vaultKeyStore,
       _syncEngine = syncEngine;

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;
  final MetadataCipher _metadataCipher = MetadataCipher();

  bool _running = false;
  bool _disposed = false;
  LocalUploadStatus _status = LocalUploadStatus.idle;
  String? _errorMessage;

  LocalUploadStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// Scans [rootPath] for local changes and uploads them. Safe to call
  /// repeatedly; a call already in flight is not duplicated. A single
  /// file that fails to upload is skipped rather than aborting the whole
  /// pass — it is simply retried on the next call.
  Future<void> scan(String rootPath) async {
    if (_running) return;
    final api = _serverConnection.api;
    final session = _serverConnection.session;
    final vaultKey = await _vaultKeyStore.loadVaultKey();
    if (api == null || session == null || vaultKey == null) return;
    _running = true;
    _setStatus(LocalUploadStatus.scanning);
    try {
      final vaultId = uuidStringToBytes(session.user.id);
      await _scanDirectory(
        rootPath: rootPath,
        parentId: null,
        relativePath: '',
        api: api,
        accessToken: session.accessToken,
        keyScopeId: session.user.id,
        vaultKey: vaultKey,
        vaultId: vaultId,
      );
      _errorMessage = null;
      _setStatus(LocalUploadStatus.idle);
    } catch (e) {
      _errorMessage = '$e';
      _setStatus(LocalUploadStatus.error);
    } finally {
      _running = false;
    }
  }

  Future<void> _scanDirectory({
    required String rootPath,
    required String? parentId,
    required String relativePath,
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required String keyScopeId,
    required SecretKey vaultKey,
    required Uint8List vaultId,
  }) async {
    final dir = Directory(
      relativePath.isEmpty ? rootPath : '$rootPath/$relativePath',
    );
    if (!await dir.exists()) {
      return; // the whole folder is gone locally; out of scope for this slice.
    }

    final localFiles = <String, File>{};
    final localDirs = <String>{};
    await for (final entry in dir.list()) {
      final name = basenameOfLocalPath(entry.path);
      if (entry is File) {
        if (name.endsWith('.homebox-tmp')) {
          continue; // SyncFolderMaterializer's own in-flight temp file.
        }
        localFiles[name] = entry;
      } else if (entry is Directory) {
        localDirs.add(name);
      }
    }

    final expectedChildren = <String, (LocalNode, SensitiveNodeMetadata)>{};
    for (final node in _syncEngine.nodeCache.listChildren(parentId)) {
      try {
        final metadata = await _decryptMetadata(node, vaultKey, vaultId);
        expectedChildren[metadata.fileName] = (node, metadata);
      } catch (_) {
        // Can't decrypt or parse this node's metadata - skip it, matching
        // how SyncFolderMaterializer and FilesController.refresh treat the
        // same failure.
      }
    }

    for (final entry in expectedChildren.entries) {
      final name = entry.key;
      final (node, metadata) = entry.value;
      if (node.isDirectory) continue; // handled by the recursive pass below.
      final localFile = localFiles[name];
      if (localFile == null) {
        // Only treat this as a user deletion if this device has actually
        // written the file before — see the class doc comment for why.
        if (_syncEngine.materializedFiles.getById(node.id) != null) {
          await _deleteRemoteNode(api, accessToken, node);
        }
        continue;
      }
      await _uploadIfChanged(
        api: api,
        accessToken: accessToken,
        keyScopeId: keyScopeId,
        vaultKey: vaultKey,
        vaultId: vaultId,
        node: node,
        currentMetadata: metadata,
        name: name,
        relativePath: relativePath,
        localFile: localFile,
      );
    }

    for (final name in localFiles.keys) {
      if (expectedChildren.containsKey(name)) continue; // already handled above (or is a directory-named collision, skipped below).
      await _uploadNewFile(
        api: api,
        accessToken: accessToken,
        keyScopeId: keyScopeId,
        vaultKey: vaultKey,
        vaultId: vaultId,
        parentId: parentId,
        name: name,
        relativePath: relativePath,
        localFile: localFiles[name]!,
      );
    }

    for (final name in localDirs) {
      if (expectedChildren.containsKey(name)) continue;
      final createdDirectory = await _createRemoteDirectory(
        api: api,
        accessToken: accessToken,
        vaultKey: vaultKey,
        vaultId: vaultId,
        parentId: parentId,
        name: name,
      );
      if (createdDirectory == null) continue;
      await _scanDirectory(
        rootPath: rootPath,
        parentId: createdDirectory.id,
        relativePath: relativePath.isEmpty ? name : '$relativePath/$name',
        api: api,
        accessToken: accessToken,
        keyScopeId: keyScopeId,
        vaultKey: vaultKey,
        vaultId: vaultId,
      );
    }

    for (final entry in expectedChildren.entries) {
      final (node, _) = entry.value;
      if (!node.isDirectory) continue;
      if (!localDirs.contains(entry.key)) continue; // disappeared directories are deliberately not deleted remotely.
      await _scanDirectory(
        rootPath: rootPath,
        parentId: node.id,
        relativePath: relativePath.isEmpty
            ? entry.key
            : '$relativePath/${entry.key}',
        api: api,
        accessToken: accessToken,
        keyScopeId: keyScopeId,
        vaultKey: vaultKey,
        vaultId: vaultId,
      );
    }
  }

  Future<void> _uploadIfChanged({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required String keyScopeId,
    required SecretKey vaultKey,
    required Uint8List vaultId,
    required LocalNode node,
    required SensitiveNodeMetadata currentMetadata,
    required String name,
    required String relativePath,
    required File localFile,
  }) async {
    try {
      final plaintextLength = await localFile.length();
      if (plaintextLength > homeBoxMaxPlaintextFileSize) return;
      final hash = await plaintextFileSha256(localFile);
      if (currentMetadata.plaintextSha256?.toLowerCase() ==
          hash.toLowerCase()) {
        return; // unchanged - either untouched, or exactly what materialize() itself just wrote.
      }
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(fileName: name, plaintextSha256: hash),
        metadataKey: vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: MetadataNodeType.file,
        scopeId: vaultId,
        nodeId: uuidStringToBytes(node.id),
      );
      final metadataCiphertext = metadataEnvelope.encode();

      final uploadedNode = await uploadFilePathVersion(
        api: api,
        accessToken: accessToken,
        vaultKey: vaultKey,
        vaultId: vaultId,
        keyScopeId: keyScopeId,
        targetNodeId: node.id,
        expectedRevision: node.revision,
        file: localFile,
        plaintextLength: plaintextLength,
        expectedPlaintextSha256: hash,
        metadataCiphertext: metadataCiphertext,
      );
      // Two separate mutations, same reasoning as FilesController.replaceFileContent:
      // completing an upload does not itself update the node's own metadata.
      final finalNode = await api.updateNode(
        accessToken,
        node.id,
        operationId: generateUuidV4(),
        expectedRevision: uploadedNode.revision,
        metadataCiphertext: metadataCiphertext,
        metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
      );
      _syncEngine.nodeCache.upsert(localNodeFromServerNode(finalNode));
      _syncEngine.materializedFiles.upsert(
        MaterializedFile(
          nodeId: node.id,
          relativePath: relativePath.isEmpty ? name : '$relativePath/$name',
          contentVersionId: finalNode.currentVersionId,
        ),
      );
    } catch (_) {
      // Broad on purpose: this class's own checks and the shared crypto
      // helpers can throw StateError/ArgumentError, which do not extend
      // Exception. Leave this file for the next scan() call rather than
      // aborting the whole tree over one bad upload.
    }
  }

  Future<void> _uploadNewFile({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required String keyScopeId,
    required SecretKey vaultKey,
    required Uint8List vaultId,
    required String? parentId,
    required String name,
    required String relativePath,
    required File localFile,
  }) async {
    try {
      final plaintextLength = await localFile.length();
      if (plaintextLength > homeBoxMaxPlaintextFileSize) return;
      final hash = await plaintextFileSha256(localFile);

      final nodeId = generateUuidV4();
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(fileName: name, plaintextSha256: hash),
        metadataKey: vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: MetadataNodeType.file,
        scopeId: vaultId,
        nodeId: uuidStringToBytes(nodeId),
      );
      final metadataCiphertext = metadataEnvelope.encode();

      final createdNode = await api.createNode(
        accessToken,
        id: nodeId,
        operationId: generateUuidV4(),
        parentId: parentId,
        nodeType: 'FILE',
        metadataCiphertext: metadataCiphertext,
        metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
      );
      _syncEngine.nodeCache.upsert(localNodeFromServerNode(createdNode));

      final uploadedNode = await uploadFilePathVersion(
        api: api,
        accessToken: accessToken,
        vaultKey: vaultKey,
        vaultId: vaultId,
        keyScopeId: keyScopeId,
        targetNodeId: nodeId,
        expectedRevision: createdNode.revision,
        file: localFile,
        plaintextLength: plaintextLength,
        expectedPlaintextSha256: hash,
        metadataCiphertext: metadataCiphertext,
      );
      _syncEngine.nodeCache.upsert(localNodeFromServerNode(uploadedNode));
      // Record this device's own upload as already-materialized so the
      // next materialize() pass doesn't immediately re-download the bytes
      // it just read from disk.
      _syncEngine.materializedFiles.upsert(
        MaterializedFile(
          nodeId: nodeId,
          relativePath: relativePath.isEmpty ? name : '$relativePath/$name',
          contentVersionId: uploadedNode.currentVersionId,
        ),
      );
    } catch (_) {
      // Broad on purpose — see _uploadIfChanged.
    }
  }

  Future<LocalNode?> _createRemoteDirectory({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required SecretKey vaultKey,
    required Uint8List vaultId,
    required String? parentId,
    required String name,
  }) async {
    try {
      final nodeId = generateUuidV4();
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(fileName: name),
        metadataKey: vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: MetadataNodeType.directory,
        scopeId: vaultId,
        nodeId: uuidStringToBytes(nodeId),
      );
      final created = await api.createNode(
        accessToken,
        id: nodeId,
        operationId: generateUuidV4(),
        parentId: parentId,
        nodeType: 'DIRECTORY',
        metadataCiphertext: metadataEnvelope.encode(),
        metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
      );
      final local = localNodeFromServerNode(created);
      _syncEngine.nodeCache.upsert(local);
      return local;
    } catch (_) {
      // See _uploadIfChanged: leave this directory for the next scan instead
      // of aborting the entire tree because a single create failed.
      return null;
    }
  }

  Future<void> _deleteRemoteNode(
    transport.HomeBoxApiClient api,
    String accessToken,
    LocalNode node,
  ) async {
    try {
      await api.deleteNode(
        accessToken,
        node.id,
        operationId: generateUuidV4(),
        expectedRevision: node.revision,
      );
      // Refetch rather than assume the exact post-delete revision — a
      // soft-deleted node is still retrievable by design (that is what
      // Trash/restore relies on), matching how SyncEngine reconciles its
      // own mutations.
      final deletedNode = await api.getNode(accessToken, node.id);
      _syncEngine.nodeCache.upsert(localNodeFromServerNode(deletedNode));
      _syncEngine.materializedFiles.remove(node.id);
    } catch (_) {
      // Broad on purpose — see _uploadIfChanged. A REVISION_CONFLICT here
      // (someone else changed the file first) is left for the next scan()
      // pass, which will re-derive the correct outcome from fresh state.
    }
  }

  Future<SensitiveNodeMetadata> _decryptMetadata(
    LocalNode node,
    SecretKey vaultKey,
    Uint8List vaultId,
  ) {
    final envelope = EncryptedMetadataEnvelope.decode(node.metadataCiphertext);
    return _metadataCipher.decrypt(
      envelope: envelope,
      metadataKey: vaultKey,
      nodeType: node.isDirectory
          ? MetadataNodeType.directory
          : MetadataNodeType.file,
      scopeId: vaultId,
      nodeId: uuidStringToBytes(node.id),
    );
  }

  void _setStatus(LocalUploadStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

