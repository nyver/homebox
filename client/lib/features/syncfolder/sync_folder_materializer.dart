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
import '../files/file_transfer.dart';
import '../server/server_connection_controller.dart';
import '../sync/sync_engine.dart';

enum SyncFolderStatus { idle, materializing, error }

/// Mirrors the vault's current contents onto disk under a user-chosen root
/// folder (spec §8/Milestone 8's pull direction): every non-deleted
/// directory node becomes a real folder, every non-deleted file node with
/// uploaded content becomes a decrypted file at the matching path. Driven
/// by [SyncEngine]'s local cache only — it never talks to the server for
/// listings, just for downloading content that changed.
///
/// This intentionally only mirrors server -> disk. Detecting edits made
/// directly in the folder and uploading them (the watcher / upload
/// direction) is a separate, later piece — see the roadmap notes in
/// README.md.
///
/// Known limitation: only files are tracked for pruning/relocation
/// ([MaterializedFilesStore] has no directory-level equivalent), so an
/// empty folder left behind by a rename or delete is not removed from
/// disk. Harmless (no data loss, no security impact — the folder is
/// simply empty), but worth fixing alongside the watcher slice.
final class SyncFolderMaterializer extends ChangeNotifier {
  SyncFolderMaterializer({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required SyncEngine syncEngine,
  })  : _serverConnection = serverConnection,
        _vaultKeyStore = vaultKeyStore,
        _syncEngine = syncEngine;

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;
  final MetadataCipher _metadataCipher = MetadataCipher();

  bool _running = false;
  bool _disposed = false;
  SyncFolderStatus _status = SyncFolderStatus.idle;
  String? _errorMessage;

  SyncFolderStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// Mirrors the current vault contents into [rootPath]. Safe to call
  /// repeatedly (e.g. after every [SyncEngine] pull); a call already in
  /// flight is not duplicated. A node this device cannot decrypt, or a
  /// single file that fails to download, is skipped rather than aborting
  /// the whole pass — it is simply retried on the next call.
  Future<void> materialize(String rootPath) async {
    if (_running) return;
    final api = _serverConnection.api;
    final session = _serverConnection.session;
    final vaultKey = await _vaultKeyStore.loadVaultKey();
    if (api == null || session == null || vaultKey == null) return;
    _running = true;
    _setStatus(SyncFolderStatus.materializing);
    try {
      final vaultId = uuidStringToBytes(session.user.id);
      final accessToken = session.accessToken;
      final seenNodeIds = <String>{};
      await _materializeDirectory(
        rootPath: rootPath,
        parentId: null,
        relativePath: '',
        api: api,
        accessToken: accessToken,
        vaultKey: vaultKey,
        vaultId: vaultId,
        seenNodeIds: seenNodeIds,
      );
      await _pruneUnseen(rootPath, seenNodeIds);
      _errorMessage = null;
      _setStatus(SyncFolderStatus.idle);
    } catch (e) {
      _errorMessage = '$e';
      _setStatus(SyncFolderStatus.error);
    } finally {
      _running = false;
    }
  }

  Future<void> _materializeDirectory({
    required String rootPath,
    required String? parentId,
    required String relativePath,
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required SecretKey vaultKey,
    required Uint8List vaultId,
    required Set<String> seenNodeIds,
  }) async {
    for (final node in _syncEngine.nodeCache.listChildren(parentId)) {
      final SensitiveNodeMetadata metadata;
      try {
        metadata = await _decryptMetadata(node, vaultKey, vaultId);
      } catch (_) {
        // Can't decrypt or parse this node's metadata (wrong/missing key
        // version, malformed envelope) - skip it, matching how
        // FilesController.refresh treats the same failure.
        continue;
      }
      seenNodeIds.add(node.id);
      final childRelativePath = relativePath.isEmpty ? metadata.fileName : '$relativePath/${metadata.fileName}';
      if (node.isDirectory) {
        await Directory('$rootPath/$childRelativePath').create(recursive: true);
        await _materializeDirectory(
          rootPath: rootPath,
          parentId: node.id,
          relativePath: childRelativePath,
          api: api,
          accessToken: accessToken,
          vaultKey: vaultKey,
          vaultId: vaultId,
          seenNodeIds: seenNodeIds,
        );
      } else {
        await _materializeFile(
          node: node,
          metadata: metadata,
          relativePath: childRelativePath,
          rootPath: rootPath,
          api: api,
          accessToken: accessToken,
          vaultKey: vaultKey,
          vaultId: vaultId,
        );
      }
    }
  }

  Future<void> _materializeFile({
    required LocalNode node,
    required SensitiveNodeMetadata metadata,
    required String relativePath,
    required String rootPath,
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required SecretKey vaultKey,
    required Uint8List vaultId,
  }) async {
    final targetPath = '$rootPath/$relativePath';
    final existing = _syncEngine.materializedFiles.getById(node.id);
    // Compare file *version* IDs, not the node's revision: a pure
    // rename/move bumps the revision too (it is just another UPDATE) but
    // does not create a new file version, so this is the only reliable way
    // to tell "just moved" apart from "content actually changed."
    if (existing != null && existing.contentVersionId == node.currentVersionId) {
      if (existing.relativePath != relativePath) {
        // Only the name/location changed since last time; relocate the
        // bytes already on disk instead of re-downloading them.
        final oldFile = File('$rootPath/${existing.relativePath}');
        if (await oldFile.exists()) {
          await Directory(File(targetPath).parent.path).create(recursive: true);
          await oldFile.rename(targetPath);
        }
        _syncEngine.materializedFiles.upsert(MaterializedFile(nodeId: node.id, relativePath: relativePath, contentVersionId: node.currentVersionId));
      }
      return; // content unchanged; nothing else to do.
    }
    if (node.currentVersionId == null) return; // node created but no content uploaded yet.
    try {
      final bytes = await downloadAndDecryptFile(
        api: api,
        accessToken: accessToken,
        vaultKey: vaultKey,
        vaultId: vaultId,
        nodeId: node.id,
        expectedPlaintextSha256: metadata.plaintextSha256,
      );
      await Directory(File(targetPath).parent.path).create(recursive: true);
      final tempPath = '$targetPath.homebox-tmp';
      await File(tempPath).writeAsBytes(bytes, flush: true);
      await File(tempPath).rename(targetPath); // atomic replace on the same volume.
      if (existing != null && existing.relativePath != relativePath) {
        // Content changed and it moved/was renamed in the same pass -
        // clean up the stale copy at its old location.
        final oldFile = File('$rootPath/${existing.relativePath}');
        if (await oldFile.exists()) await oldFile.delete();
      }
      _syncEngine.materializedFiles.upsert(MaterializedFile(nodeId: node.id, relativePath: relativePath, contentVersionId: node.currentVersionId));
    } catch (_) {
      // Broad on purpose: downloadAndDecryptFile can throw StateError
      // (e.g. hash mismatch), which does not extend Exception. Leave this
      // file for the next materialize() call rather than aborting the
      // whole tree over one bad download.
    }
  }

  Future<void> _pruneUnseen(String rootPath, Set<String> seenNodeIds) async {
    for (final entry in _syncEngine.materializedFiles.listAll()) {
      if (seenNodeIds.contains(entry.nodeId)) continue;
      final file = File('$rootPath/${entry.relativePath}');
      if (await file.exists()) {
        await file.delete();
      }
      _syncEngine.materializedFiles.remove(entry.nodeId);
    }
  }

  Future<SensitiveNodeMetadata> _decryptMetadata(LocalNode node, SecretKey vaultKey, Uint8List vaultId) {
    final envelope = EncryptedMetadataEnvelope.decode(node.metadataCiphertext);
    return _metadataCipher.decrypt(
      envelope: envelope,
      metadataKey: vaultKey,
      nodeType: node.isDirectory ? MetadataNodeType.directory : MetadataNodeType.file,
      scopeId: vaultId,
      nodeId: uuidStringToBytes(node.id),
    );
  }

  void _setStatus(SyncFolderStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
