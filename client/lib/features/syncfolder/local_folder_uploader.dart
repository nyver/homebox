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
import '../../core/storage/sync_conflicts_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/local_path.dart';
import '../files/file_transfer.dart';
import '../server/server_connection_controller.dart';
import '../sync/conflict_naming.dart';
import '../sync/sync_engine.dart';
import 'conflict_copies.dart';
import '../../core/util/user_facing_error.dart';

enum LocalUploadStatus { idle, scanning, resyncing, error }

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
/// so its initial tree is uploaded too. A previously materialized directory
/// that disappears locally is deleted remotely; a directory never written by
/// this device is left alone to avoid mistaking an incomplete pull for intent.
/// A local rename is still seen as a delete plus a new node rather than
/// recognized as a rename of the existing one.
///
/// A local file or folder still recorded as the materialized copy of some
/// node, but no longer matching a live node at that path, is never uploaded
/// as new: its node was moved to Trash, renamed, or moved on the server (or
/// in the Files page while a pass was running), and the next materialize()
/// pass removes or relocates it. Uploading it would resurrect a trashed file.
///
/// A tracked file whose size and modification time still match what was
/// recorded when its content was last verified is not re-hashed, so an idle
/// scan of a large folder costs a directory listing instead of reading every
/// byte again.
final class LocalFolderUploader extends ChangeNotifier {
  LocalFolderUploader({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required SyncEngine syncEngine,
    String? deviceName,
  }) : _serverConnection = serverConnection,
       _vaultKeyStore = vaultKeyStore,
       _syncEngine = syncEngine,
       _deviceName = deviceName ?? localConflictDeviceName();

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;

  /// Embedded in conflict-copy names and details (see SyncFolderMaterializer).
  final String _deviceName;
  final MetadataCipher _metadataCipher = MetadataCipher();

  bool _running = false;
  bool _disposed = false;
  LocalUploadStatus _status = LocalUploadStatus.idle;
  String? _errorMessage;
  String? _activeFileName;
  double? _transferProgress;
  bool _resyncRequiresRecovery = false;

  LocalUploadStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get activeFileName => _activeFileName;
  double? get transferProgress => _transferProgress;
  bool get resyncRequiresRecovery => _resyncRequiresRecovery;

  /// Scans [rootPath] for local changes and uploads them. Safe to call
  /// repeatedly; a call already in flight is not duplicated. A single
  /// file that fails to upload is skipped rather than aborting the whole
  /// pass — it is simply retried on the next call.
  Future<void> scan(String rootPath) async {
    if (_running) return;
    final api = _serverConnection.api;
    // Not _serverConnection.session directly — see FilesController's
    // _requireContext for why (mobile OSes suspend background timers).
    final session = await _serverConnection.ensureFreshSession();
    final vaultKey = await _vaultKeyStore.loadVaultKey();
    if (api == null || session == null || vaultKey == null) return;
    _running = true;
    _clearTransferProgress();
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
        tracked: _TrackedPaths.snapshot(_syncEngine),
      );
      _errorMessage = null;
      _setStatus(LocalUploadStatus.idle);
    } catch (e) {
      _errorMessage = describeError(e);
      _setStatus(LocalUploadStatus.error);
    } finally {
      _running = false;
      _clearTransferProgress();
    }
  }

  /// Replaces the active personal Vault with a fresh encrypted snapshot of
  /// [rootPath]. Existing root nodes are soft-deleted, so each whole subtree
  /// remains recoverable from Trash. The caller must pause SyncEngine and the
  /// filesystem watcher first: until this strict upload succeeds, the local
  /// folder is the only source of truth and must not be materialized from the
  /// partially rebuilt server tree.
  Future<bool> resyncFromLocalFolder(String rootPath) async {
    if (_running) return false;
    _resyncRequiresRecovery = false;
    final root = Directory(rootPath);
    if (!await root.exists()) {
      _errorMessage = 'The selected local sync folder no longer exists.';
      _setStatus(LocalUploadStatus.error);
      return false;
    }
    final api = _serverConnection.api;
    final session = await _serverConnection.ensureFreshSession();
    final vaultKey = await _vaultKeyStore.loadVaultKey();
    if (api == null || session == null || vaultKey == null) {
      _errorMessage =
          'Connect to the server and unlock the E2EE vault before resyncing.';
      _setStatus(LocalUploadStatus.error);
      return false;
    }
    if (_syncEngine.pendingOperations.hasUnfinishedOperations) {
      _errorMessage =
          'Pending server changes must finish before the Vault can be rebuilt.';
      _setStatus(LocalUploadStatus.error);
      return false;
    }

    _running = true;
    _clearTransferProgress();
    _setStatus(LocalUploadStatus.resyncing);
    try {
      // Forget old node-to-path associations before the first delete. If a
      // network failure leaves only part of the old Vault in Trash, a later
      // pull must never interpret those old IDs as permission to remove the
      // authoritative local files.
      _resyncRequiresRecovery = true;
      _syncEngine.materializedFiles.clear();
      _syncEngine.materializedDirectories.clear();
      _syncEngine.materializationFailures.clear();

      var clearPasses = 0;
      while (true) {
        final roots = await api.listChildren(
          session.accessToken,
          ownedOnly: true,
        );
        if (roots.isEmpty) break;
        if (clearPasses == 10) {
          throw StateError(
            'The server Vault kept changing while Resync was clearing it.',
          );
        }
        clearPasses++;
        for (final node in roots) {
          await api.deleteNode(
            session.accessToken,
            node.id,
            operationId: generateUuidV4(),
            expectedRevision: node.revision,
          );
          final deleted = await api.getNode(session.accessToken, node.id);
          _syncEngine.nodeCache.upsert(localNodeFromServerNode(deleted));
        }
      }

      await _scanDirectory(
        rootPath: rootPath,
        parentId: null,
        relativePath: '',
        api: api,
        accessToken: session.accessToken,
        keyScopeId: session.user.id,
        vaultKey: vaultKey,
        vaultId: uuidStringToBytes(session.user.id),
        tracked: _TrackedPaths.snapshot(_syncEngine),
        strict: true,
      );
      _errorMessage = null;
      _resyncRequiresRecovery = false;
      _setStatus(LocalUploadStatus.idle);
      return true;
    } catch (error) {
      _errorMessage = '$error';
      _setStatus(LocalUploadStatus.error);
      return false;
    } finally {
      _running = false;
      _clearTransferProgress();
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
    required _TrackedPaths tracked,
    bool strict = false,
  }) async {
    final dir = Directory(
      relativePath.isEmpty ? rootPath : '$rootPath/$relativePath',
    );
    if (!await dir.exists()) {
      if (strict) {
        throw StateError('The local folder changed while Resync was running.');
      }
      return; // the whole folder is gone locally; out of scope for this slice.
    }

    final localFiles = <String, File>{};
    final localDirs = <String>{};
    await for (final entry in dir.list()) {
      final name = basenameOfLocalPath(entry.path);
      if (entry is File) {
        if (isTransientSyncFileName(name)) {
          continue; // in-flight temp file or an open application's lock file.
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
        rootPath: rootPath,
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
        strict: strict,
      );
    }

    String childPath(String name) =>
        relativePath.isEmpty ? name : '$relativePath/$name';

    for (final name in localFiles.keys) {
      if (expectedChildren.containsKey(name)) continue; // already handled above (or is a directory-named collision, skipped below).
      // A stale copy of a node trashed, renamed or moved elsewhere; the
      // materializer cleans it up (see the class doc comment).
      if (tracked.files.contains(childPath(name))) continue;
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
        strict: strict,
      );
    }

    for (final name in localDirs) {
      if (expectedChildren.containsKey(name)) continue;
      if (tracked.directories.contains(childPath(name))) continue;
      final createdDirectory = await _createRemoteDirectory(
        api: api,
        accessToken: accessToken,
        vaultKey: vaultKey,
        vaultId: vaultId,
        parentId: parentId,
        name: name,
        strict: strict,
      );
      if (createdDirectory == null) continue;
      await _scanDirectory(
        rootPath: rootPath,
        parentId: createdDirectory.id,
        relativePath: childPath(name),
        api: api,
        accessToken: accessToken,
        keyScopeId: keyScopeId,
        vaultKey: vaultKey,
        vaultId: vaultId,
        tracked: tracked,
        strict: strict,
      );
    }

    for (final entry in expectedChildren.entries) {
      final (node, _) = entry.value;
      if (!node.isDirectory) continue;
      if (!localDirs.contains(entry.key)) {
        if (_syncEngine.materializedDirectories.getById(node.id) != null) {
          await _deleteRemoteNode(api, accessToken, node);
          _syncEngine.materializedDirectories.remove(node.id);
        }
        continue;
      }
      await _scanDirectory(
        rootPath: rootPath,
        parentId: node.id,
        relativePath: childPath(entry.key),
        api: api,
        accessToken: accessToken,
        keyScopeId: keyScopeId,
        vaultKey: vaultKey,
        vaultId: vaultId,
        tracked: tracked,
        strict: strict,
      );
    }
  }

  Future<void> _uploadIfChanged({
    required String rootPath,
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
    bool strict = false,
  }) async {
    try {
      final fileRelativePath = relativePath.isEmpty
          ? name
          : '$relativePath/$name';
      final stat = await localFile.stat();
      final materialized = _syncEngine.materializedFiles.getById(node.id);
      final recordedHere =
          materialized != null && materialized.relativePath == fileRelativePath;
      final materializedCurrent =
          recordedHere &&
          materialized.contentVersionId == node.currentVersionId;
      if (materializedCurrent && materialized.matchesLocalStat(stat)) {
        return; // untouched since its content was last verified.
      }
      final plaintextLength = stat.size;
      if (plaintextLength > homeBoxMaxPlaintextFileSize) {
        if (strict) {
          throw StateError('$name exceeds the HomeBox file size limit.');
        }
        return;
      }
      final hash = await plaintextFileSha256(localFile);
      if (currentMetadata.plaintextSha256?.toLowerCase() ==
          hash.toLowerCase()) {
        // Unchanged - either untouched, or exactly what materialize() itself
        // just wrote. Remember the stat so the next scan can skip the hash.
        if (materializedCurrent) {
          _syncEngine.materializedFiles.upsert(
            MaterializedFile(
              nodeId: node.id,
              relativePath: fileRelativePath,
              contentVersionId: node.currentVersionId,
              localSize: stat.size,
              localModifiedAt: stat.modified,
              contentSha256: hash,
            ),
          );
        }
        return;
      }
      if (!materializedCurrent && node.currentVersionId != null && !strict) {
        // The local file is not based on the server's current version: the
        // server moved on since this device last synced it, or the file
        // never came from this node at all. Uploading it as the next version
        // would silently replace someone else's change (spec §21). A node
        // without content yet (e.g. this device's own interrupted upload)
        // still receives the file as its first version below; a concurrent
        // first upload elsewhere makes one side lose the revision check,
        // and that side keeps its file as a conflict copy on the next pass.
        if (recordedHere &&
            await localCopyMatchesRecord(
              materialized,
              localFile,
              knownSha256: hash,
            )) {
          return; // an untouched older copy; materialize() refreshes it.
        }
        final copyPath = await preserveAsConflictCopy(
          rootPath: rootPath,
          relativePath: fileRelativePath,
          conflicts: _syncEngine.conflicts,
          kind: recordedHere
              ? SyncConflictKind.bothModified
              : SyncConflictKind.bothCreated,
          deviceName: _deviceName,
          nodeId: node.id,
        );
        await _uploadNewFile(
          api: api,
          accessToken: accessToken,
          keyScopeId: keyScopeId,
          vaultKey: vaultKey,
          vaultId: vaultId,
          parentId: node.parentId,
          name: basenameOfLocalPath(copyPath),
          relativePath: relativePath,
          localFile: File('$rootPath/$copyPath'),
        );
        return;
      }
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: name,
          plaintextSha256: hash,
          plaintextSize: plaintextLength,
          // Editing a conflict copy does not resolve it; only the explicit
          // "Mark conflict resolved" action clears the marker.
          conflictDetails: currentMetadata.conflictDetails,
          labels: currentMetadata.labels,
        ),
        metadataKey: vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: MetadataNodeType.file,
        scopeId: vaultId,
        nodeId: uuidStringToBytes(node.id),
      );
      final metadataCiphertext = metadataEnvelope.encode();
      _setTransferProgress(name, 0);

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
        onProgress: (progress) => _setTransferProgress(name, progress),
      );
      _syncEngine.nodeCache.upsert(localNodeFromServerNode(uploadedNode));
      _syncEngine.materializedFiles.upsert(
        MaterializedFile(
          nodeId: node.id,
          relativePath: fileRelativePath,
          contentVersionId: uploadedNode.currentVersionId,
          // Taken before hashing: an edit made during the upload changes the
          // stat, so the next scan hashes again instead of skipping it.
          localSize: stat.size,
          localModifiedAt: stat.modified,
          contentSha256: hash,
        ),
      );
    } catch (error) {
      if (strict) rethrow;
      // Broad on purpose: this class's own checks and the shared crypto
      // helpers can throw StateError/ArgumentError, which do not extend
      // Exception. Leave this file for the next scan() call rather than
      // aborting the whole tree over one bad upload. A REVISION_CONFLICT
      // (the server moved on mid-scan) is resolved by the next pass: the
      // record still names the older version, so the edit becomes a
      // conflict copy instead of overwriting the newer content.
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
    bool strict = false,
  }) async {
    try {
      final stat = await localFile.stat();
      final plaintextLength = stat.size;
      if (plaintextLength > homeBoxMaxPlaintextFileSize) {
        if (strict) {
          throw StateError('$name exceeds the HomeBox file size limit.');
        }
        return;
      }
      final hash = await plaintextFileSha256(localFile);
      final fileRelativePath = relativePath.isEmpty
          ? name
          : '$relativePath/$name';
      // A conflict copy kept by this device carries its explanation inside
      // the encrypted metadata, so every device can show it.
      final conflict = _syncEngine.conflicts.copyAwaitingUpload(
        fileRelativePath,
      );

      final nodeId = generateUuidV4();
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: name,
          plaintextSha256: hash,
          plaintextSize: plaintextLength,
          conflictDetails: conflict == null
              ? null
              : conflictCopyDetails(
                  originalName: conflict.fileName ?? name,
                  deviceName: _deviceName,
                  detectedAt: conflict.detectedAt,
                  reason: conflictCopyReason(conflict.kind),
                ),
        ),
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
      _setTransferProgress(name, 0);

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
        onProgress: (progress) => _setTransferProgress(name, progress),
      );
      _syncEngine.nodeCache.upsert(localNodeFromServerNode(uploadedNode));
      // Record this device's own upload as already-materialized so the
      // next materialize() pass doesn't immediately re-download the bytes
      // it just read from disk.
      _syncEngine.materializedFiles.upsert(
        MaterializedFile(
          nodeId: nodeId,
          relativePath: fileRelativePath,
          contentVersionId: uploadedNode.currentVersionId,
          localSize: stat.size,
          localModifiedAt: stat.modified,
          contentSha256: hash,
        ),
      );
      if (conflict != null) {
        _syncEngine.conflicts.markCopyUploaded(conflict.id, nodeId);
      }
    } catch (error) {
      if (strict) rethrow;
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
    bool strict = false,
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
    } catch (error) {
      if (strict) rethrow;
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

  void _setTransferProgress(String fileName, double progress) {
    _activeFileName = fileName;
    _transferProgress = progress.clamp(0, 1).toDouble();
    if (!_disposed) notifyListeners();
  }

  void _clearTransferProgress() {
    if (_activeFileName == null && _transferProgress == null) return;
    _activeFileName = null;
    _transferProgress = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Relative paths this device has materialized, read once per scan so the
/// per-entry checks stay in memory instead of querying SQLite per file.
final class _TrackedPaths {
  const _TrackedPaths({required this.files, required this.directories});

  factory _TrackedPaths.snapshot(SyncEngine syncEngine) => _TrackedPaths(
    files: {
      for (final file in syncEngine.materializedFiles.listAll())
        file.relativePath,
    },
    directories: {
      for (final directory in syncEngine.materializedDirectories.listAll())
        directory.relativePath,
    },
  );

  final Set<String> files;
  final Set<String> directories;
}
