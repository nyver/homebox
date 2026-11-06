// Constructor parameters are named to give callers readable arguments
// instead of the backing private field names (matches SyncEngine/FilesController).
// ignore_for_file: prefer_initializing_formals
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/platform/android_sync_folder.dart';
import '../../core/storage/materialized_files_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/sync_conflicts_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/local_path.dart';
import '../files/file_transfer.dart';
import '../server/server_connection_controller.dart';
import '../sharing/key_scopes.dart';
import '../sync/conflict_naming.dart';
import '../sync/sync_engine.dart';
import 'conflict_copies.dart';
import '../../core/util/user_facing_error.dart';
import '../../core/localization/user_text.dart';

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
///
/// Android's Storage Access Framework folder is handled by
/// [scanAndroidEdits] instead, which only publishes edits to files this
/// device materialized (see its doc comment).
final class LocalFolderUploader extends ChangeNotifier {
  LocalFolderUploader({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required SyncEngine syncEngine,
    AndroidSyncFolder? androidSyncFolder,
    String? deviceName,
    this.androidEditRetryDelay = const Duration(minutes: 5),
  }) : _serverConnection = serverConnection,
       _vaultKeyStore = vaultKeyStore,
       _syncEngine = syncEngine,
       _androidSyncFolder = androidSyncFolder,
       _deviceName = deviceName ?? localConflictDeviceName();

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;
  final AndroidSyncFolder? _androidSyncFolder;

  /// How long an Android edit that failed to upload waits before the same
  /// unchanged file is tried again (see [scanAndroidEdits]).
  final Duration androidEditRetryDelay;

  /// Failed Android edit uploads by node ID; in memory only, so restarting
  /// the app retries every pending edit at once.
  final Map<
    String,
    ({int size, int? modifiedMillis, int? nodeRevision, DateTime notBefore})
  >
  _androidRetryAfter = {};

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
    // Claimed before the first await, so a second caller arriving while the
    // session is being refreshed cannot start an overlapping pass.
    _running = true;
    try {
      await _scanLocked(rootPath);
    } finally {
      _running = false;
    }
  }

  Future<void> _scanLocked(String rootPath) async {
    final api = _serverConnection.api;
    // Not _serverConnection.session directly — see FilesController's
    // _requireContext for why (mobile OSes suspend background timers).
    final session = await _serverConnection.ensureFreshSession();
    if (api == null || session == null) return;
    final keys = await _openKeys(session.user.id);
    if (keys == null) return;
    _clearTransferProgress();
    _setStatus(LocalUploadStatus.scanning);
    try {
      await _scanDirectory(
        rootPath: rootPath,
        parentId: null,
        relativePath: '',
        api: api,
        accessToken: session.accessToken,
        keys: keys,
        tracked: _TrackedPaths.snapshot(_syncEngine),
      );
      _errorMessage = null;
      _setStatus(LocalUploadStatus.idle);
    } catch (e) {
      _errorMessage = describeError(e);
      _setStatus(LocalUploadStatus.error);
    } finally {
      keys.dispose();
      _clearTransferProgress();
    }
  }

  /// Publishes edits that other Android apps made to files this device has
  /// materialized into the Storage Access Framework tree [treeUri].
  ///
  /// SAF offers no change notifications for a document tree, so the caller
  /// polls: one recursive listing per call, and a file is read only when its
  /// size or modification time differs from what was recorded when it was
  /// last in sync. Its content hash then decides: an unchanged hash merely
  /// refreshes the recorded stat; a changed one is uploaded as the node's
  /// next version when the local copy is based on the server's current
  /// version, and otherwise (the server moved on, or the node was deleted)
  /// as a separate conflict copy (spec §21), so neither side's edit is lost.
  ///
  /// Unlike [scan], new and deleted local files are not mirrored back: the
  /// Android folder is a download mirror whose tracked files can be edited.
  /// Callers MUST run this before [SyncFolderMaterializer.materialize] on the
  /// same tree and never concurrently with it, so a pull never overwrites an
  /// edit that has not been published yet.
  Future<void> scanAndroidEdits(String treeUri) async {
    final android = _androidSyncFolder;
    if (android == null || _running) return;
    // Claimed before the first await, like [scan].
    _running = true;
    try {
      final records = _syncEngine.materializedFiles.listAll();
      if (records.isEmpty) return;
      // Listing needs neither the network nor the keys, so an idle pass
      // (the common case: this runs every sync cycle) stops here.
      final Map<String, AndroidDocumentStat> documents;
      try {
        documents = await android.listFiles(treeUri: treeUri);
      } catch (e) {
        _errorMessage = describeError(e);
        _setStatus(LocalUploadStatus.error);
        return;
      }
      final now = DateTime.now();
      final candidates = [
        for (final record in records)
          if (documents[record.relativePath] case final stat?)
            if (!record.matchesSizeAndModified(stat.size, stat.modified) &&
                !_androidRetryDeferred(record, stat, now))
              (record, stat),
      ];
      if (_androidRetryAfter.isNotEmpty) {
        final tracked = {for (final record in records) record.nodeId};
        _androidRetryAfter.removeWhere((id, _) => !tracked.contains(id));
      }
      if (candidates.isEmpty) {
        if (_status == LocalUploadStatus.error) {
          _errorMessage = null;
          _setStatus(LocalUploadStatus.idle);
        }
        return;
      }
      final api = _serverConnection.api;
      final session = await _serverConnection.ensureFreshSession();
      if (api == null || session == null) return;
      final keys = await _openKeys(session.user.id);
      if (keys == null) return;
      _clearTransferProgress();
      _setStatus(LocalUploadStatus.scanning);
      try {
        for (final (record, stat) in candidates) {
          await _publishAndroidEdit(
            android: android,
            treeUri: treeUri,
            api: api,
            accessToken: session.accessToken,
            keys: keys,
            record: record,
            stat: stat,
            documents: documents,
          );
        }
        _errorMessage = null;
        _setStatus(LocalUploadStatus.idle);
      } catch (e) {
        _errorMessage = describeError(e);
        _setStatus(LocalUploadStatus.error);
      } finally {
        keys.dispose();
        _clearTransferProgress();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _publishAndroidEdit({
    required AndroidSyncFolder android,
    required String treeUri,
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeys keys,
    required MaterializedFile record,
    required AndroidDocumentStat stat,
    required Map<String, AndroidDocumentStat> documents,
  }) async {
    File? copy;
    var failed = false;
    try {
      final cached = _syncEngine.nodeCache.getById(record.nodeId);
      final node = cached != null && !cached.isDeleted && !cached.isDirectory
          ? cached
          : null;
      final metadata = node == null ? null : await keys.decrypt(node);
      final basedOnCurrent =
          node != null &&
          node.currentVersionId != null &&
          record.contentVersionId == node.currentVersionId;
      final baseline =
          record.contentSha256 ??
          (basedOnCurrent ? metadata?.plaintextSha256 : null);
      void rememberStat({String? contentSha256}) =>
          _syncEngine.materializedFiles.upsert(
            MaterializedFile(
              nodeId: record.nodeId,
              relativePath: record.relativePath,
              contentVersionId: record.contentVersionId,
              localSize: stat.size,
              localModifiedAt: stat.modified,
              contentSha256: contentSha256 ?? record.contentSha256,
            ),
          );
      if (baseline == null && node != null) {
        // Nothing to compare against (content uploaded without a hash):
        // adopt the current stat, so edits are detected from here on. Not
        // for a deleted node, whose copy the next prune would then remove:
        // that copy is kept as a conflict copy below instead.
        rememberStat();
        return;
      }
      if (stat.size > homeBoxMaxPlaintextFileSize) return;
      if (baseline != null) {
        final localHash = await android.hashFile(
          treeUri: treeUri,
          relativePath: record.relativePath,
        );
        if (localHash == null) return; // removed meanwhile.
        if (localHash.toLowerCase() == baseline.toLowerCase()) {
          rememberStat(contentSha256: baseline); // touched, not changed.
          return;
        }
      }

      final edited = File(
        '${Directory.systemTemp.path}/homebox_android_edit_${generateUuidV4()}.tmp',
      );
      copy = edited;
      if (!await android.readFile(
        treeUri: treeUri,
        relativePath: record.relativePath,
        destinationPath: edited.path,
      )) {
        return;
      }
      // Hash what is actually uploaded: the editing app may still have been
      // writing while the native hash ran. The recorded stat stays the one
      // listed before reading, so a write landing during the upload no longer
      // matches it and is published by the next pass.
      final plaintextLength = await edited.length();
      if (plaintextLength > homeBoxMaxPlaintextFileSize) {
        failed = true; // grew past the limit while being read.
        return;
      }
      final hash = await plaintextFileSha256(edited);

      if (basedOnCurrent) {
        await _uploadAndroidVersion(
          api: api,
          accessToken: accessToken,
          keys: keys,
          node: node,
          metadata: metadata!,
          record: record,
          stat: stat,
          file: edited,
          plaintextLength: plaintextLength,
          hash: hash,
        );
        return;
      }

      // The edit is not based on what the server holds now: keep it as a
      // separate conflict copy next to the original (at the vault root when
      // the original's folder is gone too). The materializer then downloads
      // that copy into the folder like any other new file.
      final fileName =
          metadata?.fileName ?? basenameOfLocalPath(record.relativePath);
      final copyPath = _freeAndroidConflictCopyPath(
        record.relativePath,
        fileName,
        documents,
      );
      final kind = node == null
          ? SyncConflictKind.modifiedLocallyDeletedRemotely
          : SyncConflictKind.bothModified;
      final detectedAt = DateTime.now().toUtc();
      // Logged only once the copy is on the server: a file that keeps
      // failing must not add a conflict entry on every polling pass.
      final copyNodeId = await _uploadNewFile(
        api: api,
        accessToken: accessToken,
        keys: keys,
        parentId: node?.parentId ?? _liveParentOf(cached),
        name: basenameOfLocalPath(copyPath),
        relativePath: '',
        localFile: edited,
        conflict: SyncConflict(
          id: generateUuidV4(),
          kind: kind,
          detectedAt: detectedAt,
          nodeId: record.nodeId,
          fileName: fileName,
          conflictCopyPath: copyPath,
        ),
        recordMaterialized: false,
      );
      if (copyNodeId == null) {
        failed = true;
        return;
      }
      final conflict = _syncEngine.conflicts.record(
        kind: kind,
        nodeId: record.nodeId,
        fileName: fileName,
        conflictCopyPath: copyPath,
        detectedAt: detectedAt,
      );
      _syncEngine.conflicts.markCopyUploaded(conflict.id, copyNodeId);
      // The edit now lives on the server, so the materializer may replace
      // (or remove) the local copy like an untouched one.
      rememberStat();
    } catch (_) {
      // Broad on purpose — see _uploadIfChanged. The record keeps its old
      // stat, so a later pass retries while the materializer leaves the
      // edited copy alone.
      failed = true;
    } finally {
      if (failed) {
        _androidRetryAfter[record.nodeId] = (
          size: stat.size,
          modifiedMillis: stat.modified?.millisecondsSinceEpoch,
          nodeRevision: _syncEngine.nodeCache.getById(record.nodeId)?.revision,
          notBefore: DateTime.now().add(androidEditRetryDelay),
        );
      } else {
        _androidRetryAfter.remove(record.nodeId);
      }
      final leftover = copy;
      if (leftover != null && await leftover.exists()) {
        await leftover.delete();
      }
    }
  }

  /// True while an earlier attempt to publish this exact edit failed
  /// recently. Without this, a file the server keeps refusing (say, in a
  /// folder shared read-only) would be read, hashed and uploaded again on
  /// every sync cycle. A further edit, or any change of the node, retries at
  /// once.
  bool _androidRetryDeferred(
    MaterializedFile record,
    AndroidDocumentStat stat,
    DateTime now,
  ) {
    final retry = _androidRetryAfter[record.nodeId];
    return retry != null &&
        now.isBefore(retry.notBefore) &&
        retry.size == stat.size &&
        retry.modifiedMillis == stat.modified?.millisecondsSinceEpoch &&
        retry.nodeRevision ==
            _syncEngine.nodeCache.getById(record.nodeId)?.revision;
  }

  Future<void> _uploadAndroidVersion({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeys keys,
    required LocalNode node,
    required SensitiveNodeMetadata metadata,
    required MaterializedFile record,
    required AndroidDocumentStat stat,
    required File file,
    required int plaintextLength,
    required String hash,
  }) async {
    final key = await keys.forExisting(node);
    final metadataCiphertext = (await _metadataCipher.encrypt(
      metadata: SensitiveNodeMetadata(
        fileName: metadata.fileName,
        mimeType: metadata.mimeType,
        plaintextSha256: hash,
        plaintextSize: plaintextLength,
        // Editing a conflict copy does not resolve it (see _uploadIfChanged).
        conflictDetails: metadata.conflictDetails,
        labels: metadata.labels,
      ),
      metadataKey: key.key,
      keyVersion: key.version,
      nodeType: MetadataNodeType.file,
      scopeId: key.scopeIdBytes,
      nodeId: uuidStringToBytes(node.id),
    )).encode();
    _setTransferProgress(metadata.fileName, 0);
    // A REVISION_CONFLICT (the server moved on meanwhile) throws: the record
    // still names the older version, so the next pass keeps the edit as a
    // conflict copy instead.
    final uploaded = await uploadFilePathVersion(
      api: api,
      accessToken: accessToken,
      key: key,
      targetNodeId: node.id,
      expectedRevision: node.revision,
      file: file,
      plaintextLength: plaintextLength,
      expectedPlaintextSha256: hash,
      metadataCiphertext: metadataCiphertext,
      onProgress: (progress) =>
          _setTransferProgress(metadata.fileName, progress),
    );
    _syncEngine.nodeCache.upsert(localNodeFromServerNode(uploaded));
    _syncEngine.materializedFiles.upsert(
      MaterializedFile(
        nodeId: node.id,
        relativePath: record.relativePath,
        contentVersionId: uploaded.currentVersionId,
        localSize: stat.size,
        localModifiedAt: stat.modified,
        contentSha256: hash,
      ),
    );
  }

  /// The parent of a deleted [node] while that folder still exists, so its
  /// conflict copy lands where the user last saw the file.
  String? _liveParentOf(LocalNode? node) {
    final parentId = node?.parentId;
    if (parentId == null) return null;
    final parent = _syncEngine.nodeCache.getById(parentId);
    return parent != null && !parent.isDeleted ? parentId : null;
  }

  /// A conflict-copy path next to [relativePath] that no local document
  /// uses yet.
  String _freeAndroidConflictCopyPath(
    String relativePath,
    String fileName,
    Map<String, AndroidDocumentStat> documents,
  ) {
    final slash = relativePath.lastIndexOf('/');
    final directory = slash == -1 ? '' : relativePath.substring(0, slash);
    String inDirectory(String name) =>
        directory.isEmpty ? name : '$directory/$name';
    final detectedAt = DateTime.now().toUtc();
    var path = inDirectory(
      conflictCopyName(
        fileName,
        deviceName: _deviceName,
        detectedAt: detectedAt,
      ),
    );
    while (documents.containsKey(path)) {
      path = inDirectory(
        conflictCopyName(
          fileName,
          deviceName: _deviceName,
          detectedAt: detectedAt,
          uniqueSuffix: generateUuidV4().substring(0, 8),
        ),
      );
    }
    return path;
  }

  /// The keys of one scan or Resync pass; disposed when the pass ends.
  Future<OwnerKeys?> _openKeys(String userId) => OwnerKeys.open(
    vaultKeyStore: _vaultKeyStore,
    nodeCache: _syncEngine.nodeCache,
    folderKeys: _syncEngine.folderKeys,
    userId: userId,
  );

  /// Replaces the active personal Vault with a fresh encrypted snapshot of
  /// [rootPath]. Existing root nodes are soft-deleted, so each whole subtree
  /// remains recoverable from Trash. The caller must pause SyncEngine and the
  /// filesystem watcher first: until this strict upload succeeds, the local
  /// folder is the only source of truth and must not be materialized from the
  /// partially rebuilt server tree.
  Future<bool> resyncFromLocalFolder(String rootPath) async {
    if (_running) return false;
    _running = true;
    try {
      return await _resyncLocked(rootPath);
    } finally {
      _running = false;
    }
  }

  Future<bool> _resyncLocked(String rootPath) async {
    _resyncRequiresRecovery = false;
    final root = Directory(rootPath);
    if (!await root.exists()) {
      _errorMessage = UserText.of(
        en: 'The selected local sync folder no longer exists.',
        ru: 'Выбранная локальная папка синхронизации больше не существует.',
      );
      _setStatus(LocalUploadStatus.error);
      return false;
    }
    final api = _serverConnection.api;
    final session = await _serverConnection.ensureFreshSession();
    final keys = session == null ? null : await _openKeys(session.user.id);
    if (api == null || session == null || keys == null) {
      _errorMessage = UserText.of(
        en: 'Connect to the server and unlock the E2EE vault before resyncing.',
        ru: 'Перед пересозданием подключитесь к серверу и разблокируйте хранилище.',
      );
      _setStatus(LocalUploadStatus.error);
      return false;
    }
    if (_syncEngine.pendingOperations.hasUnfinishedOperations) {
      keys.dispose();
      _errorMessage = UserText.of(
        en: 'Pending server changes must finish before the Vault can be rebuilt.',
        ru: 'Дождитесь отправки ожидающих изменений, прежде чем пересоздавать хранилище.',
      );
      _setStatus(LocalUploadStatus.error);
      return false;
    }

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
            UserText.of(
              en: 'The server Vault kept changing while Resync was clearing it.',
              ru: 'Хранилище на сервере менялось, пока шла его очистка.',
            ),
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
        keys: keys,
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
      keys.dispose();
      _clearTransferProgress();
    }
  }

  Future<void> _scanDirectory({
    required String rootPath,
    required String? parentId,
    required String relativePath,
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeys keys,
    required _TrackedPaths tracked,
    bool strict = false,
  }) async {
    final dir = Directory(
      relativePath.isEmpty ? rootPath : '$rootPath/$relativePath',
    );
    if (!await dir.exists()) {
      if (strict) {
        throw StateError(
          UserText.of(
            en: 'The local folder changed while Resync was running.',
            ru: 'Локальная папка изменилась во время пересоздания.',
          ),
        );
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
        final metadata = await keys.decrypt(node);
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
        keys: keys,
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
        keys: keys,
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
        keys: keys,
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
        keys: keys,
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
        keys: keys,
        tracked: tracked,
        strict: strict,
      );
    }
  }

  Future<void> _uploadIfChanged({
    required String rootPath,
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeys keys,
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
          throw StateError(
            UserText.of(
              en: '$name exceeds the HomeBox file size limit.',
              ru: '$name превышает допустимый в HomeBox размер файла.',
            ),
          );
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
          keys: keys,
          parentId: node.parentId,
          name: basenameOfLocalPath(copyPath),
          relativePath: relativePath,
          localFile: File('$rootPath/$copyPath'),
        );
        return;
      }
      final key = await keys.forExisting(node);
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: name,
          mimeType: currentMetadata.mimeType,
          plaintextSha256: hash,
          plaintextSize: plaintextLength,
          // Editing a conflict copy does not resolve it; only the explicit
          // "Mark conflict resolved" action clears the marker.
          conflictDetails: currentMetadata.conflictDetails,
          labels: currentMetadata.labels,
        ),
        metadataKey: key.key,
        keyVersion: key.version,
        nodeType: MetadataNodeType.file,
        scopeId: key.scopeIdBytes,
        nodeId: uuidStringToBytes(node.id),
      );
      final metadataCiphertext = metadataEnvelope.encode();
      _setTransferProgress(name, 0);

      final uploadedNode = await uploadFilePathVersion(
        api: api,
        accessToken: accessToken,
        key: key,
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

  /// Uploads [localFile] as a new node named [name] and returns its ID, or
  /// null when it was skipped or failed. [conflict] overrides the conflict
  /// looked up by the copy's path; [recordMaterialized] is false when
  /// [localFile] is not the copy in the sync folder itself (Android uploads
  /// a temporary copy).
  Future<String?> _uploadNewFile({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeys keys,
    required String? parentId,
    required String name,
    required String relativePath,
    required File localFile,
    bool strict = false,
    SyncConflict? conflict,
    bool recordMaterialized = true,
  }) async {
    try {
      final stat = await localFile.stat();
      final plaintextLength = stat.size;
      if (plaintextLength > homeBoxMaxPlaintextFileSize) {
        if (strict) {
          throw StateError(
            UserText.of(
              en: '$name exceeds the HomeBox file size limit.',
              ru: '$name превышает допустимый в HomeBox размер файла.',
            ),
          );
        }
        return null;
      }
      final hash = await plaintextFileSha256(localFile);
      final fileRelativePath = relativePath.isEmpty
          ? name
          : '$relativePath/$name';
      // A conflict copy kept by this device carries its explanation inside
      // the encrypted metadata, so every device can show it.
      conflict ??= _syncEngine.conflicts.copyAwaitingUpload(fileRelativePath);

      final nodeId = generateUuidV4();
      final key = await keys.forNewChild(parentId);
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
        metadataKey: key.key,
        keyVersion: key.version,
        nodeType: MetadataNodeType.file,
        scopeId: key.scopeIdBytes,
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
        metadataKeyVersion: key.version,
        metadataKeyScopeId: key.scopeId,
      );
      _syncEngine.nodeCache.upsert(localNodeFromServerNode(createdNode));
      _setTransferProgress(name, 0);

      final uploadedNode = await uploadFilePathVersion(
        api: api,
        accessToken: accessToken,
        key: key,
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
      if (recordMaterialized) {
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
      }
      if (conflict != null) {
        _syncEngine.conflicts.markCopyUploaded(conflict.id, nodeId);
      }
      return nodeId;
    } catch (error) {
      if (strict) rethrow;
      // Broad on purpose — see _uploadIfChanged.
      return null;
    }
  }

  Future<LocalNode?> _createRemoteDirectory({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeys keys,
    required String? parentId,
    required String name,
    bool strict = false,
  }) async {
    try {
      final nodeId = generateUuidV4();
      final key = await keys.forNewChild(parentId);
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(fileName: name),
        metadataKey: key.key,
        keyVersion: key.version,
        nodeType: MetadataNodeType.directory,
        scopeId: key.scopeIdBytes,
        nodeId: uuidStringToBytes(nodeId),
      );
      final created = await api.createNode(
        accessToken,
        id: nodeId,
        operationId: generateUuidV4(),
        parentId: parentId,
        nodeType: 'DIRECTORY',
        metadataCiphertext: metadataEnvelope.encode(),
        metadataKeyVersion: key.version,
        metadataKeyScopeId: key.scopeId,
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
