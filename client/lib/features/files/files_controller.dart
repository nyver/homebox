// Constructor parameters are named to give callers readable arguments
// (`serverConnection:`, `vaultKeyStore:`, `syncEngine:`) instead of the
// backing private field names (matches ServerConnectionController/SyncEngine).
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/file_cipher.dart' show homeBoxChunkMacLength;
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/portable_name.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/local_path.dart';
import '../server/server_connection_controller.dart';
import '../sync/outbox_conflict_resolver.dart'
    show baseMetadataPayloadKey, baseParentIdPayloadKey;
import '../sync/sync_engine.dart';
import 'file_transfer.dart';
import '../../core/util/user_facing_error.dart';

enum FilesStatus { idle, loading, ready, failed }

/// Which direction [FilesController.progress] currently reports, so the
/// Files page can label a busy transfer accurately instead of always
/// saying "upload" even while a download is in progress.
enum FileTransferDirection { upload, download }

enum FileListSort { name, extension, updatedAt }

/// The picker and desktop file APIs only provide a path, so preserve the
/// common image formats in encrypted metadata ourselves. The filename
/// fallback also lets previews work for files uploaded before MIME metadata
/// was introduced.
String? _imageMimeTypeFromFileName(String fileName) {
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex <= 0 || dotIndex == fileName.length - 1) return null;
  return switch (fileName.substring(dotIndex + 1).toLowerCase()) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    _ => null,
  };
}

/// A decrypted-for-display file or folder entry. The server only ever knows
/// [node]'s opaque ID and ciphertext; [metadata] is decrypted locally.
final class FileEntry {
  const FileEntry({required this.node, required this.metadata});

  final LocalNode node;
  final SensitiveNodeMetadata metadata;

  bool get isDirectory => node.isDirectory;
  String get name => metadata.fileName;

  /// True for a conflict copy (spec §21) the user has not marked resolved.
  bool get isConflictCopy => metadata.conflictDetails != null;
}

/// A soft-deleted file or folder that can still be restored from Trash.
final class TrashEntry {
  const TrashEntry({required this.entry, required this.location});

  final FileEntry entry;

  /// The readable path of the folder it was deleted from; empty for the root.
  final String location;
}

/// One stored version of a file, as listed by [FilesController.fileVersions].
final class FileVersionEntry {
  const FileVersionEntry({
    required this.id,
    required this.isCurrent,
    this.createdAt,
    this.plaintextSize,
  });

  final String id;
  final bool isCurrent;
  final DateTime? createdAt;

  /// Derived from the ciphertext size: every chunk adds one AEAD tag.
  final int? plaintextSize;
}

/// The outcome of one user-initiated batch of file uploads.
final class FileUploadBatchResult {
  const FileUploadBatchResult({
    required this.succeeded,
    required this.failed,
    this.successfulPaths = const [],
  });

  final int succeeded;
  final int failed;
  final List<String> successfulPaths;
  int get total => succeeded + failed;
}

final class _Breadcrumb {
  const _Breadcrumb(this.id, this.name);
  final String id;
  final String name;
}

final class _UploadContext {
  const _UploadContext({
    required this.api,
    required this.accessToken,
    required this.vaultKey,
    required this.vaultId,
    required this.userId,
  });
  final transport.HomeBoxApiClient api;
  final String accessToken;
  final SecretKey vaultKey;
  final Uint8List vaultId;
  final String userId;
}

/// Drives the Files browser. Folder create/rename/delete go through
/// [SyncEngine]'s local cache + outbox (so they work offline and survive a
/// restart); file upload/download stay direct, synchronous, online-only
/// calls, since transferring the actual bytes needs connectivity anyway —
/// see SyncEngine's doc comment for why splitting "create the node" from
/// "upload its content" into two independently-queued steps wouldn't add
/// real offline value here.
///
/// Scoped to this account's one personal vault (`vaultId == userId`, key
/// version 1); Folder-specific keys, sharing, and rotation are later
/// milestones (§28, §10.11).
final class FilesController extends ChangeNotifier {
  // Named `serverConnection`/`vaultKeyStore`/`syncEngine` rather than
  // initializing formals so callers get readable named arguments instead of
  // the backing private field names (matches ServerConnectionController).
  ///
  /// [thumbnailer] shrinks a decoded preview before it is cached, so the
  /// cache holds small thumbnails instead of full-size photos.
  /// [localSyncFolderRoot] returns the selected sync folder as a filesystem
  /// path (Windows); a preview of a file already mirrored there and
  /// unchanged since is then read from disk instead of the network.
  FilesController({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required SyncEngine syncEngine,
    Future<Uint8List> Function(Uint8List image)? thumbnailer,
    String? Function()? localSyncFolderRoot,
  }) : _serverConnection = serverConnection,
       _vaultKeyStore = vaultKeyStore,
       _syncEngine = syncEngine,
       _thumbnailer = thumbnailer,
       _localSyncFolderRoot = localSyncFolderRoot {
    _syncEngine.addListener(_onSyncEngineChanged);
  }

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;
  final Future<Uint8List> Function(Uint8List image)? _thumbnailer;
  final String? Function()? _localSyncFolderRoot;
  final MetadataCipher _metadataCipher = MetadataCipher();
  static const int _maxImagePreviewSourceSize = 12 * 1024 * 1024;
  static const int _imagePreviewCacheBudgetBytes = 64 * 1024 * 1024;
  static const int _maxCachedImagePreviews = 256;
  static const int _maxConcurrentImagePreviews = 2;
  // Insertion order doubles as LRU order: a cache hit is re-inserted at the
  // end, and eviction removes from the front. Failed previews are not cached:
  // a row asks again only when it is built anew, so a transient network
  // error heals on the next visit without ever looping.
  final Map<String, Uint8List> _imagePreviewCache = {};
  int _imagePreviewCacheBytes = 0;
  final Map<String, _ImagePreviewLoad> _imagePreviewLoads = {};
  final Queue<_ImagePreviewLoad> _queuedImagePreviews = Queue();
  int _activeImagePreviewLoads = 0;

  FilesStatus _status = FilesStatus.idle;
  String? _errorMessage;
  List<FileEntry> _entries = const [];
  DateTime? _entriesAsOf;
  final List<_Breadcrumb> _path = [];
  bool _busy = false;
  double? _progress;
  FileTransferDirection? _transferDirection;
  // Transfers run one at a time to bound memory and bandwidth, but a new
  // request waits its turn instead of being rejected.
  Future<void> _transferTail = Future<void>.value();
  int _queuedTransfers = 0;
  FileListSort _sort = FileListSort.name;
  bool _disposed = false;

  FilesStatus get status => _status;
  String? get errorMessage => _errorMessage;
  List<FileEntry> get entries => _entries;

  /// When [entries] was last (re)loaded — the folder was opened, or new
  /// files/folders appeared in it. "Updated x ago" labels are computed
  /// relative to this fixed instant rather than the current wall clock, so
  /// they don't silently tick forward while the list is otherwise unchanged
  /// (e.g. on every upload/download progress notification).
  DateTime get entriesAsOf => _entriesAsOf ?? DateTime.now().toUtc();
  bool get busy => _busy;

  /// Transfers waiting for the current one to finish.
  int get queuedTransfers => _queuedTransfers;
  double? get progress => _progress;
  FileTransferDirection? get transferDirection => _transferDirection;
  FileListSort get sort => _sort;
  bool get canGoUp => _path.isNotEmpty;
  List<String> get breadcrumbNames =>
      _path.map((e) => e.name).toList(growable: false);

  /// The selected local sync folder has already received this file when a
  /// materialization record exists. Android uses this to open that local
  /// document directly instead of downloading a second copy on every tap.
  String? materializedRelativePath(String nodeId) =>
      _syncEngine.materializedFiles.getById(nodeId)?.relativePath;

  /// The already-decrypted preview for [entry], if one is cached. Lets a list
  /// row paint its thumbnail in the very first frame instead of flashing the
  /// file icon while an already-completed future resolves.
  Uint8List? cachedImagePreview(FileEntry entry) {
    if (!canShowImagePreview(entry)) return null;
    final key = _imagePreviewKey(entry);
    final bytes = _imagePreviewCache.remove(key);
    // Re-insert to mark this entry as most recently used.
    if (bytes != null) _imagePreviewCache[key] = bytes;
    return bytes;
  }

  /// Returns a decrypted image source for a compact list preview. Previews
  /// deliberately use a separate, bounded cache and never claim the primary
  /// transfer state, so rendering a list cannot block an explicit upload or
  /// download. Large images remain a regular file icon to avoid excessive
  /// network and memory use while scrolling.
  ///
  /// Requests beyond the concurrency limit wait in a queue instead of being
  /// rejected. Completing a preview never notifies this controller's
  /// listeners: the requesting row updates itself, so a folder of images
  /// does not rebuild the whole list once per thumbnail. A row that scrolls
  /// away before its download starts should call [releaseImagePreview].
  Future<Uint8List?> imagePreview(FileEntry entry) {
    if (!canShowImagePreview(entry)) {
      return Future<Uint8List?>.value(null);
    }
    final cached = cachedImagePreview(entry);
    if (cached != null) return Future<Uint8List?>.value(cached);
    final key = _imagePreviewKey(entry);
    final pending = _imagePreviewLoads[key];
    if (pending != null) {
      pending.demand++;
      return pending.completer.future;
    }
    final load = _ImagePreviewLoad(key, entry);
    _imagePreviewLoads[key] = load;
    _queuedImagePreviews.add(load);
    _pumpImagePreviews();
    return load.completer.future;
  }

  /// Withdraws one [imagePreview] request that has not completed yet. A
  /// queued download nobody is waiting for any more is dropped (its future
  /// completes with null); one already in flight still finishes and is
  /// cached, since its bytes are already on the way.
  void releaseImagePreview(FileEntry entry) {
    final key = _imagePreviewKey(entry);
    final load = _imagePreviewLoads[key];
    if (load == null || load.started) return;
    if (--load.demand > 0) return;
    _imagePreviewLoads.remove(key);
    _queuedImagePreviews.remove(load);
    load.completer.complete(null);
  }

  String _imagePreviewKey(FileEntry entry) =>
      '${entry.node.id}:${entry.node.currentVersionId}';

  void _pumpImagePreviews() {
    while (!_disposed &&
        _activeImagePreviewLoads < _maxConcurrentImagePreviews &&
        _queuedImagePreviews.isNotEmpty) {
      final load = _queuedImagePreviews.removeFirst()..started = true;
      _activeImagePreviewLoads++;
      unawaited(_runImagePreviewLoad(load));
    }
  }

  Future<void> _runImagePreviewLoad(_ImagePreviewLoad load) async {
    Uint8List? bytes;
    try {
      bytes = await _downloadImagePreview(load.entry);
    } catch (_) {
      // A thumbnail is cosmetic; e.g. a secure-storage error while loading
      // the vault key must still release this queue slot.
    } finally {
      _activeImagePreviewLoads--;
      _imagePreviewLoads.remove(load.key);
    }
    if (!_disposed && bytes != null) _cacheImagePreview(load.key, bytes);
    load.completer.complete(bytes);
    _pumpImagePreviews();
  }

  void _cacheImagePreview(String key, Uint8List bytes) {
    final previous = _imagePreviewCache.remove(key);
    _imagePreviewCacheBytes -= previous?.length ?? 0;
    if (bytes.length > _imagePreviewCacheBudgetBytes) return;
    while (_imagePreviewCache.isNotEmpty &&
        (_imagePreviewCache.length >= _maxCachedImagePreviews ||
            _imagePreviewCacheBytes + bytes.length >
                _imagePreviewCacheBudgetBytes)) {
      final evicted = _imagePreviewCache.remove(_imagePreviewCache.keys.first);
      _imagePreviewCacheBytes -= evicted!.length;
    }
    _imagePreviewCache[key] = bytes;
    _imagePreviewCacheBytes += bytes.length;
  }

  bool canShowImagePreview(FileEntry entry) {
    final mimeType = entry.metadata.mimeType?.toLowerCase();
    final size = entry.metadata.plaintextSize;
    return !entry.isDirectory &&
        (mimeType?.startsWith('image/') == true ||
            _imageMimeTypeFromFileName(entry.name) != null) &&
        size != null &&
        size <= _maxImagePreviewSourceSize &&
        entry.node.currentVersionId != null;
  }

  /// Updates the local display ordering without reloading or decrypting the
  /// current folder again. Directories always remain before regular files.
  void setSort(FileListSort sort) {
    if (_sort == sort) return;
    _sort = sort;
    _entries = List<FileEntry>.of(_entries)..sort(_compareEntries);
    notifyListeners();
  }

  String? get _currentParentId => _path.isEmpty ? null : _path.last.id;

  void _onSyncEngineChanged() {
    // Only refresh once a sync pass actually settles (idle/offline/error),
    // not on its transient "syncing" status too — halves the redundant
    // local-cache re-reads and metadata re-decryption per pass without
    // losing any freshness, since nothing meaningful changes mid-pass.
    if (_syncEngine.status == SyncStatus.syncing) return;
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final ctx = await _requireContext();
    if (ctx == null) {
      _setStatus(FilesStatus.failed);
      return;
    }
    _setStatus(FilesStatus.loading);
    try {
      final nodes = _syncEngine.nodeCache.listChildren(_currentParentId);
      final decrypted = <FileEntry>[];
      for (final node in nodes) {
        try {
          decrypted.add(
            FileEntry(node: node, metadata: await _decryptMetadata(node, ctx)),
          );
        } catch (_) {
          // A node this device cannot decrypt or parse (wrong/missing key
          // version, or malformed metadata) is skipped rather than failing
          // the whole listing. Broad catch: envelope decoding can throw
          // ArgumentError, which does not extend Exception.
        }
      }
      decrypted.sort(_compareEntries);
      _entries = decrypted;
      _entriesAsOf = DateTime.now().toUtc();
      _setStatus(FilesStatus.ready);
    } catch (e) {
      // Broad on purpose: StateError/ArgumentError (thrown by this class's
      // own checks) do not extend Exception, so `on Exception` would miss
      // them and crash instead of surfacing errorMessage.
      _errorMessage = describeError(e);
      _setStatus(FilesStatus.failed);
    }
  }

  void openFolder(FileEntry entry) {
    if (!entry.isDirectory) return;
    _path.add(_Breadcrumb(entry.node.id, entry.name));
    unawaited(refresh());
  }

  void goToBreadcrumb(int index) {
    _path.removeRange(index + 1, _path.length);
    unawaited(refresh());
  }

  void goToRoot() {
    if (_path.isEmpty) return;
    _path.clear();
    unawaited(refresh());
  }

  /// Navigates to the parent of the currently open folder.
  void goUp() {
    if (_path.isEmpty) return;
    _path.removeLast();
    unawaited(refresh());
  }

  /// Creates a folder immediately in the local cache and enqueues its
  /// creation in the durable outbox — this succeeds even offline; a
  /// background [SyncEngine] run pushes it to the server when connectivity
  /// allows (spec §19: local-first, sync opportunistically).
  Future<bool> createFolder(String name) async {
    final ctx = await _requireContext();
    if (ctx == null) return false;
    try {
      final nodeId = generateUuidV4();
      final envelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(fileName: name),
        metadataKey: ctx.vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: MetadataNodeType.directory,
        scopeId: ctx.vaultId,
        nodeId: uuidStringToBytes(nodeId),
      );
      final metadataCiphertext = envelope.encode();
      final now = DateTime.now().toUtc();
      _syncEngine.nodeCache.upsert(
        LocalNode(
          id: nodeId,
          parentId: _currentParentId,
          nodeType: 'DIRECTORY',
          metadataCiphertext: metadataCiphertext,
          metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
          currentVersionId: null,
          revision: 0,
          createdAt: now,
          updatedAt: now,
          pendingCreate: true,
        ),
      );
      _syncEngine.pendingOperations.enqueue(
        PendingOperation(
          id: generateUuidV4(),
          operationId: generateUuidV4(),
          type: PendingOperationType.createNode,
          nodeId: nodeId,
          payload: {
            'parentId': _currentParentId,
            'nodeType': 'DIRECTORY',
            'metadataCiphertext': base64Encode(metadataCiphertext),
            'metadataKeyVersion': homeBoxPersonalVaultKeyVersion,
          },
          createdAt: now,
          retryCount: 0,
          status: PendingOperationStatus.pending,
        ),
      );
      unawaited(_syncEngine.runOnce());
      await refresh();
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  }

  /// Renames or moves an existing node the same local-first way as
  /// [createFolder]. [newParentId] of `null` with [move] true means "move
  /// to root"; omit [move] (default false) for a pure rename.
  Future<bool> renameNode(
    FileEntry entry,
    String newName, {
    bool move = false,
    String? newParentId,
  }) async {
    final ctx = await _requireContext();
    if (ctx == null) return false;
    try {
      final envelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: newName,
          mimeType: entry.metadata.mimeType,
          plaintextSha256: entry.metadata.plaintextSha256,
          plaintextSize: entry.metadata.plaintextSize,
          conflictDetails: entry.metadata.conflictDetails,
          labels: entry.metadata.labels,
        ),
        metadataKey: ctx.vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: entry.isDirectory
            ? MetadataNodeType.directory
            : MetadataNodeType.file,
        scopeId: ctx.vaultId,
        nodeId: uuidStringToBytes(entry.node.id),
      );
      final metadataCiphertext = envelope.encode();
      final targetParentId = move ? newParentId : entry.node.parentId;
      _syncEngine.nodeCache.upsert(
        LocalNode(
          id: entry.node.id,
          parentId: targetParentId,
          nodeType: entry.node.nodeType,
          metadataCiphertext: metadataCiphertext,
          metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
          currentVersionId: entry.node.currentVersionId,
          revision: entry.node.revision,
          createdAt: entry.node.createdAt,
          updatedAt: DateTime.now().toUtc(),
          pendingCreate: entry.node.pendingCreate,
        ),
      );
      _enqueueUpdate(
        entry.node,
        baseRevision: entry.node.revision,
        metadataCiphertext: metadataCiphertext,
        moveParent: move,
        parentId: targetParentId,
      );
      unawaited(_syncEngine.runOnce());
      await refresh();
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  }

  /// Clears the conflict-copy marker of [entry] once the user has reviewed
  /// it, through the same local-first outbox as a rename. Only the encrypted
  /// metadata changes; the content and its version history stay as they are.
  Future<bool> markConflictResolved(FileEntry entry) async {
    if (!entry.isConflictCopy) return true;
    final ctx = await _requireContext();
    if (ctx == null) return false;
    try {
      final envelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: entry.metadata.fileName,
          mimeType: entry.metadata.mimeType,
          plaintextSha256: entry.metadata.plaintextSha256,
          plaintextSize: entry.metadata.plaintextSize,
          labels: entry.metadata.labels,
        ),
        metadataKey: ctx.vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: entry.isDirectory
            ? MetadataNodeType.directory
            : MetadataNodeType.file,
        scopeId: ctx.vaultId,
        nodeId: uuidStringToBytes(entry.node.id),
      );
      final metadataCiphertext = envelope.encode();
      _syncEngine.nodeCache.upsert(
        LocalNode(
          id: entry.node.id,
          parentId: entry.node.parentId,
          nodeType: entry.node.nodeType,
          metadataCiphertext: metadataCiphertext,
          metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
          currentVersionId: entry.node.currentVersionId,
          revision: entry.node.revision,
          createdAt: entry.node.createdAt,
          updatedAt: DateTime.now().toUtc(),
          pendingCreate: entry.node.pendingCreate,
        ),
      );
      _enqueueUpdate(
        entry.node,
        baseRevision: entry.node.revision,
        metadataCiphertext: metadataCiphertext,
        parentId: entry.node.parentId,
      );
      unawaited(_syncEngine.runOnce());
      await refresh();
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  }

  /// Soft-deletes [entry] (spec §27.2): marked deleted locally right away,
  /// with the actual server call queued the same as any other mutation.
  Future<bool> deleteNode(FileEntry entry) async {
    final ctx = await _requireContext();
    if (ctx == null) return false;
    try {
      final now = DateTime.now().toUtc();
      _syncEngine.nodeCache.upsert(
        LocalNode(
          id: entry.node.id,
          parentId: entry.node.parentId,
          nodeType: entry.node.nodeType,
          metadataCiphertext: entry.node.metadataCiphertext,
          metadataKeyVersion: entry.node.metadataKeyVersion,
          currentVersionId: entry.node.currentVersionId,
          revision: entry.node.revision,
          createdAt: entry.node.createdAt,
          updatedAt: now,
          deletedAt: now,
          pendingCreate: entry.node.pendingCreate,
        ),
      );
      _syncEngine.pendingOperations.enqueue(
        PendingOperation(
          id: generateUuidV4(),
          operationId: generateUuidV4(),
          type: PendingOperationType.deleteNode,
          nodeId: entry.node.id,
          payload: const {},
          baseRevision: entry.node.revision,
          createdAt: now,
          retryCount: 0,
          status: PendingOperationStatus.pending,
        ),
      );
      unawaited(_syncEngine.runOnce());
      await refresh();
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  }

  void _enqueueUpdate(
    LocalNode node, {
    required int baseRevision,
    Uint8List? metadataCiphertext,
    bool moveParent = false,
    String? parentId,
  }) {
    _syncEngine.pendingOperations.enqueue(
      PendingOperation(
        id: generateUuidV4(),
        operationId: generateUuidV4(),
        type: PendingOperationType.updateNode,
        nodeId: node.id,
        payload: {
          if (metadataCiphertext != null)
            'metadataCiphertext': base64Encode(metadataCiphertext),
          if (metadataCiphertext != null)
            'metadataKeyVersion': homeBoxPersonalVaultKeyVersion,
          'moveParent': moveParent,
          'parentId': parentId,
          // The node as this change saw it, so a revision conflict can be
          // rebased onto the server's newer state (spec §21) instead of
          // being dropped or overwriting a concurrent change.
          baseParentIdPayloadKey: node.parentId,
          baseMetadataPayloadKey: base64Encode(node.metadataCiphertext),
        },
        baseRevision: baseRevision,
        createdAt: DateTime.now().toUtc(),
        retryCount: 0,
        status: PendingOperationStatus.pending,
      ),
    );
  }

  /// Encrypts and uploads a local file (spec §22): a new opaque node, a
  /// fresh random File DEK wrapped by the vault key, 4 MiB AEAD chunks, and
  /// a resumable-upload session driven to completion. Returns false and
  /// sets [errorMessage] on failure — a partial upload is never left
  /// referenced by the node (the server-side upload session simply expires
  /// unfinished). Unlike folder/rename/delete, this requires connectivity
  /// up front rather than queuing — see the class doc comment.
  Future<bool> uploadFile(String localPath) async {
    final result = await uploadFiles([localPath]);
    return result.succeeded == 1;
  }

  /// Encrypts and uploads [localPaths] sequentially into the folder that was
  /// open when this call started. Sequential uploads keep memory and network
  /// use bounded, and a failure for one dropped file does not discard the
  /// others.
  Future<FileUploadBatchResult> uploadFiles(List<String> localPaths) async {
    final uniquePaths = <String>[];
    final seen = <String>{};
    for (final path in localPaths) {
      if (path.isNotEmpty && seen.add(path)) uniquePaths.add(path);
    }
    if (uniquePaths.isEmpty) {
      return const FileUploadBatchResult(succeeded: 0, failed: 0);
    }
    // Capture this before waiting in the queue. A user may navigate while
    // earlier transfers or a large drop are uploading, but that must not
    // move these files elsewhere.
    final targetParentId = _currentParentId;
    return _runTransfer(FileTransferDirection.upload, () async {
      _errorMessage = null;
      return _uploadBatch(uniquePaths, targetParentId);
    });
  }

  Future<FileUploadBatchResult> _uploadBatch(
    List<String> uniquePaths,
    String? targetParentId,
  ) async {
    var succeeded = 0;
    var failed = 0;
    final successfulPaths = <String>[];
    final ctx = await _requireContext();
    if (ctx == null) {
      return FileUploadBatchResult(succeeded: 0, failed: uniquePaths.length);
    }
    for (var index = 0; index < uniquePaths.length; index++) {
      try {
        await _uploadFileToParent(
          localPath: uniquePaths[index],
          ctx: ctx,
          parentId: targetParentId,
          onProgress: (progress) =>
              _setProgress((index + progress) / uniquePaths.length),
        );
        succeeded++;
        successfulPaths.add(uniquePaths[index]);
      } catch (e) {
        // Continue so a single unreadable or oversized dropped file does
        // not prevent the rest of the selection from being backed up.
        failed++;
        _errorMessage = describeError(e);
        notifyListeners();
      }
    }
    await refresh();
    return FileUploadBatchResult(
      succeeded: succeeded,
      failed: failed,
      successfulPaths: List.unmodifiable(successfulPaths),
    );
  }

  /// Runs [body] as the next file transfer, after every transfer requested
  /// before it has finished. The busy flag and progress belong to whichever
  /// transfer is running; [queuedTransfers] counts the ones still waiting.
  Future<T> _runTransfer<T>(
    FileTransferDirection direction,
    Future<T> Function() body,
  ) async {
    final previous = _transferTail;
    final done = Completer<void>();
    _transferTail = done.future;
    _queuedTransfers++;
    if (!_disposed) notifyListeners();
    try {
      await previous;
    } finally {
      _queuedTransfers--;
    }
    _setBusy(true, direction: direction);
    try {
      return await body();
    } finally {
      _setBusy(false);
      done.complete();
    }
  }

  Future<void> _uploadFileToParent({
    required String localPath,
    required _UploadContext ctx,
    required String? parentId,
    required void Function(double progress) onProgress,
  }) async {
    final file = File(localPath);
    if (!await file.exists()) {
      throw const FormatException(
        'The selected item is no longer a readable file.',
      );
    }
    final plaintextLength = await file.length();
    if (plaintextLength > homeBoxMaxPlaintextFileSize) {
      throw const FormatException('HomeBox files are limited to 500 MiB.');
    }
    final fileName = basenameOfLocalPath(localPath);
    final plaintextHash = await plaintextFileSha256(file);

    final nodeId = generateUuidV4();
    final nodeIdBytes = uuidStringToBytes(nodeId);
    final metadataEnvelope = await _metadataCipher.encrypt(
      metadata: SensitiveNodeMetadata(
        fileName: fileName,
        mimeType: _imageMimeTypeFromFileName(fileName),
        plaintextSha256: plaintextHash,
        plaintextSize: plaintextLength,
      ),
      metadataKey: ctx.vaultKey,
      keyVersion: homeBoxPersonalVaultKeyVersion,
      nodeType: MetadataNodeType.file,
      scopeId: ctx.vaultId,
      nodeId: nodeIdBytes,
    );
    final metadataCiphertext = metadataEnvelope.encode();
    final createdNode = await ctx.api.createNode(
      ctx.accessToken,
      id: nodeId,
      operationId: generateUuidV4(),
      parentId: parentId,
      nodeType: 'FILE',
      metadataCiphertext: metadataCiphertext,
      metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
    );
    _upsertFromServer(createdNode);

    final updatedNode = await uploadFilePathVersion(
      api: ctx.api,
      accessToken: ctx.accessToken,
      vaultKey: ctx.vaultKey,
      vaultId: ctx.vaultId,
      keyScopeId: ctx.userId,
      targetNodeId: nodeId,
      expectedRevision: createdNode.revision,
      file: file,
      plaintextLength: plaintextLength,
      expectedPlaintextSha256: plaintextHash,
      metadataCiphertext: metadataCiphertext,
      onProgress: onProgress,
    );
    _upsertFromServer(updatedNode);
  }

  /// Uploads [localPath] as a new version of an already-existing file
  /// [entry] (spec §22, versioned): unlike [uploadFile], no new node is
  /// created — the current version and revision are simply advanced, and
  /// every earlier version remains retrievable through the node's version
  /// history. Fails with a clear error (surfaced via [errorMessage]) if the
  /// node was concurrently modified elsewhere (`REVISION_CONFLICT`), rather
  /// than silently overwriting someone else's change.
  ///
  /// Upload completion publishes both the new version and this encrypted
  /// metadata in one server transaction. A concurrent mutation therefore
  /// fails before either value changes instead of leaving mismatched content
  /// and integrity metadata.
  Future<bool> replaceFileContent(FileEntry entry, String localPath) async {
    if (entry.isDirectory) return false;
    return _runTransfer(
      FileTransferDirection.upload,
      () => _replaceFileContent(entry, localPath),
    );
  }

  Future<bool> _replaceFileContent(
    FileEntry entry,
    String localPath, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final ctx = await _requireContext();
      if (ctx == null) return false;
      final file = File(localPath);
      final plaintextLength = await file.length();
      if (plaintextLength > homeBoxMaxPlaintextFileSize) {
        throw const FormatException('HomeBox files are limited to 500 MiB.');
      }
      final plaintextHash = await plaintextFileSha256(file);
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: entry.name,
          mimeType:
              entry.metadata.mimeType ?? _imageMimeTypeFromFileName(entry.name),
          plaintextSha256: plaintextHash,
          plaintextSize: plaintextLength,
        ),
        metadataKey: ctx.vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: MetadataNodeType.file,
        scopeId: ctx.vaultId,
        nodeId: uuidStringToBytes(entry.node.id),
      );
      final metadataCiphertext = metadataEnvelope.encode();

      final uploadedNode = await uploadFilePathVersion(
        api: ctx.api,
        accessToken: ctx.accessToken,
        vaultKey: ctx.vaultKey,
        vaultId: ctx.vaultId,
        keyScopeId: ctx.userId,
        targetNodeId: entry.node.id,
        expectedRevision: entry.node.revision,
        file: file,
        plaintextLength: plaintextLength,
        expectedPlaintextSha256: plaintextHash,
        metadataCiphertext: metadataCiphertext,
        onProgress: onProgress ?? _setProgress,
      );
      // Completion publishes the new version and encrypted metadata in one
      // server transaction, so the content can never retain the old hash.
      _upsertFromServer(uploadedNode);

      await refresh();
      return true;
    } catch (e) {
      // Broad on purpose: StateError/ArgumentError (thrown by this class's
      // own checks) do not extend Exception, so `on Exception` would miss
      // them and crash instead of surfacing errorMessage.
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  }

  /// Downloads, decrypts, and saves [entry] to [destinationPath] (spec
  /// §23): unwraps the File DEK from the newest version's key envelope,
  /// splits the downloaded ciphertext blob back into AEAD frames, decrypts
  /// each (any authentication failure aborts before anything is written),
  /// and verifies the plaintext SHA-256 recorded in the encrypted metadata
  /// before the file is saved.
  Future<bool> downloadFile(FileEntry entry, String destinationPath) =>
      _runTransfer(
        FileTransferDirection.download,
        () => _downloadFile(entry, destinationPath),
      );

  Future<bool> _downloadFile(FileEntry entry, String destinationPath) async {
    try {
      final ctx = await _requireContext();
      if (ctx == null) return false;
      await downloadAndDecryptFileToPath(
        api: ctx.api,
        accessToken: ctx.accessToken,
        vaultKey: ctx.vaultKey,
        vaultId: ctx.vaultId,
        nodeId: entry.node.id,
        expectedVersionId: entry.node.currentVersionId,
        destinationPath: destinationPath,
        expectedPlaintextSha256: entry.metadata.plaintextSha256,
        onProgress: _setProgress,
      );
      return true;
    } catch (e) {
      // Broad on purpose: StateError/ArgumentError (thrown by this class's
      // own checks) do not extend Exception, so `on Exception` would miss
      // them and crash instead of surfacing errorMessage.
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  }

  /// Lists this account's Trash from the local cache, most recently deleted
  /// first, so it also works offline. Like [refresh], an item this device
  /// cannot decrypt is skipped rather than failing the whole list.
  Future<List<TrashEntry>> trashEntries() async {
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return const [];
    }
    final folderNames = <String, String?>{};
    final result = <TrashEntry>[];
    for (final node in _syncEngine.nodeCache.listTrash()) {
      try {
        final metadata = await _decryptMetadata(node, ctx);
        result.add(
          TrashEntry(
            entry: FileEntry(node: node, metadata: metadata),
            location: await _readablePath(node.parentId, ctx, folderNames),
          ),
        );
      } catch (_) {
        // Broad on purpose, as in refresh(): see its comment.
      }
    }
    return result;
  }

  /// Restores [entry] from Trash through the durable outbox, together with
  /// any deleted folders above it, so the item is reachable again. Refuses
  /// when a live item with the same name now occupies one of those places:
  /// two same-named siblings could not both be mirrored to a sync folder.
  Future<bool> restoreFromTrash(FileEntry entry) async {
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return false;
    }
    try {
      final cache = _syncEngine.nodeCache;
      // Collected innermost first and restored outermost first, so each
      // node lands in a parent that is already live again.
      final deletedChain = <LocalNode>[];
      final visited = <String>{};
      LocalNode? node = cache.getById(entry.node.id) ?? entry.node;
      while (node != null && visited.add(node.id)) {
        if (node.isDeleted) deletedChain.add(node);
        final parentId = node.parentId;
        node = parentId == null ? null : cache.getById(parentId);
      }
      final toRestore = deletedChain.reversed.toList(growable: false);
      for (final deleted in toRestore) {
        await _ensureNameIsFree(deleted, ctx);
      }
      final now = DateTime.now().toUtc();
      for (final deleted in toRestore) {
        cache.upsert(
          LocalNode(
            id: deleted.id,
            parentId: deleted.parentId,
            nodeType: deleted.nodeType,
            metadataCiphertext: deleted.metadataCiphertext,
            metadataKeyVersion: deleted.metadataKeyVersion,
            currentVersionId: deleted.currentVersionId,
            revision: deleted.revision,
            createdAt: deleted.createdAt,
            updatedAt: now,
            pendingCreate: deleted.pendingCreate,
          ),
        );
        _syncEngine.pendingOperations.enqueue(
          PendingOperation(
            id: generateUuidV4(),
            operationId: generateUuidV4(),
            type: PendingOperationType.restoreNode,
            nodeId: deleted.id,
            payload: const {},
            createdAt: now,
            retryCount: 0,
            status: PendingOperationStatus.pending,
          ),
        );
      }
      unawaited(_syncEngine.runOnce());
      await refresh();
      return true;
    } catch (e) {
      // Broad on purpose, as in refresh(): see its comment.
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  }

  Future<void> _ensureNameIsFree(LocalNode node, _UploadContext ctx) async {
    final name = (await _decryptMetadata(node, ctx)).fileName;
    final key = PortableName.comparisonKey(name);
    for (final sibling in _syncEngine.nodeCache.listChildren(node.parentId)) {
      if (sibling.id == node.id) continue;
      final String siblingName;
      try {
        siblingName = (await _decryptMetadata(sibling, ctx)).fileName;
      } catch (_) {
        continue;
      }
      if (PortableName.comparisonKey(siblingName) == key) {
        throw StateError(
          '"$name" cannot be restored because an item with the same name '
          'already exists there. Rename or move that item first.',
        );
      }
    }
  }

  /// The readable path of [folderId] such as "Documents/Taxes", decrypting
  /// each ancestor's name at most once per [names] cache.
  Future<String> _readablePath(
    String? folderId,
    _UploadContext ctx,
    Map<String, String?> names,
  ) async {
    final segments = <String>[];
    final visited = <String>{};
    var id = folderId;
    while (id != null && visited.add(id)) {
      final node = _syncEngine.nodeCache.getById(id);
      if (node == null) break;
      if (!names.containsKey(id)) {
        try {
          names[id] = (await _decryptMetadata(node, ctx)).fileName;
        } catch (_) {
          names[id] = null;
        }
      }
      segments.add(names[id] ?? '…');
      id = node.parentId;
    }
    return segments.reversed.join('/');
  }

  /// Lists every stored version of [entry], newest first (spec §27.1).
  /// Returns null and sets [errorMessage] when the server cannot be reached.
  Future<List<FileVersionEntry>?> fileVersions(FileEntry entry) async {
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return null;
    }
    try {
      final versions = await ctx.api.listFileVersions(
        ctx.accessToken,
        entry.node.id,
      );
      // The server's node, not the local cache: another device may have
      // replaced the content since the last sync pass.
      final node = await ctx.api.getNode(ctx.accessToken, entry.node.id);
      return [
        for (final version in versions)
          FileVersionEntry(
            id: version.id,
            isCurrent: version.id == node.currentVersionId,
            createdAt: version.createdAt,
            plaintextSize: switch (version.ciphertextSize) {
              null => null,
              final size => math.max(
                0,
                size - version.chunkCount * homeBoxChunkMacLength,
              ),
            },
          ),
      ];
    } catch (e) {
      // Broad on purpose, as in refresh(): see its comment.
      _errorMessage = describeError(e);
      notifyListeners();
      return null;
    }
  }

  /// Decrypts one specific [version] of [entry] to [destinationPath]. Only
  /// the current version has a plaintext hash in the encrypted metadata;
  /// older versions rely on per-chunk AEAD, which binds every chunk to its
  /// version ID, its position, and the total chunk count, so a truncated or
  /// substituted blob still fails to decrypt.
  Future<bool> downloadFileVersion(
    FileEntry entry,
    FileVersionEntry version,
    String destinationPath,
  ) => _runTransfer(FileTransferDirection.download, () async {
    try {
      await _downloadVersionTo(entry, version, destinationPath, _setProgress);
      return true;
    } catch (e) {
      // Broad on purpose, as in refresh(): see its comment.
      _errorMessage = describeError(e);
      notifyListeners();
      return false;
    }
  });

  /// Makes [version] the current content of [entry] again by uploading its
  /// decrypted bytes as a new version (spec §27.1: a restore never rewrites
  /// history), so the version it replaces stays in the history too.
  Future<bool> restoreFileVersion(FileEntry entry, FileVersionEntry version) {
    if (entry.isDirectory || version.isCurrent) return Future.value(false);
    return _runTransfer(FileTransferDirection.upload, () async {
      Directory? workDirectory;
      try {
        workDirectory = await Directory.systemTemp.createTemp(
          'homebox-restore-',
        );
        final restoredPath =
            '${workDirectory.path}${Platform.pathSeparator}${entry.name}';
        try {
          await _downloadVersionTo(
            entry,
            version,
            restoredPath,
            (progress) => _setProgress(progress / 2),
          );
        } catch (e) {
          // Broad on purpose, as in refresh(): see its comment.
          _errorMessage = describeError(e);
          notifyListeners();
          return false;
        }
        // The newest cached node and its own metadata, so a rename synced
        // since the dialog opened is kept instead of reverted by the upload.
        final latest = await _latestEntry(entry);
        return await _replaceFileContent(
          latest,
          restoredPath,
          onProgress: (progress) => _setProgress(0.5 + progress / 2),
        );
      } finally {
        try {
          await workDirectory?.delete(recursive: true);
        } on FileSystemException {
          // The OS clears a leftover temp copy with its temp directory.
        }
      }
    });
  }

  Future<FileEntry> _latestEntry(FileEntry entry) async {
    final latest = _syncEngine.nodeCache.getById(entry.node.id);
    final ctx = await _requireContext();
    if (latest == null || ctx == null) return entry;
    return FileEntry(
      node: latest,
      metadata: await _decryptMetadata(latest, ctx),
    );
  }

  Future<void> _downloadVersionTo(
    FileEntry entry,
    FileVersionEntry version,
    String destinationPath,
    void Function(double progress) onProgress,
  ) async {
    final ctx = await _requireContext();
    if (ctx == null) {
      throw StateError(_errorMessage ?? 'Sign in and unlock the vault first.');
    }
    await downloadAndDecryptFileToPath(
      api: ctx.api,
      accessToken: ctx.accessToken,
      vaultKey: ctx.vaultKey,
      vaultId: ctx.vaultId,
      nodeId: entry.node.id,
      expectedVersionId: version.id,
      destinationPath: destinationPath,
      // The metadata hash describes exactly the version the cached node
      // points at; any other version is authenticated by AEAD alone.
      expectedPlaintextSha256: version.id == entry.node.currentVersionId
          ? entry.metadata.plaintextSha256
          : null,
      onProgress: onProgress,
    );
  }

  Future<Uint8List?> _downloadImagePreview(FileEntry entry) async {
    final source =
        await _readLocalImagePreview(entry) ?? await _fetchImagePreview(entry);
    final thumbnailer = _thumbnailer;
    if (source == null || thumbnailer == null) return source;
    return thumbnailer(source);
  }

  /// The mirrored sync-folder copy of [entry], if it still holds exactly the
  /// current version (the recorded size and modification time match).
  Future<Uint8List?> _readLocalImagePreview(FileEntry entry) async {
    final root = _localSyncFolderRoot?.call();
    final record = _syncEngine.materializedFiles.getById(entry.node.id);
    if (root == null ||
        record == null ||
        record.contentVersionId != entry.node.currentVersionId) {
      return null;
    }
    try {
      final file = File('$root/${record.relativePath}');
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          !record.matchesLocalStat(stat) ||
          stat.size > _maxImagePreviewSourceSize) {
        return null;
      }
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<Uint8List?> _fetchImagePreview(FileEntry entry) async {
    try {
      final api = _serverConnection.api;
      final session = _serverConnection.session;
      final vaultKey = await _vaultKeyStore.loadVaultKey();
      if (api == null || session == null || vaultKey == null) return null;
      return await downloadAndDecryptFile(
        api: api,
        accessToken: session.accessToken,
        vaultKey: vaultKey,
        vaultId: uuidStringToBytes(session.user.id),
        nodeId: entry.node.id,
        expectedVersionId: entry.node.currentVersionId,
        expectedPlaintextSha256: entry.metadata.plaintextSha256,
        // Thumbnails are cosmetic and decoded in memory. Large images remain
        // available through the bounded streaming download path instead.
        maxCiphertextBytes: 25 * 1024 * 1024,
      );
    } catch (_) {
      // A thumbnail is cosmetic. Keep the normal file icon if downloading or
      // decoding it fails, without changing the Files page's error state.
      return null;
    }
  }

  void _upsertFromServer(transport.NodeInfo node) {
    _syncEngine.nodeCache.upsert(localNodeFromServerNode(node));
  }

  Future<SensitiveNodeMetadata> _decryptMetadata(
    LocalNode node,
    _UploadContext ctx,
  ) {
    final envelope = EncryptedMetadataEnvelope.decode(node.metadataCiphertext);
    return _metadataCipher.decrypt(
      envelope: envelope,
      metadataKey: ctx.vaultKey,
      nodeType: node.isDirectory
          ? MetadataNodeType.directory
          : MetadataNodeType.file,
      scopeId: ctx.vaultId,
      nodeId: uuidStringToBytes(node.id),
    );
  }

  Future<_UploadContext?> _requireContext() async {
    final api = _serverConnection.api;
    // Not _serverConnection.session directly: refreshes first if the
    // access token has expired or is about to, which the background
    // refresh timer alone cannot guarantee on a mobile OS that suspended
    // it while HomeBox was backgrounded (see its doc comment).
    final session = await _serverConnection.ensureFreshSession();
    final vaultKey = await _vaultKeyStore.loadVaultKey();
    if (api == null || session == null || vaultKey == null) {
      _errorMessage =
          'Connect to a server, sign in, and set up the vault first.';
      return null;
    }
    return _UploadContext(
      api: api,
      accessToken: session.accessToken,
      vaultKey: vaultKey,
      vaultId: uuidStringToBytes(session.user.id),
      userId: session.user.id,
    );
  }

  int _compareEntries(FileEntry a, FileEntry b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    // Folder names always use a predictable alphabetical order. Extension
    // and date sorts are useful for files, not for navigating folders.
    if (a.isDirectory) return _compareNames(a, b);
    return switch (_sort) {
      FileListSort.name => _compareNames(a, b),
      FileListSort.extension => _compareExtensions(a, b),
      FileListSort.updatedAt => _compareUpdatedAt(a, b),
    };
  }

  int _compareNames(FileEntry a, FileEntry b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  int _compareExtensions(FileEntry a, FileEntry b) {
    final extensionComparison = _extensionOf(a.name)
        .compareTo(_extensionOf(b.name));
    return extensionComparison == 0 ? _compareNames(a, b) : extensionComparison;
  }

  int _compareUpdatedAt(FileEntry a, FileEntry b) {
    final dateComparison = b.node.updatedAt.compareTo(a.node.updatedAt);
    return dateComparison == 0 ? _compareNames(a, b) : dateComparison;
  }

  String _extensionOf(String name) {
    final index = name.lastIndexOf('.');
    if (index <= 0 || index == name.length - 1) return '';
    return name.substring(index + 1).toLowerCase();
  }

  void _setStatus(FilesStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  void _setBusy(bool value, {FileTransferDirection? direction}) {
    _busy = value;
    _progress = value ? 0 : null;
    _transferDirection = value ? direction : null;
    if (!_disposed) notifyListeners();
  }

  void _setProgress(double value) {
    _progress = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncEngine.removeListener(_onSyncEngineChanged);
    _imagePreviewCache.clear();
    _imagePreviewCacheBytes = 0;
    // In-flight loads complete on their own; queued ones would never start.
    for (final load in _queuedImagePreviews) {
      _imagePreviewLoads.remove(load.key);
      load.completer.complete(null);
    }
    _queuedImagePreviews.clear();
    super.dispose();
  }
}

final class _ImagePreviewLoad {
  _ImagePreviewLoad(this.key, this.entry);

  final String key;
  final FileEntry entry;
  final Completer<Uint8List?> completer = Completer<Uint8List?>();
  int demand = 1;
  bool started = false;
}
