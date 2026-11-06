// Constructor parameters are named to give callers readable arguments
// instead of the backing private field names (matches SyncEngine/FilesController).
// ignore_for_file: prefer_initializing_formals
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/scoped_metadata.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/platform/android_sync_folder.dart';
import '../../core/storage/materialized_directories_store.dart';
import '../../core/storage/materialized_files_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/sync_conflicts_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../files/file_transfer.dart';
import '../server/server_connection_controller.dart';
import '../sync/conflict_naming.dart';
import '../sync/sync_engine.dart';
import 'conflict_copies.dart';
import '../../core/util/user_facing_error.dart';

enum SyncFolderStatus { idle, materializing, error }

/// Mirrors the vault's current contents onto disk under a user-chosen root
/// folder (spec §8/Milestone 8's pull direction): every non-deleted
/// directory node becomes a real folder, every non-deleted file node with
/// uploaded content becomes a decrypted file at the matching path. Driven
/// by [SyncEngine]'s local cache only — it never talks to the server for
/// listings, just for downloading content that changed.
///
/// Local edits are observed by the sync-folder watcher, which asks the
/// desktop coordinator to run this pull pass before the uploader's push pass.
/// This class remains server -> disk only.
///
/// It never destroys local content the server does not have (spec §21). A
/// local file is replaced or removed only when it provably still holds what
/// this device last synchronized (see [localCopyMatchesRecord]); an edited
/// or unknown file in the way is first renamed to a conflict copy, which the
/// uploader then publishes as a separate node. Android's write-only SAF
/// mirror is never edited through HomeBox and keeps the plain behavior.
///
final class SyncFolderMaterializer extends ChangeNotifier {
  SyncFolderMaterializer({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required SyncEngine syncEngine,
    AndroidSyncFolder? androidSyncFolder,
    void Function({required String fileName, required String location})?
    onFileMaterialized,
    String? deviceName,
  }) : _serverConnection = serverConnection,
       _vaultKeyStore = vaultKeyStore,
       _syncEngine = syncEngine,
       _androidSyncFolder = androidSyncFolder,
       _onFileMaterialized = onFileMaterialized,
       _deviceName = deviceName ?? localConflictDeviceName();

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;
  final AndroidSyncFolder? _androidSyncFolder;

  /// Embedded in conflict-copy names so the user can tell which device
  /// kept which version.
  final String _deviceName;
  final void Function({required String fileName, required String location})?
  _onFileMaterialized;
  final MetadataCipher _metadataCipher = MetadataCipher();

  bool _running = false;
  bool _disposed = false;
  SyncFolderStatus _status = SyncFolderStatus.idle;
  String? _errorMessage;
  String? _activeFileName;
  double? _transferProgress;

  SyncFolderStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get activeFileName => _activeFileName;
  double? get transferProgress => _transferProgress;

  /// Mirrors the current vault contents into [rootPath]. Safe to call
  /// repeatedly (e.g. after every [SyncEngine] pull); a call already in
  /// flight is not duplicated. A node this device cannot decrypt, or a
  /// single file that fails to download, is skipped rather than aborting
  /// the whole pass — it is simply retried on the next call.
  Future<void> materialize(String rootPath) async {
    if (_running) return;
    // Claimed before the first await, so a second caller arriving while the
    // session is being refreshed cannot start an overlapping pass.
    _running = true;
    final api = _serverConnection.api;
    // Not _serverConnection.session directly — see FilesController's
    // _requireContext for why (mobile OSes suspend background timers).
    final transport.HomeBoxSession? session;
    final OwnerKeyRing? keys;
    try {
      session = await _serverConnection.ensureFreshSession();
      // Every key this account holds: its Vault Key and the keys of the
      // folders it shares, whose content is encrypted with them (ADR-023).
      keys = session == null
          ? null
          : await openOwnerKeyRing(
              vaultKeyStore: _vaultKeyStore,
              userId: session.user.id,
              wrappedFolderKeys: _syncEngine.folderKeys.all(),
            );
    } catch (_) {
      _running = false;
      rethrow;
    }
    if (api == null || session == null || keys == null) {
      _running = false;
      keys?.dispose();
      return;
    }
    _clearTransferProgress();
    _setStatus(SyncFolderStatus.materializing);
    try {
      final accessToken = session.accessToken;
      final seenNodeIds = <String>{};
      final fileErrors = <String>[];
      await _materializeDirectory(
        rootPath: rootPath,
        parentId: null,
        relativePath: '',
        api: api,
        accessToken: accessToken,
        keys: keys,
        seenNodeIds: seenNodeIds,
        fileErrors: fileErrors,
      );
      await _pruneUnseen(rootPath, seenNodeIds);
      if (fileErrors.isNotEmpty) {
        throw StateError(fileErrors.join('\n'));
      }
      _errorMessage = null;
      _setStatus(SyncFolderStatus.idle);
    } catch (e) {
      _errorMessage = describeError(e);
      _setStatus(SyncFolderStatus.error);
    } finally {
      keys.dispose();
      _running = false;
      _clearTransferProgress();
    }
  }

  Future<void> _materializeDirectory({
    required String rootPath,
    required String? parentId,
    required String relativePath,
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeyRing keys,
    required Set<String> seenNodeIds,
    required List<String> fileErrors,
  }) async {
    for (final node in _syncEngine.nodeCache.listChildren(parentId)) {
      // Seen means "still exists on the server", whether or not it can be
      // shown: only nodes absent from the cache may lose their local copy.
      seenNodeIds.add(node.id);
      final SensitiveNodeMetadata metadata;
      try {
        metadata = await _decryptMetadata(node, keys);
      } catch (_) {
        // Can't decrypt or parse this node's metadata (wrong/missing key
        // version, malformed envelope) - skip it, matching how
        // FilesController.refresh treats the same failure. Its subtree is not
        // walked either, so keep every descendant's existing local copy
        // rather than pruning it as if it had been deleted remotely.
        _markSubtreeSeen(node.id, seenNodeIds);
        continue;
      }
      final childRelativePath = relativePath.isEmpty
          ? metadata.fileName
          : '$relativePath/${metadata.fileName}';
      if (node.isDirectory) {
        final previous = _syncEngine.materializedDirectories.getById(node.id);
        await _createDirectory(rootPath, childRelativePath);
        _syncEngine.materializedDirectories.upsert(
          MaterializedDirectory(
            nodeId: node.id,
            relativePath: childRelativePath,
          ),
        );
        await _materializeDirectory(
          rootPath: rootPath,
          parentId: node.id,
          relativePath: childRelativePath,
          api: api,
          accessToken: accessToken,
          keys: keys,
          seenNodeIds: seenNodeIds,
          fileErrors: fileErrors,
        );
        if (previous != null && previous.relativePath != childRelativePath) {
          // Renamed or moved on the server: its files were relocated above,
          // so drop the now-empty old folder. Left behind, the uploader would
          // see an unknown local folder and create it remotely again.
          await _deleteEmptyDirectory(rootPath, previous.relativePath);
        }
      } else {
        await _materializeFile(
          node: node,
          metadata: metadata,
          relativePath: childRelativePath,
          rootPath: rootPath,
          api: api,
          accessToken: accessToken,
          keys: keys,
          fileErrors: fileErrors,
        );
      }
    }
  }

  void _markSubtreeSeen(String nodeId, Set<String> seenNodeIds) {
    final pending = [nodeId];
    while (pending.isNotEmpty) {
      for (final child in _syncEngine.nodeCache.listChildren(
        pending.removeLast(),
      )) {
        if (seenNodeIds.add(child.id)) pending.add(child.id);
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
    required OwnerKeyRing keys,
    required List<String> fileErrors,
  }) async {
    final targetPath = '$rootPath/$relativePath';
    final existing = _syncEngine.materializedFiles.getById(node.id);
    // Compare file *version* IDs, not the node's revision: a pure
    // rename/move bumps the revision too (it is just another UPDATE) but
    // does not create a new file version, so this is the only reliable way
    // to tell "just moved" apart from "content actually changed."
    if (existing != null &&
        existing.contentVersionId == node.currentVersionId) {
      if (existing.relativePath != relativePath && !_usesAndroidStorage) {
        // Only the name/location changed since last time; relocate the
        // bytes already on disk instead of re-downloading them.
        final oldFile = File('$rootPath/${existing.relativePath}');
        try {
          await _relocateLocalCopy(
            rootPath: rootPath,
            relativePath: relativePath,
            node: node,
            existing: existing,
            oldFile: oldFile,
          );
        } catch (error) {
          // E.g. the file is open in an application that locks it. Leave it
          // where it is for a later pass instead of aborting the whole tree.
          fileErrors.add('${metadata.fileName}: ${_localFileError(error)}');
          return;
        }
      }
      if (await _fileExists(rootPath, relativePath)) {
        return; // content is unchanged and present at its target path.
      }
    }
    if (node.currentVersionId == null) {
      return; // node created but no content uploaded yet.
    }
    final expectedHash = metadata.plaintextSha256;
    if (!_usesAndroidStorage && await File(targetPath).exists()) {
      // A Windows Files-page upload can copy its original plaintext straight
      // into the matching sync-folder location. Verify that local copy before
      // downloading ciphertext back from the server.
      final stat = await _localStat(targetPath);
      final localHash = await plaintextFileSha256(File(targetPath));
      if (expectedHash != null &&
          localHash.toLowerCase() == expectedHash.toLowerCase()) {
        _syncEngine.materializedFiles.upsert(
          MaterializedFile(
            nodeId: node.id,
            relativePath: relativePath,
            contentVersionId: node.currentVersionId,
            localSize: stat?.size,
            localModifiedAt: stat?.modified,
            contentSha256: localHash,
          ),
        );
        _syncEngine.materializationFailures.remove(node.id);
        return;
      }
      // The local file differs from the server's current version. Replace
      // it only if it is this node's own untouched older copy; otherwise it
      // is a concurrent edit (or an unrelated same-name file) and is kept.
      try {
        await _clearDestination(
          rootPath: rootPath,
          relativePath: relativePath,
          node: node,
          ownRecord: existing,
          knownSha256: localHash,
        );
      } catch (error) {
        // Never download over a local file that could not be moved aside.
        fileErrors.add('${metadata.fileName}: ${_localFileError(error)}');
        return;
      }
    }
    if (expectedHash != null &&
        _syncEngine.materializationFailures.contains(
          nodeId: node.id,
          contentVersionId: node.currentVersionId!,
          nodeRevision: node.revision,
        )) {
      if (!await _trashIntegrityFailedFile(
        node: node,
        rootPath: rootPath,
        relativePath: relativePath,
        existing: existing,
      )) {
        fileErrors.add(
          '${metadata.fileName}: integrity verification previously failed; automatic download is paused and the file could not be moved to Trash.',
        );
      }
      return;
    }
    try {
      if (!_isCurrentDownload(node)) return;
      _setTransferProgress(metadata.fileName, 0);
      final temporaryDirectory = Directory.systemTemp;
      final source = File(
        '${temporaryDirectory.path}/homebox_materialize_${node.id}_${generateUuidV4()}.tmp',
      );
      try {
        await downloadAndDecryptFileToPath(
          api: api,
          accessToken: accessToken,
          keys: keys,
          nodeId: node.id,
          expectedVersionId: node.currentVersionId,
          destinationPath: source.path,
          expectedPlaintextSha256: metadata.plaintextSha256,
          onProgress: (progress) {
            if (!_isCurrentDownload(node)) {
              throw const _MaterializationCancelled();
            }
            _setTransferProgress(metadata.fileName, progress);
          },
        );
        if (!_isCurrentDownload(node)) return;
        await _writeFile(rootPath, relativePath, targetPath, source);
      } finally {
        if (await source.exists()) await source.delete();
      }
      if (existing != null &&
          !_sameLocalPath(existing.relativePath, relativePath)) {
        // Content changed and it moved/was renamed in the same pass -
        // clean up the stale copy at its old location (kept if edited).
        await _removeLocalCopy(
          rootPath,
          existing,
          SyncConflictKind.bothModified,
        );
      }
      final stat = await _localStat(targetPath);
      _syncEngine.materializedFiles.upsert(
        MaterializedFile(
          nodeId: node.id,
          relativePath: relativePath,
          contentVersionId: node.currentVersionId,
          localSize: stat?.size,
          localModifiedAt: stat?.modified,
          contentSha256: metadata.plaintextSha256,
        ),
      );
      _syncEngine.materializationFailures.remove(node.id);
      // Only this path receives bytes from the server. Renames, moves, and
      // verified direct local copies use existing local bytes above, so they
      // must not look like a new download to the user.
      _onFileMaterialized?.call(
        fileName: metadata.fileName,
        location: _materializedLocation(relativePath, targetPath),
      );
    } on _MaterializationCancelled {
      // The node was replaced or moved to Trash while bytes were arriving.
      // A later pass will handle the new state; this is not a sync failure.
    } on FileIntegrityException catch (error) {
      if (expectedHash != null) {
        _syncEngine.materializationFailures.record(
          nodeId: node.id,
          contentVersionId: node.currentVersionId!,
          nodeRevision: node.revision,
        );
      }
      final trashed = await _trashIntegrityFailedFile(
        node: node,
        rootPath: rootPath,
        relativePath: relativePath,
        existing: existing,
      );
      if (!trashed && _isCurrentDownload(node)) {
        fileErrors.add(
          '${metadata.fileName}: $error Automatic move to Trash failed.',
        );
      }
    } catch (error) {
      // Broad on purpose: downloadAndDecryptFile can throw StateError
      // and cryptography can throw authentication errors that do not extend
      // Exception. Continue the tree, but surface a truthful error state
      // after the pass and retry transient/unknown failures next time.
      fileErrors.add('${metadata.fileName}: $error');
    }
  }

  /// Moves [existing]'s copy from [oldFile] to [relativePath] after a remote
  /// rename or move, without re-downloading unchanged content.
  Future<void> _relocateLocalCopy({
    required String rootPath,
    required String relativePath,
    required LocalNode node,
    required MaterializedFile existing,
    required File oldFile,
  }) async {
    if (!_ownsLocalPath(existing) || !await oldFile.exists()) return;
    // A case-only rename on a case-insensitive file system names the same
    // file; anything else already at the target is not ours.
    if (!_sameLocalPath(existing.relativePath, relativePath)) {
      await _clearDestination(
        rootPath: rootPath,
        relativePath: relativePath,
        node: node,
        ownRecord: null,
      );
    }
    // An edit made here before the remote rename is still unsynced. Forget
    // the stat then, so the uploader hashes the moved file and publishes the
    // edit instead of trusting it as this version.
    final unchanged = await localCopyMatchesRecord(existing, oldFile);
    final targetPath = '$rootPath/$relativePath';
    await Directory(File(targetPath).parent.path).create(recursive: true);
    await oldFile.rename(targetPath);
    final stat = unchanged ? await _localStat(targetPath) : null;
    _syncEngine.materializedFiles.upsert(
      MaterializedFile(
        nodeId: node.id,
        relativePath: relativePath,
        contentVersionId: node.currentVersionId,
        localSize: stat?.size,
        localModifiedAt: stat?.modified,
        contentSha256: existing.contentSha256,
      ),
    );
  }

  String _localFileError(Object error) => error is FileSystemException
      ? 'the local copy could not be moved (${error.osError?.message ?? error.message}). It may be open in another application.'
      : '$error';

  bool _isCurrentDownload(LocalNode snapshot) {
    final current = _syncEngine.nodeCache.getById(snapshot.id);
    return current != null &&
        !current.isDeleted &&
        current.revision == snapshot.revision &&
        current.currentVersionId == snapshot.currentVersionId;
  }

  String _materializedLocation(String relativePath, String targetPath) =>
      _usesAndroidStorage ? 'Selected sync folder/$relativePath' : targetPath;

  Future<bool> _trashIntegrityFailedFile({
    required LocalNode node,
    required String rootPath,
    required String relativePath,
    required MaterializedFile? existing,
  }) async {
    if (!await _syncEngine.trashAfterIntegrityFailure(node)) return false;
    // Anything still at the target path is either this node's own untouched
    // copy or was already moved aside before the download started.
    if (existing != null) {
      await _removeLocalCopy(
        rootPath,
        existing,
        SyncConflictKind.modifiedLocallyDeletedRemotely,
      );
    }
    if (existing == null ||
        !_sameLocalPath(existing.relativePath, relativePath)) {
      await _deleteFile(rootPath, relativePath);
    }
    _syncEngine.materializedFiles.remove(node.id);
    return true;
  }

  Future<void> _pruneUnseen(String rootPath, Set<String> seenNodeIds) async {
    for (final entry in _syncEngine.materializedFiles.listAll()) {
      if (seenNodeIds.contains(entry.nodeId)) continue;
      // Deleted (or no longer reachable) on the server: remove the mirror,
      // but keep a local edit the server never received (UPDATE vs DELETE).
      await _removeLocalCopy(
        rootPath,
        entry,
        SyncConflictKind.modifiedLocallyDeletedRemotely,
      );
      _syncEngine.materializedFiles.remove(entry.nodeId);
      _syncEngine.materializationFailures.remove(entry.nodeId);
    }
    for (final nodeId in _syncEngine.materializationFailures.listNodeIds()) {
      if (!seenNodeIds.contains(nodeId)) {
        _syncEngine.materializationFailures.remove(nodeId);
      }
    }
    for (final entry in _syncEngine.materializedDirectories.listAll()) {
      if (seenNodeIds.contains(entry.nodeId)) continue;
      await _deleteEmptyDirectory(rootPath, entry.relativePath);
      _syncEngine.materializedDirectories.remove(entry.nodeId);
    }
  }

  /// Makes [relativePath] safe to overwrite with [node]'s content. The file
  /// there is left alone (the caller replaces it) when it is [ownRecord]'s
  /// untouched copy; deleted when it is another node's untouched stale copy
  /// that node re-downloads (e.g. two files swapped names remotely); and
  /// otherwise renamed to a conflict copy, so nothing unsynced is lost.
  Future<void> _clearDestination({
    required String rootPath,
    required String relativePath,
    required LocalNode node,
    required MaterializedFile? ownRecord,
    String? knownSha256,
  }) async {
    if (_usesAndroidStorage) return;
    final file = File('$rootPath/$relativePath');
    if (!await file.exists()) return;
    final ownCopyHere =
        ownRecord != null &&
        _sameLocalPath(ownRecord.relativePath, relativePath);
    if (ownCopyHere &&
        await localCopyMatchesRecord(
          ownRecord,
          file,
          knownSha256: knownSha256,
        )) {
      return;
    }
    if (!ownCopyHere) {
      final occupant = _syncEngine.materializedFiles.getByRelativePath(
        relativePath,
        excludingNodeId: node.id,
      );
      if (occupant != null &&
          await localCopyMatchesRecord(
            occupant,
            file,
            knownSha256: knownSha256,
          )) {
        await file.delete();
        return;
      }
    }
    await preserveAsConflictCopy(
      rootPath: rootPath,
      relativePath: relativePath,
      conflicts: _syncEngine.conflicts,
      kind: ownCopyHere
          ? SyncConflictKind.bothModified
          : SyncConflictKind.bothCreated,
      deviceName: _deviceName,
      nodeId: node.id,
    );
  }

  /// Removes [record]'s local copy, unless it holds an edit this device has
  /// not uploaded yet: that copy is renamed to a conflict copy (recorded as
  /// [kindIfEdited]) and later uploaded as a separate node instead.
  Future<void> _removeLocalCopy(
    String rootPath,
    MaterializedFile record,
    SyncConflictKind kindIfEdited,
  ) async {
    // Another node was already relocated onto this path in the current pass:
    // the bytes there are its copy now, not [record]'s.
    if (!_ownsLocalPath(record)) return;
    if (_usesAndroidStorage) {
      await _deleteFile(rootPath, record.relativePath);
      return;
    }
    final file = File('$rootPath/${record.relativePath}');
    if (!await file.exists()) return;
    if (await localCopyMatchesRecord(record, file)) {
      await file.delete();
      return;
    }
    await preserveAsConflictCopy(
      rootPath: rootPath,
      relativePath: record.relativePath,
      conflicts: _syncEngine.conflicts,
      kind: kindIfEdited,
      deviceName: _deviceName,
      nodeId: record.nodeId,
    );
  }

  /// Whether two sync-folder-relative paths name the same local file. The
  /// Windows and macOS default file systems ignore case, so a case-only
  /// rename there must never look like a different file being in the way.
  bool _sameLocalPath(String a, String b) =>
      a == b ||
      ((Platform.isWindows || Platform.isMacOS) &&
          a.toLowerCase() == b.toLowerCase());

  /// False when another node's record already claims [record]'s path.
  bool _ownsLocalPath(MaterializedFile record) =>
      _syncEngine.materializedFiles.getByRelativePath(
        record.relativePath,
        excludingNodeId: record.nodeId,
      ) ==
      null;

  bool get _usesAndroidStorage =>
      defaultTargetPlatform == TargetPlatform.android &&
      _androidSyncFolder != null;

  Future<void> _createDirectory(String rootPath, String relativePath) {
    final android = _androidSyncFolder;
    if (_usesAndroidStorage && android != null) {
      return android.createDirectory(
        treeUri: rootPath,
        relativePath: relativePath,
      );
    }
    return Directory('$rootPath/$relativePath').create(recursive: true);
  }

  /// The stat recorded alongside a materialized file so the uploader can skip
  /// re-hashing it. Android SAF documents are never scanned, so none there.
  Future<FileStat?> _localStat(String targetPath) async {
    if (_usesAndroidStorage) return null;
    final stat = await File(targetPath).stat();
    return stat.type == FileSystemEntityType.notFound ? null : stat;
  }

  Future<bool> _fileExists(String rootPath, String relativePath) {
    final android = _androidSyncFolder;
    if (_usesAndroidStorage && android != null) {
      return android.fileExists(treeUri: rootPath, relativePath: relativePath);
    }
    return File('$rootPath/$relativePath').exists();
  }

  Future<void> _writeFile(
    String rootPath,
    String relativePath,
    String targetPath,
    File source,
  ) async {
    final android = _androidSyncFolder;
    if (_usesAndroidStorage && android != null) {
      await android.writeFile(
        treeUri: rootPath,
        relativePath: relativePath,
        sourcePath: source.path,
      );
      return;
    }
    await Directory(File(targetPath).parent.path).create(recursive: true);
    final tempPath = '$targetPath.homebox-tmp';
    await source.copy(tempPath);
    await File(tempPath).rename(targetPath); // Atomic on the same volume.
  }

  Future<void> _deleteFile(String rootPath, String relativePath) async {
    final android = _androidSyncFolder;
    if (_usesAndroidStorage && android != null) {
      await android.deleteFile(treeUri: rootPath, relativePath: relativePath);
      return;
    }
    final file = File('$rootPath/$relativePath');
    if (await file.exists()) await file.delete();
  }

  /// A remote delete must not recursively erase unsynced local files. Remove
  /// only an empty folder; any remaining content is preserved for upload.
  Future<void> _deleteEmptyDirectory(
    String rootPath,
    String relativePath,
  ) async {
    if (_usesAndroidStorage) return;
    final directory = Directory('$rootPath/$relativePath');
    if (!await directory.exists()) return;
    if (await directory.list().isEmpty) await directory.delete();
  }

  Future<SensitiveNodeMetadata> _decryptMetadata(
    LocalNode node,
    OwnerKeyRing keys,
  ) => decryptNodeMetadata(
    keys: keys,
    ciphertext: node.metadataCiphertext,
    scopeId: node.scopeOrOwner(keys.userId),
    isDirectory: node.isDirectory,
    nodeId: node.id,
    cipher: _metadataCipher,
  );

  void _setStatus(SyncFolderStatus status) {
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

final class _MaterializationCancelled implements Exception {
  const _MaterializationCancelled();
}
