// Constructor parameters are named to give callers readable arguments
// (`serverConnection:`, `vaultKeyStore:`, `syncEngine:`) instead of the
// backing private field names (matches ServerConnectionController/SyncEngine).
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/e2ee/file_cipher.dart' show homeBoxChunkMacLength;
import '../../core/e2ee/key_ring.dart' show ScopedKey;
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/portable_name.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/storage/search_index.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/local_path.dart';
import '../server/server_connection_controller.dart';
import '../sharing/key_scopes.dart';
import '../sync/outbox_conflict_resolver.dart'
    show
        baseMetadataPayloadKey,
        baseMetadataScopePayloadKey,
        baseParentIdPayloadKey,
        metadataScopePayloadKey;
import '../sync/sync_engine.dart';
import 'bulk_download.dart';
import 'file_transfer.dart';
import '../../core/util/user_facing_error.dart';
import '../../core/localization/user_text.dart';

enum FilesStatus { idle, loading, ready, failed }

/// Which direction [FilesController.progress] currently reports, so the
/// Files page can label a busy transfer accurately instead of always
/// saying "upload" even while a download is in progress.
enum FileTransferDirection { upload, download }

/// File order. Each has a natural direction (A→Z, newest first, largest
/// first) that [FilesController.sortReversed] flips.
enum FileListSort { name, extension, updatedAt, size }

/// Where a file's current content is, from this device's point of view.
enum FileSyncState {
  /// A local change to it is still waiting to reach the server.
  pendingUpload,

  /// Its current version is in the local sync folder.
  onThisDevice,

  /// Only on the server; opening it downloads it.
  serverOnly,
}

/// How the Files page lays out the open folder.
enum FileViewMode { list, grid }

enum TransferState { queued, running, succeeded, failed, cancelled }

/// Thrown from a transfer's progress callback once the user cancelled it,
/// which unwinds the upload or download through its normal cleanup.
final class TransferCancelledException implements Exception {
  const TransferCancelledException();

  @override
  String toString() => UserText.of(en: 'Cancelled.', ru: 'Отменено.');
}

/// One upload or download as shown in the Transfers panel.
final class TransferRecord {
  TransferRecord._(this.id, this.label, this.direction);

  /// Increases with every transfer this controller starts.
  final int id;

  /// A file name, or a count such as "3 files" for a batch.
  final String label;
  final FileTransferDirection direction;
  TransferState _state = TransferState.queued;
  String? _error;
  DateTime? _finishedAt;
  bool _cancelRequested = false;

  /// Runs the same transfer again; null when it cannot be repeated (for
  /// example a download into a temporary file for sharing).
  Future<void> Function()? _retry;

  TransferState get state => _state;

  /// Why it failed, when [state] is [TransferState.failed].
  String? get error => _error;
  DateTime? get finishedAt => _finishedAt;
  bool get finished =>
      _state == TransferState.succeeded ||
      _state == TransferState.failed ||
      _state == TransferState.cancelled;

  /// Whether Cancel still applies (queued or running, not yet cancelled).
  bool get cancellable => !finished && !_cancelRequested;

  bool get canRetry =>
      _retry != null &&
      (_state == TransferState.failed || _state == TransferState.cancelled);
}

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

/// A folder offered as a move destination.
final class FolderChoice {
  const FolderChoice({required this.id, required this.name});

  final String id;
  final String name;
}

/// A search hit or favorite, with the readable path of its folder.
final class LocatedEntry {
  const LocatedEntry({required this.entry, required this.location});

  final FileEntry entry;

  /// The readable path of the containing folder; empty for the root.
  final String location;
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

/// One operation's connection and keys. Every caller of
/// [FilesController._requireContext] disposes it when done, so the Vault
/// Key and folder keys it unwrapped are erased.
final class _UploadContext {
  const _UploadContext({
    required this.api,
    required this.accessToken,
    required this.keys,
  });
  final transport.HomeBoxApiClient api;
  final String accessToken;

  /// The Vault Key and every shared-folder key of this account (ADR-023).
  final OwnerKeys keys;

  String get userId => keys.userId;

  /// The newest key of the scope a new child of [parentId] belongs to.
  Future<ScopedKey> keyForNewChild(String? parentId) =>
      keys.forNewChild(parentId);

  /// The newest key of the scope [node] is currently encrypted in; moving
  /// into a shared folder's scope is the shared-scope reconciler's job.
  Future<ScopedKey> keyForExisting(LocalNode node) => keys.forExisting(node);

  void dispose() => keys.dispose();
}

/// Drives the Files browser. Folder create/rename/delete go through
/// [SyncEngine]'s local cache + outbox (so they work offline and survive a
/// restart); file upload/download stay direct, synchronous, online-only
/// calls, since transferring the actual bytes needs connectivity anyway —
/// see SyncEngine's doc comment for why splitting "create the node" from
/// "upload its content" into two independently-queued steps wouldn't add
/// real offline value here.
///
/// Content is encrypted with this account's personal Vault Key, or, below a
/// folder this account shares, with that folder's key (spec §28, ADR-023).
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

  // --- multi-selection (bulk actions on the open folder) ---

  final Set<String> _selectedIds = {};
  bool _selectionMode = false;

  /// The entry a Shift+click range starts from: the last one toggled.
  String? _selectionAnchorId;

  /// True while the Files page shows checkboxes for bulk actions. It can be
  /// on with nothing selected yet, after the user chose "Select".
  bool get selectionMode => _selectionMode;

  /// The selected entries of the open folder, in display order.
  List<FileEntry> get selectedEntries => [
    for (final entry in _entries)
      if (_selectedIds.contains(entry.node.id)) entry,
  ];

  int get selectedCount => _selectedIds.length;

  bool isSelected(FileEntry entry) => _selectedIds.contains(entry.node.id);

  /// Turns selection mode on without selecting anything.
  void startSelection() {
    if (_selectionMode) return;
    _selectionMode = true;
    notifyListeners();
  }

  /// Selects or deselects [entry], turning selection mode on as needed.
  void toggleSelection(FileEntry entry) {
    _selectionMode = true;
    _selectionAnchorId = entry.node.id;
    if (!_selectedIds.remove(entry.node.id)) _selectedIds.add(entry.node.id);
    notifyListeners();
  }

  /// Adds every entry between the last toggled one and [entry] (inclusive)
  /// to the selection, as Shift+click does in desktop file managers. With no
  /// usable anchor this simply selects [entry].
  void extendSelectionTo(FileEntry entry) {
    final target = _entries.indexWhere((e) => e.node.id == entry.node.id);
    if (target < 0) return;
    final anchorId = _selectionAnchorId;
    final anchor = anchorId == null
        ? -1
        : _entries.indexWhere((e) => e.node.id == anchorId);
    _selectionMode = true;
    if (anchor < 0) {
      _selectedIds.add(entry.node.id);
      _selectionAnchorId = entry.node.id;
    } else {
      final (from, to) = anchor <= target ? (anchor, target) : (target, anchor);
      for (var i = from; i <= to; i++) {
        _selectedIds.add(_entries[i].node.id);
      }
    }
    notifyListeners();
  }

  /// Selects every entry of the open folder, or clears the selection when
  /// everything already is selected.
  void toggleSelectAll() {
    _selectionMode = true;
    if (_entries.isNotEmpty && _selectedIds.length == _entries.length) {
      _selectedIds.clear();
    } else {
      _selectedIds
        ..clear()
        ..addAll(_entries.map((entry) => entry.node.id));
    }
    notifyListeners();
  }

  /// Leaves selection mode and forgets the selection.
  void clearSelection() {
    if (!_selectionMode && _selectedIds.isEmpty) return;
    _selectionMode = false;
    _selectedIds.clear();
    _selectionAnchorId = null;
    notifyListeners();
  }

  /// A selection belongs to one folder; navigating away drops it.
  void _resetSelectionForNavigation() {
    _selectionMode = false;
    _selectedIds.clear();
    _selectionAnchorId = null;
  }

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
  /// Choosing another order starts in its natural direction.
  void setSort(FileListSort sort) {
    if (_sort == sort) return;
    _sort = sort;
    _sortReversed = false;
    _entries = List<FileEntry>.of(_entries)..sort(_compareEntries);
    notifyListeners();
  }

  bool _sortReversed = false;

  /// Whether [sort]'s natural direction is flipped (e.g. Z→A, oldest first).
  bool get sortReversed => _sortReversed;

  void toggleSortReversed() {
    _sortReversed = !_sortReversed;
    _entries = List<FileEntry>.of(_entries)..sort(_compareEntries);
    notifyListeners();
  }

  FileViewMode _viewMode = FileViewMode.list;
  FileViewMode get viewMode => _viewMode;

  void setViewMode(FileViewMode mode) {
    if (_viewMode == mode) return;
    _viewMode = mode;
    notifyListeners();
  }

  Set<String> _pendingNodeIds = const {};
  Set<String> _mirroredNodeIds = const {};

  /// Where [entry]'s content currently is; see [FileSyncState]. Without a
  /// local sync folder every synced file is [FileSyncState.serverOnly].
  FileSyncState syncStateOf(FileEntry entry) {
    final id = entry.node.id;
    if (_pendingNodeIds.contains(id)) return FileSyncState.pendingUpload;
    if (_mirroredNodeIds.contains(id)) return FileSyncState.onThisDevice;
    return FileSyncState.serverOnly;
  }

  /// Re-reads which listed files are waiting to upload or mirrored on disk,
  /// without decrypting the folder again. Called after every refresh and
  /// after each local sync-folder pass, which changes the latter.
  void refreshSyncStates() {
    if (_disposed) return;
    final pending = _syncEngine.pendingOperations
        .nodeIdsWithUnfinishedOperations();
    final mirrored = <String>{
      for (final entry in _entries)
        if (!entry.isDirectory &&
            _syncEngine.materializedFiles
                    .getById(entry.node.id)
                    ?.contentVersionId ==
                entry.node.currentVersionId)
          entry.node.id,
    };
    if (setEquals(pending, _pendingNodeIds) &&
        setEquals(mirrored, _mirroredNodeIds)) {
      return;
    }
    _pendingNodeIds = pending;
    _mirroredNodeIds = mirrored;
    if (!_disposed) notifyListeners();
  }

  /// The full decrypted image for the in-app viewer: the mirrored local copy
  /// when it is current, else a bounded download. Null when [entry] is not a
  /// previewable image or cannot be loaded; the caller then opens it with
  /// another app instead.
  Future<Uint8List?> fullImage(FileEntry entry) async {
    if (!canShowImagePreview(entry)) return null;
    return await _readLocalImagePreview(entry) ??
        await _fetchImagePreview(entry);
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
    try {
      _setStatus(FilesStatus.loading);
      try {
        final nodes = _syncEngine.nodeCache.listChildren(_currentParentId);
        final decrypted = <FileEntry>[];
        for (final node in nodes) {
          try {
            decrypted.add(
              FileEntry(
                node: node,
                metadata: await _decryptMetadata(node, ctx),
              ),
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
        _favoriteIds = _syncEngine.favorites.all();
        refreshSyncStates();
        // Drop selected entries that disappeared, e.g. deleted elsewhere.
        _selectedIds.retainAll(decrypted.map((entry) => entry.node.id));
        _entriesAsOf = DateTime.now().toUtc();
        _setStatus(FilesStatus.ready);
      } catch (e) {
        // Broad on purpose: StateError/ArgumentError (thrown by this class's
        // own checks) do not extend Exception, so `on Exception` would miss
        // them and crash instead of surfacing errorMessage.
        _errorMessage = describeError(e);
        _setStatus(FilesStatus.failed);
      }
    } finally {
      ctx.dispose();
    }
  }

  void openFolder(FileEntry entry) {
    if (!entry.isDirectory) return;
    _resetSelectionForNavigation();
    _path.add(_Breadcrumb(entry.node.id, entry.name));
    unawaited(refresh());
  }

  void goToBreadcrumb(int index) {
    _resetSelectionForNavigation();
    _path.removeRange(index + 1, _path.length);
    unawaited(refresh());
  }

  void goToRoot() {
    if (_path.isEmpty) return;
    _resetSelectionForNavigation();
    _path.clear();
    unawaited(refresh());
  }

  /// Navigates to the parent of the currently open folder.
  void goUp() {
    if (_path.isEmpty) return;
    _resetSelectionForNavigation();
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
      try {
        final nodeId = generateUuidV4();
        final key = await ctx.keyForNewChild(_currentParentId);
        final envelope = await _metadataCipher.encrypt(
          metadata: SensitiveNodeMetadata(fileName: name),
          metadataKey: key.key,
          keyVersion: key.version,
          nodeType: MetadataNodeType.directory,
          scopeId: key.scopeIdBytes,
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
            metadataKeyVersion: key.version,
            keyScopeId: key.scopeId,
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
              'metadataKeyVersion': key.version,
              metadataScopePayloadKey: key.scopeId,
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
    } finally {
      ctx.dispose();
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
      try {
        final targetParentId = move ? newParentId : entry.node.parentId;
        if (move) {
          _checkMoveKeepsSharedFoldersApart(entry.node, targetParentId, ctx);
        }
        final key = await ctx.keyForExisting(entry.node);
        final envelope = await _metadataCipher.encrypt(
          metadata: SensitiveNodeMetadata(
            fileName: newName,
            mimeType: entry.metadata.mimeType,
            plaintextSha256: entry.metadata.plaintextSha256,
            plaintextSize: entry.metadata.plaintextSize,
            conflictDetails: entry.metadata.conflictDetails,
            labels: entry.metadata.labels,
          ),
          metadataKey: key.key,
          keyVersion: key.version,
          nodeType: entry.isDirectory
              ? MetadataNodeType.directory
              : MetadataNodeType.file,
          scopeId: key.scopeIdBytes,
          nodeId: uuidStringToBytes(entry.node.id),
        );
        final metadataCiphertext = envelope.encode();
        _syncEngine.nodeCache.upsert(
          entry.node.copyWith(
            parentId: targetParentId,
            clearParent: targetParentId == null,
            metadataCiphertext: metadataCiphertext,
            metadataKeyVersion: key.version,
            keyScopeId: key.scopeId,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        _enqueueUpdate(
          entry.node,
          baseRevision: entry.node.revision,
          metadataCiphertext: metadataCiphertext,
          metadataKey: key,
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
    } finally {
      ctx.dispose();
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
      try {
        final key = await ctx.keyForExisting(entry.node);
        final envelope = await _metadataCipher.encrypt(
          metadata: SensitiveNodeMetadata(
            fileName: entry.metadata.fileName,
            mimeType: entry.metadata.mimeType,
            plaintextSha256: entry.metadata.plaintextSha256,
            plaintextSize: entry.metadata.plaintextSize,
            labels: entry.metadata.labels,
          ),
          metadataKey: key.key,
          keyVersion: key.version,
          nodeType: entry.isDirectory
              ? MetadataNodeType.directory
              : MetadataNodeType.file,
          scopeId: key.scopeIdBytes,
          nodeId: uuidStringToBytes(entry.node.id),
        );
        final metadataCiphertext = envelope.encode();
        _syncEngine.nodeCache.upsert(
          entry.node.copyWith(
            metadataCiphertext: metadataCiphertext,
            metadataKeyVersion: key.version,
            keyScopeId: key.scopeId,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        _enqueueUpdate(
          entry.node,
          baseRevision: entry.node.revision,
          metadataCiphertext: metadataCiphertext,
          metadataKey: key,
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
    } finally {
      ctx.dispose();
    }
  }

  /// Soft-deletes [entry] (spec §27.2): marked deleted locally right away,
  /// with the actual server call queued the same as any other mutation.
  Future<bool> deleteNode(FileEntry entry) async =>
      (await deleteNodes([entry])) == 1;

  /// Moves every entry in [entries] to Trash at once (spec §27.2), the same
  /// local-first way as [deleteNode]: each is hidden immediately and its
  /// delete queued in the durable outbox, so this also works offline and
  /// one sync pass pushes them all. A folder takes its whole subtree along,
  /// so an entry inside another selected folder is not deleted separately;
  /// restoring the folder later brings it back with it.
  ///
  /// Returns how many entries were moved to Trash; on a partial failure
  /// [errorMessage] explains the first problem. The selection is cleared.
  Future<int> deleteNodes(List<FileEntry> entries) async {
    if (entries.isEmpty) return 0;
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return 0;
    }
    ctx.dispose(); // Only the session check is needed; Trash needs no key.
    final selectedIds = {for (final entry in entries) entry.node.id};
    var deleted = 0;
    Object? firstError;
    final now = DateTime.now().toUtc();
    for (final (index, entry) in entries.indexed) {
      if (_hasSelectedAncestor(entry.node, selectedIds)) continue;
      try {
        // The cached node, not the listing's copy: a sync pass may have
        // advanced its revision since the folder was listed.
        final node = _syncEngine.nodeCache.getById(entry.node.id) ?? entry.node;
        if (node.isDeleted) {
          deleted++; // Already in Trash, e.g. from another device.
          continue;
        }
        _syncEngine.nodeCache.upsert(
          node.copyWith(updatedAt: now, deletedAt: now),
        );
        _syncEngine.pendingOperations.enqueue(
          PendingOperation(
            id: generateUuidV4(),
            operationId: generateUuidV4(),
            type: PendingOperationType.deleteNode,
            nodeId: node.id,
            payload: const {},
            baseRevision: node.revision,
            // Strictly increasing, so the outbox keeps the selection order.
            createdAt: now.add(Duration(microseconds: index)),
            retryCount: 0,
            status: PendingOperationStatus.pending,
          ),
        );
        deleted++;
      } catch (e) {
        firstError ??= e;
      }
    }
    _selectionMode = false;
    _selectedIds.clear();
    if (firstError != null) _errorMessage = describeError(firstError);
    if (deleted > 0) unawaited(_syncEngine.runOnce());
    await refresh();
    return deleted;
  }

  /// Whether a folder above [node] is part of the same bulk delete.
  bool _hasSelectedAncestor(LocalNode node, Set<String> selectedIds) {
    final visited = <String>{};
    for (
      var id = node.parentId;
      id != null && visited.add(id);
      id = _syncEngine.nodeCache.getById(id)?.parentId
    ) {
      if (selectedIds.contains(id)) return true;
    }
    return false;
  }

  void _enqueueUpdate(
    LocalNode node, {
    required int baseRevision,
    Uint8List? metadataCiphertext,
    ScopedKey? metadataKey,
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
            'metadataKeyVersion': metadataKey!.version,
          if (metadataCiphertext != null)
            metadataScopePayloadKey: metadataKey!.scopeId,
          'moveParent': moveParent,
          'parentId': parentId,
          // The node as this change saw it, so a revision conflict can be
          // rebased onto the server's newer state (spec §21) instead of
          // being dropped or overwriting a concurrent change.
          baseParentIdPayloadKey: node.parentId,
          baseMetadataPayloadKey: base64Encode(node.metadataCiphertext),
          baseMetadataScopePayloadKey: ?node.keyScopeId,
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
  ///
  /// [fileNames] optionally stores a path under a different name than its
  /// local basename, e.g. "photo (1).jpg" when the user chose to keep both
  /// files on a name clash.
  Future<FileUploadBatchResult> uploadFiles(
    List<String> localPaths, {
    Map<String, String> fileNames = const {},
  }) =>
      // Captured before waiting in the queue. A user may navigate while
      // earlier transfers or a large drop are uploading, but that must not
      // move these files elsewhere.
      _uploadInto(localPaths, _currentParentId, fileNames);

  Future<FileUploadBatchResult> _uploadInto(
    List<String> localPaths,
    String? targetParentId,
    Map<String, String> fileNames,
  ) async {
    final uniquePaths = <String>[];
    final seen = <String>{};
    for (final path in localPaths) {
      if (path.isNotEmpty && seen.add(path)) uniquePaths.add(path);
    }
    if (uniquePaths.isEmpty) {
      return const FileUploadBatchResult(succeeded: 0, failed: 0);
    }
    final first = uniquePaths.first;
    return _runTransfer(
      FileTransferDirection.upload,
      () async {
        _errorMessage = null;
        return _uploadBatch(uniquePaths, targetParentId, fileNames);
      },
      label: uniquePaths.length == 1
          ? fileNames[first] ?? basenameOfLocalPath(first)
          : _countLabel(uniquePaths.length, files: true),
      succeeded: (result) => result.failed == 0,
      whenCancelled: () =>
          FileUploadBatchResult(succeeded: 0, failed: uniquePaths.length),
      // Only what did not make it, into the same folder as before.
      retry: (result) {
        final done = result.successfulPaths.toSet();
        final remaining = [
          for (final path in uniquePaths)
            if (!done.contains(path)) path,
        ];
        return () => _uploadInto(remaining, targetParentId, fileNames);
      },
    );
  }

  Future<FileUploadBatchResult> _uploadBatch(
    List<String> uniquePaths,
    String? targetParentId,
    Map<String, String> fileNames,
  ) async {
    var succeeded = 0;
    var failed = 0;
    final successfulPaths = <String>[];
    final ctx = await _requireContext();
    if (ctx == null) {
      return FileUploadBatchResult(succeeded: 0, failed: uniquePaths.length);
    }
    try {
      for (var index = 0; index < uniquePaths.length; index++) {
        if (_activeTransferCancelled) {
          // The rest of a cancelled batch is not started.
          failed += uniquePaths.length - index;
          _errorMessage = const TransferCancelledException().toString();
          break;
        }
        try {
          await _uploadFileToParent(
            localPath: uniquePaths[index],
            fileName: fileNames[uniquePaths[index]],
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
    } finally {
      ctx.dispose();
    }
  }

  /// How many finished transfers the Transfers panel keeps.
  static const int _maxFinishedTransfers = 50;

  final List<TransferRecord> _transfers = [];
  int _nextTransferId = 1;
  int _transfersSeenUpTo = 0;

  /// Active and recent transfers, newest first.
  List<TransferRecord> get transfers => List.unmodifiable(_transfers.reversed);

  /// Failed transfers the user has not looked at in the Transfers panel
  /// yet, so a failure stays noticeable after its snackbar is gone.
  int get unseenFailedTransfers => _transfers
      .where(
        (record) =>
            record.state == TransferState.failed &&
            record.id > _transfersSeenUpTo,
      )
      .length;

  void markTransfersSeen() {
    if (unseenFailedTransfers == 0) {
      _transfersSeenUpTo = _nextTransferId - 1;
      return;
    }
    _transfersSeenUpTo = _nextTransferId - 1;
    if (!_disposed) notifyListeners();
  }

  void clearFinishedTransfers() {
    _transfers.removeWhere((record) => record.finished);
    if (!_disposed) notifyListeners();
  }

  /// Runs [body] as the next file transfer, after every transfer requested
  /// before it has finished. The busy flag and progress belong to whichever
  /// transfer is running; [queuedTransfers] counts the ones still waiting.
  /// The transfer is recorded under [label]; [succeeded] tells from its
  /// result whether it worked, and a failure keeps [errorMessage].
  Future<T> _runTransfer<T>(
    FileTransferDirection direction,
    Future<T> Function() body, {
    required String label,
    required bool Function(T result) succeeded,
    required T Function() whenCancelled,
    Future<void> Function()? Function(T result)? retry,
  }) async {
    final record = TransferRecord._(_nextTransferId++, label, direction);
    _transfers.add(record);
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
    if (record._cancelRequested) {
      // Cancelled while queued: nothing was started.
      _errorMessage = const TransferCancelledException().toString();
      final result = whenCancelled();
      record._retry = retry?.call(result);
      _finishTransfer(record, TransferState.cancelled);
      if (!_disposed) notifyListeners();
      done.complete();
      return result;
    }
    record._state = TransferState.running;
    _activeTransfer = record;
    _setBusy(true, direction: direction);
    var ok = false;
    try {
      final result = await body();
      ok = succeeded(result);
      if (!ok) record._retry = retry?.call(result);
      return result;
    } finally {
      _activeTransfer = null;
      _finishTransfer(
        record,
        ok
            ? TransferState.succeeded
            : record._cancelRequested
            ? TransferState.cancelled
            : TransferState.failed,
      );
      _setBusy(false);
      done.complete();
    }
  }

  void _finishTransfer(TransferRecord record, TransferState state) {
    record
      .._state = state
      .._error = state == TransferState.failed ? _errorMessage : null
      .._finishedAt = DateTime.now().toUtc();
    _trimFinishedTransfers();
  }

  /// The transfer currently running, whose cancellation [_setProgress]
  /// enforces.
  TransferRecord? _activeTransfer;

  /// Stops [record]: a queued one never starts, a running one stops at its
  /// next progress step (within one 4 MiB chunk) and cleans up after itself.
  void cancelTransfer(TransferRecord record) {
    if (!record.cancellable) return;
    record._cancelRequested = true;
    if (!_disposed) notifyListeners();
  }

  /// Starts [record] again as a new transfer; the old entry is replaced.
  Future<void> retryTransfer(TransferRecord record) async {
    final retry = record._retry;
    if (retry == null || !record.canRetry) return;
    _transfers.remove(record);
    if (!_disposed) notifyListeners();
    await retry();
  }

  bool get _activeTransferCancelled =>
      _activeTransfer?._cancelRequested ?? false;

  void _trimFinishedTransfers() {
    var finished = _transfers.where((record) => record.finished).length;
    for (
      var i = 0;
      i < _transfers.length && finished > _maxFinishedTransfers;
    ) {
      if (_transfers[i].finished) {
        _transfers.removeAt(i);
        finished--;
      } else {
        i++;
      }
    }
  }

  static String _countLabel(int count, {required bool files}) => UserText.of(
    en: files ? '$count files' : '$count items',
    ru: files ? 'Файлов: $count' : 'Элементов: $count',
  );

  Future<void> _uploadFileToParent({
    required String localPath,
    String? fileName,
    required _UploadContext ctx,
    required String? parentId,
    required void Function(double progress) onProgress,
  }) async {
    final file = File(localPath);
    if (!await file.exists()) {
      throw FormatException(
        UserText.of(
          en: 'The selected item is no longer a readable file.',
          ru: 'Выбранный элемент больше не является доступным файлом.',
        ),
      );
    }
    final plaintextLength = await file.length();
    if (plaintextLength > homeBoxMaxPlaintextFileSize) {
      throw FormatException(
        UserText.of(
          en: 'HomeBox files are limited to 500 MiB.',
          ru: 'Размер файла в HomeBox ограничен 500 МиБ.',
        ),
      );
    }
    fileName ??= basenameOfLocalPath(localPath);
    final plaintextHash = await plaintextFileSha256(file);

    final nodeId = generateUuidV4();
    final nodeIdBytes = uuidStringToBytes(nodeId);
    final key = await ctx.keyForNewChild(parentId);
    final metadataEnvelope = await _metadataCipher.encrypt(
      metadata: SensitiveNodeMetadata(
        fileName: fileName,
        mimeType: _imageMimeTypeFromFileName(fileName),
        plaintextSha256: plaintextHash,
        plaintextSize: plaintextLength,
      ),
      metadataKey: key.key,
      keyVersion: key.version,
      nodeType: MetadataNodeType.file,
      scopeId: key.scopeIdBytes,
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
      metadataKeyVersion: key.version,
      metadataKeyScopeId: key.scopeId,
    );
    _upsertFromServer(createdNode);

    final transport.NodeInfo updatedNode;
    try {
      updatedNode = await uploadFilePathVersion(
        api: ctx.api,
        accessToken: ctx.accessToken,
        key: key,
        targetNodeId: nodeId,
        expectedRevision: createdNode.revision,
        file: file,
        plaintextLength: plaintextLength,
        expectedPlaintextSha256: plaintextHash,
        metadataCiphertext: metadataCiphertext,
        onProgress: onProgress,
      );
    } on TransferCancelledException {
      // The user stopped it: remove the node created for it, so no empty
      // file is left behind (in the folder or in Trash).
      await _discardNewNode(ctx, createdNode);
      rethrow;
    }
    _upsertFromServer(updatedNode);
  }

  /// Best-effort removal of a just-created node whose content was never
  /// uploaded. If the server cannot be reached, the empty node stays and
  /// can be deleted by hand like any other item.
  Future<void> _discardNewNode(
    _UploadContext ctx,
    transport.NodeInfo node,
  ) async {
    try {
      await ctx.api.deleteNode(
        ctx.accessToken,
        node.id,
        operationId: generateUuidV4(),
        expectedRevision: node.revision,
      );
      await ctx.api.purgeTrashEntry(ctx.accessToken, node.id);
      _forgetSubtree(node.id);
    } catch (_) {
      // See the doc comment.
    }
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
      label: entry.name,
      succeeded: (ok) => ok,
      whenCancelled: () => false,
      retry: (_) =>
          () => replaceFileContent(entry, localPath),
    );
  }

  Future<bool> _replaceFileContent(
    FileEntry entry,
    String localPath, {
    void Function(double progress)? onProgress,
  }) async {
    _UploadContext? ctx;
    try {
      ctx = await _requireContext();
      if (ctx == null) return false;
      final file = File(localPath);
      final plaintextLength = await file.length();
      if (plaintextLength > homeBoxMaxPlaintextFileSize) {
        throw FormatException(
          UserText.of(
            en: 'HomeBox files are limited to 500 MiB.',
            ru: 'Размер файла в HomeBox ограничен 500 МиБ.',
          ),
        );
      }
      final plaintextHash = await plaintextFileSha256(file);
      final key = await ctx.keyForExisting(entry.node);
      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: entry.name,
          mimeType:
              entry.metadata.mimeType ?? _imageMimeTypeFromFileName(entry.name),
          plaintextSha256: plaintextHash,
          plaintextSize: plaintextLength,
        ),
        metadataKey: key.key,
        keyVersion: key.version,
        nodeType: MetadataNodeType.file,
        scopeId: key.scopeIdBytes,
        nodeId: uuidStringToBytes(entry.node.id),
      );
      final metadataCiphertext = metadataEnvelope.encode();

      final uploadedNode = await uploadFilePathVersion(
        api: ctx.api,
        accessToken: ctx.accessToken,
        key: key,
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
    } finally {
      ctx?.dispose();
    }
  }

  /// Downloads, decrypts, and saves [entry] to [destinationPath] (spec
  /// §23): unwraps the File DEK from the newest version's key envelope,
  /// splits the downloaded ciphertext blob back into AEAD frames, decrypts
  /// each (any authentication failure aborts before anything is written),
  /// and verifies the plaintext SHA-256 recorded in the encrypted metadata
  /// before the file is saved.
  ///
  /// [retryable] is false for a temporary copy handed to another app, which
  /// is pointless to repeat from the Transfers panel.
  Future<bool> downloadFile(
    FileEntry entry,
    String destinationPath, {
    bool retryable = true,
  }) => _runTransfer(
    FileTransferDirection.download,
    () => _downloadFile(entry, destinationPath),
    label: entry.name,
    succeeded: (ok) => ok,
    whenCancelled: () => false,
    retry: retryable
        ? (_) =>
              () => downloadFile(entry, destinationPath)
        : null,
  );

  Future<bool> _downloadFile(FileEntry entry, String destinationPath) async {
    _UploadContext? ctx;
    try {
      ctx = await _requireContext();
      if (ctx == null) return false;
      await downloadAndDecryptFileToPath(
        api: ctx.api,
        accessToken: ctx.accessToken,
        keys: ctx.keys.ring,
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
    } finally {
      ctx?.dispose();
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
    try {
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
    } finally {
      ctx.dispose();
    }
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
        for (final (index, deleted) in toRestore.indexed) {
          cache.upsert(deleted.copyWith(updatedAt: now, clearDeletedAt: true));
          _syncEngine.pendingOperations.enqueue(
            PendingOperation(
              id: generateUuidV4(),
              operationId: generateUuidV4(),
              type: PendingOperationType.restoreNode,
              nodeId: deleted.id,
              payload: const {},
              // What a change queued after this restore (such as deleting
              // the item again before the next sync) is based on, so the
              // outbox rebases it onto the restored revision instead of
              // failing it as a conflict.
              baseRevision: deleted.revision,
              // Strictly increasing, so the outbox pushes the outermost
              // folder's restore first.
              createdAt: now.add(Duration(microseconds: index)),
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
    } finally {
      ctx.dispose();
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
    ctx.dispose(); // Listing versions needs the session only.
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
    String destinationPath, {
    bool retryable = true,
  }) => _runTransfer(
    FileTransferDirection.download,
    () async {
      try {
        await _downloadVersionTo(entry, version, destinationPath, _setProgress);
        return true;
      } catch (e) {
        // Broad on purpose, as in refresh(): see its comment.
        _errorMessage = describeError(e);
        notifyListeners();
        return false;
      }
    },
    label: entry.name,
    succeeded: (ok) => ok,
    whenCancelled: () => false,
    retry: retryable
        ? (_) =>
              () => downloadFileVersion(entry, version, destinationPath)
        : null,
  );

  /// Makes [version] the current content of [entry] again by uploading its
  /// decrypted bytes as a new version (spec §27.1: a restore never rewrites
  /// history), so the version it replaces stays in the history too.
  Future<bool> restoreFileVersion(FileEntry entry, FileVersionEntry version) {
    if (entry.isDirectory || version.isCurrent) return Future.value(false);
    return _runTransfer(
      FileTransferDirection.upload,
      label: entry.name,
      succeeded: (ok) => ok,
      whenCancelled: () => false,
      retry: (_) =>
          () => restoreFileVersion(entry, version),
      () async {
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
      },
    );
  }

  Future<FileEntry> _latestEntry(FileEntry entry) async {
    final latest = _syncEngine.nodeCache.getById(entry.node.id);
    final ctx = await _requireContext();
    if (ctx == null) return entry;
    try {
      if (latest == null) return entry;
      return FileEntry(
        node: latest,
        metadata: await _decryptMetadata(latest, ctx),
      );
    } finally {
      ctx.dispose();
    }
  }

  Future<void> _downloadVersionTo(
    FileEntry entry,
    FileVersionEntry version,
    String destinationPath,
    void Function(double progress) onProgress,
  ) async {
    final ctx = await _requireContext();
    if (ctx == null) {
      throw StateError(
        _errorMessage ??
            UserText.of(
              en: 'Sign in and unlock the vault first.',
              ru: 'Сначала войдите и разблокируйте хранилище.',
            ),
      );
    }
    try {
      await _downloadVersionWith(
        ctx,
        entry,
        version,
        destinationPath,
        onProgress,
      );
    } finally {
      ctx.dispose();
    }
  }

  Future<void> _downloadVersionWith(
    _UploadContext ctx,
    FileEntry entry,
    FileVersionEntry version,
    String destinationPath,
    void Function(double progress) onProgress,
  ) async {
    await downloadAndDecryptFileToPath(
      api: ctx.api,
      accessToken: ctx.accessToken,
      keys: ctx.keys.ring,
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
      if (api == null || session == null) return null;
      final keys = await _openKeys(session.user.id);
      if (keys == null) return null;
      try {
        return await downloadAndDecryptFile(
          api: api,
          accessToken: session.accessToken,
          keys: keys.ring,
          nodeId: entry.node.id,
          expectedVersionId: entry.node.currentVersionId,
          expectedPlaintextSha256: entry.metadata.plaintextSha256,
          // Thumbnails are cosmetic and decoded in memory. Large images remain
          // available through the bounded streaming download path instead.
          maxCiphertextBytes: 25 * 1024 * 1024,
        );
      } finally {
        keys.dispose();
      }
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
  ) => ctx.keys.decrypt(node);

  Future<OwnerKeys?> _openKeys(String userId) => OwnerKeys.open(
    vaultKeyStore: _vaultKeyStore,
    nodeCache: _syncEngine.nodeCache,
    folderKeys: _syncEngine.folderKeys,
    userId: userId,
  );

  /// Refuses a move the server would reject anyway: shared folders never
  /// nest, so one that contains a shared folder cannot go into another.
  void _checkMoveKeepsSharedFoldersApart(
    LocalNode node,
    String? newParentId,
    _UploadContext ctx,
  ) {
    final scopes = ctx.keys.scopes;
    if (newParentId == null ||
        scopes.nearestKeyedFolder(newParentId) == null ||
        !scopes.subtreeHasKeyedFolder(node.id)) {
      return;
    }
    throw StateError(
      UserText.of(
        en: 'A shared folder cannot be moved into another shared folder.',
        ru: 'Общую папку нельзя переместить в другую общую папку.',
      ),
    );
  }

  Future<_UploadContext?> _requireContext() async {
    final api = _serverConnection.api;
    // Not _serverConnection.session directly: refreshes first if the
    // access token has expired or is about to, which the background
    // refresh timer alone cannot guarantee on a mobile OS that suspended
    // it while HomeBox was backgrounded (see its doc comment).
    final session = await _serverConnection.ensureFreshSession();
    final keys = session == null ? null : await _openKeys(session.user.id);
    if (api == null || session == null || keys == null) {
      _errorMessage = UserText.of(
        en: 'Connect to a server, sign in, and set up the vault first.',
        ru: 'Сначала подключитесь к серверу, войдите и настройте хранилище.',
      );
      return null;
    }
    return _UploadContext(
      api: api,
      accessToken: session.accessToken,
      keys: keys,
    );
  }

  // --- favorites (spec §29) ---

  Set<String> _favoriteIds = {};

  bool isFavorite(FileEntry entry) => _favoriteIds.contains(entry.node.id);

  /// Marks or unmarks every entry in [entries] as a favorite. Favorites are
  /// kept on the server so every device shows them; this needs a
  /// connection. Returns how many entries changed.
  Future<int> setFavorite(List<FileEntry> entries, bool favorite) async {
    final api = _serverConnection.api;
    final session = await _serverConnection.ensureFreshSession();
    if (api == null || session == null) {
      _errorMessage = UserText.of(
        en: 'Connect to the server to change favorites.',
        ru: 'Чтобы изменить избранное, подключитесь к серверу.',
      );
      notifyListeners();
      return 0;
    }
    var changed = 0;
    Object? firstError;
    for (final entry in entries) {
      try {
        if (favorite) {
          await api.addFavorite(session.accessToken, entry.node.id);
          _syncEngine.favorites.add(entry.node.id);
        } else {
          await api.removeFavorite(session.accessToken, entry.node.id);
          _syncEngine.favorites.remove(entry.node.id);
        }
        changed++;
      } catch (e) {
        firstError ??= e;
      }
    }
    _favoriteIds = _syncEngine.favorites.all();
    if (firstError != null) _errorMessage = describeError(firstError);
    _resetSelectionForNavigation();
    notifyListeners();
    return changed;
  }

  /// This account's favorites that are still in its tree, sorted by name.
  Future<List<LocatedEntry>> favoriteEntries() async {
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return const [];
    }
    try {
      final names = <String, String?>{};
      final result = <LocatedEntry>[];
      for (final id in _syncEngine.favorites.all()) {
        final located = await _locate(id, ctx, names);
        if (located != null) result.add(located);
      }
      result.sort(
        (a, b) =>
            a.entry.name.toLowerCase().compareTo(b.entry.name.toLowerCase()),
      );
      return result;
    } finally {
      ctx.dispose();
    }
  }

  // --- search (spec §29: client-side, over decrypted names) ---

  final SearchIndex _searchIndex = SearchIndex();
  Future<void> _searchTail = Future<void>.value();

  /// Finds files and folders whose name contains every word of [query].
  /// The index of decrypted names lives in memory only; it is built on the
  /// first search and afterwards only re-reads nodes whose revision changed.
  Future<List<LocatedEntry>> search(String query) {
    final previous = _searchTail;
    final done = Completer<void>();
    _searchTail = done.future;
    return () async {
      try {
        await previous;
        return await _searchNow(query);
      } finally {
        done.complete();
      }
    }();
  }

  Future<List<LocatedEntry>> _searchNow(String query) async {
    if (query.trim().isEmpty || _disposed) return const [];
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return const [];
    }
    try {
      await _updateSearchIndex(ctx);
      final names = <String, String?>{};
      final result = <LocatedEntry>[];
      for (final id in _searchIndex.search(query)) {
        final located = await _locate(id, ctx, names);
        if (located != null) result.add(located);
      }
      return result;
    } finally {
      ctx.dispose();
    }
  }

  Future<void> _updateSearchIndex(_UploadContext ctx) async {
    final indexed = _searchIndex.stamps();
    final live = <String>{};
    final changed = <(String, String, String)>[];
    for (final node in _syncEngine.nodeCache.listLive()) {
      live.add(node.id);
      final stamp = _metadataStamp(node);
      if (indexed[node.id] == stamp) continue;
      try {
        final metadata = await ctx.keys.decrypt(node);
        changed.add((node.id, stamp, metadata.fileName));
      } catch (_) {
        // Not decryptable on this device (yet): leave it out of results.
      }
    }
    if (_disposed) return;
    _searchIndex.batch(() {
      for (final (id, stamp, name) in changed) {
        _searchIndex.put(id, stamp, name);
      }
      for (final id in indexed.keys) {
        if (!live.contains(id)) _searchIndex.remove(id);
      }
    });
  }

  /// Identifies one encryption of [node]'s metadata: the AEAD tag at the
  /// end of the envelope changes whenever the metadata is re-encrypted,
  /// including a local rename the server has not confirmed yet (which keeps
  /// the node's revision).
  static String _metadataStamp(LocalNode node) {
    final bytes = node.metadataCiphertext;
    final tag = bytes.length <= 16 ? bytes : bytes.sublist(bytes.length - 16);
    return base64Encode(tag);
  }

  /// [nodeId] as an entry with its folder's path, or null when it is gone,
  /// in Trash, below a folder in Trash, or cannot be decrypted.
  Future<LocatedEntry?> _locate(
    String nodeId,
    _UploadContext ctx,
    Map<String, String?> names,
  ) async {
    final node = _syncEngine.nodeCache.getById(nodeId);
    if (node == null || node.isDeleted || _isHidden(node)) return null;
    try {
      return LocatedEntry(
        entry: FileEntry(node: node, metadata: await ctx.keys.decrypt(node)),
        location: await _readablePath(node.parentId, ctx, names),
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether a folder above [node] is in Trash or no longer known.
  bool _isHidden(LocalNode node) {
    final visited = <String>{};
    for (var id = node.parentId; id != null && visited.add(id);) {
      final parent = _syncEngine.nodeCache.getById(id);
      if (parent == null || parent.isDeleted) return true;
      id = parent.parentId;
    }
    return false;
  }

  /// Opens [folderId] (the root when null) with its full breadcrumb path,
  /// e.g. to show a search hit or favorite where it lives.
  Future<void> revealFolder(String? folderId) async {
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return;
    }
    final chain = <_Breadcrumb>[];
    try {
      final visited = <String>{};
      for (var id = folderId; id != null && visited.add(id);) {
        final node = _syncEngine.nodeCache.getById(id);
        if (node == null) break;
        chain.add(_Breadcrumb(id, (await ctx.keys.decrypt(node)).fileName));
        id = node.parentId;
      }
    } catch (e) {
      _errorMessage = describeError(e);
      notifyListeners();
      return;
    } finally {
      ctx.dispose();
    }
    _resetSelectionForNavigation();
    _path
      ..clear()
      ..addAll(chain.reversed);
    await refresh();
  }

  /// The folders directly inside [parentId] (the root when null), for
  /// picking a move destination.
  Future<List<FolderChoice>> folderChoices(String? parentId) async {
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return const [];
    }
    try {
      final result = <FolderChoice>[];
      for (final node in _syncEngine.nodeCache.listChildren(parentId)) {
        if (!node.isDirectory) continue;
        try {
          result.add(
            FolderChoice(
              id: node.id,
              name: (await ctx.keys.decrypt(node)).fileName,
            ),
          );
        } catch (_) {
          // Skipped like in the folder listing itself.
        }
      }
      result.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return result;
    } finally {
      ctx.dispose();
    }
  }

  // --- bulk move ---

  /// Moves [entries] into [targetParentId] (the root when null) the same
  /// local-first way as a single move: applied at once and queued in the
  /// durable outbox. An entry that would land inside itself, collide with a
  /// name already in the destination, or put a shared folder inside another
  /// is left where it is, and [errorMessage] says why. Returns how many
  /// entries moved.
  Future<int> moveNodes(List<FileEntry> entries, String? targetParentId) async {
    final ctx = await _requireContext();
    if (ctx == null) {
      notifyListeners();
      return 0;
    }
    var moved = 0;
    String? problem;
    try {
      final taken = <String>{};
      for (final child in _syncEngine.nodeCache.listChildren(targetParentId)) {
        try {
          taken.add(
            PortableName.comparisonKey(
              (await ctx.keys.decrypt(child)).fileName,
            ),
          );
        } catch (_) {
          // An undecryptable sibling cannot be compared; the server and the
          // sync folder still keep both apart by ID.
        }
      }
      for (final entry in entries) {
        final node = _syncEngine.nodeCache.getById(entry.node.id) ?? entry.node;
        if (node.isDeleted || node.parentId == targetParentId) continue;
        if (targetParentId != null &&
            _isSelfOrDescendant(targetParentId, node.id)) {
          problem ??= UserText.of(
            en: '"${entry.name}" cannot be moved into itself.',
            ru: '«${entry.name}» нельзя переместить в само себя.',
          );
          continue;
        }
        final key = PortableName.comparisonKey(entry.name);
        if (taken.contains(key)) {
          problem ??= UserText.of(
            en: '"${entry.name}" already exists in the destination.',
            ru: '«${entry.name}» уже есть в папке назначения.',
          );
          continue;
        }
        try {
          _checkMoveKeepsSharedFoldersApart(node, targetParentId, ctx);
        } catch (e) {
          problem ??= describeError(e);
          continue;
        }
        _syncEngine.nodeCache.upsert(
          node.copyWith(
            parentId: targetParentId,
            clearParent: targetParentId == null,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        _enqueueUpdate(
          node,
          baseRevision: node.revision,
          moveParent: true,
          parentId: targetParentId,
        );
        taken.add(key);
        moved++;
      }
    } finally {
      ctx.dispose();
    }
    _resetSelectionForNavigation();
    if (problem != null) _errorMessage = problem;
    if (moved > 0) unawaited(_syncEngine.runOnce());
    await refresh();
    return moved;
  }

  /// Whether [nodeId] is [ancestorId] or lies below it.
  bool _isSelfOrDescendant(String nodeId, String ancestorId) {
    final visited = <String>{};
    for (String? id = nodeId; id != null && visited.add(id);) {
      if (id == ancestorId) return true;
      id = _syncEngine.nodeCache.getById(id)?.parentId;
    }
    return false;
  }

  // --- bulk download ---

  /// Decrypts [entries], folders with everything inside them, into
  /// [directory] (keeping the folder structure) or, when [zipPath] is
  /// given instead, into one ZIP archive there. Each file is verified
  /// against its encrypted hash like a single download. Returns how many
  /// files were saved, or null with [errorMessage] set on failure.
  Future<int?> downloadEntries(
    List<FileEntry> entries, {
    String? directory,
    String? zipPath,
    bool retryable = true,
  }) {
    assert((directory == null) != (zipPath == null));
    return _runTransfer(
      FileTransferDirection.download,
      label: entries.length == 1
          ? entries.single.name
          : _countLabel(entries.length, files: false),
      whenCancelled: () => null,
      retry: retryable
          ? (_) =>
                () => downloadEntries(
                  entries,
                  directory: directory,
                  zipPath: zipPath,
                )
          : null,
      succeeded: (written) => written != null,
      () async {
        final ctx = await _requireContext();
        if (ctx == null) return null;
        try {
          final items = await _collectDownloadItems(entries, ctx);
          Future<void> download(
            DownloadItem item,
            String path,
            void Function(double progress) onProgress,
          ) => downloadAndDecryptFileToPath(
            api: ctx.api,
            accessToken: ctx.accessToken,
            keys: ctx.keys.ring,
            nodeId: item.nodeId!,
            expectedVersionId: item.versionId,
            destinationPath: path,
            expectedPlaintextSha256: item.plaintextSha256,
            onProgress: onProgress,
          );
          final written = zipPath != null
              ? await downloadItemsAsZip(
                  items: items,
                  zipPath: zipPath,
                  download: download,
                  onProgress: _setProgress,
                )
              : await downloadItemsToDirectory(
                  items: items,
                  directory: directory!,
                  download: download,
                  onProgress: _setProgress,
                );
          _resetSelectionForNavigation();
          notifyListeners();
          return written;
        } catch (e) {
          // Broad on purpose, as in refresh(): see its comment.
          _errorMessage = describeError(e);
          notifyListeners();
          return null;
        } finally {
          ctx.dispose();
        }
      },
    );
  }

  Future<List<DownloadItem>> _collectDownloadItems(
    List<FileEntry> entries,
    _UploadContext ctx,
  ) async {
    final items = <DownloadItem>[];
    final visited = <String>{};
    DownloadItem? fileItem(
      LocalNode node,
      SensitiveNodeMetadata metadata,
      String path,
    ) => node.currentVersionId == null
        ? null // no content uploaded yet
        : DownloadItem.file(
            relativePath: path,
            nodeId: node.id,
            versionId: node.currentVersionId,
            plaintextSha256: metadata.plaintextSha256,
            size: metadata.plaintextSize,
          );
    Future<void> addFolder(LocalNode folder, String path) async {
      if (!visited.add(folder.id)) return;
      items.add(DownloadItem.directory(path));
      for (final child in _syncEngine.nodeCache.listChildren(folder.id)) {
        final SensitiveNodeMetadata metadata;
        try {
          metadata = await ctx.keys.decrypt(child);
        } catch (_) {
          continue;
        }
        final childPath = '$path/${metadata.fileName}';
        if (child.isDirectory) {
          await addFolder(child, childPath);
        } else if (fileItem(child, metadata, childPath) case final item?) {
          items.add(item);
        }
      }
    }

    for (final entry in entries) {
      if (entry.isDirectory) {
        await addFolder(entry.node, entry.name);
      } else if (fileItem(entry.node, entry.metadata, entry.name)
          case final item?) {
        items.add(item);
      }
    }
    return items;
  }

  // --- bulk Trash actions ---

  /// Restores every entry in [items] (with any deleted folders above it).
  /// Returns how many were restored; [errorMessage] explains a failure.
  Future<int> restoreEntries(List<TrashEntry> items) async {
    var restored = 0;
    for (final item in items) {
      if (await restoreFromTrash(item.entry)) restored++;
    }
    return restored;
  }

  /// Permanently deletes every entry in [entries] from Trash now, with
  /// everything inside it. This cannot be undone and needs a connection.
  /// Returns how many entries are gone; an entry inside another selected
  /// folder counts as gone with it.
  Future<int> purgeEntries(List<FileEntry> entries) async {
    final api = _serverConnection.api;
    final session = await _serverConnection.ensureFreshSession();
    if (api == null || session == null) {
      _errorMessage = UserText.of(
        en: 'Connect to the server to delete items permanently.',
        ru: 'Чтобы удалить навсегда, подключитесь к серверу.',
      );
      notifyListeners();
      return 0;
    }
    final selectedIds = {for (final entry in entries) entry.node.id};
    var purged = 0;
    Object? firstError;
    for (final entry in entries) {
      if (_hasSelectedAncestor(entry.node, selectedIds)) {
        purged++;
        continue;
      }
      try {
        await api.purgeTrashEntry(session.accessToken, entry.node.id);
      } on transport.HomeBoxApiException catch (e) {
        // Already purged elsewhere: the intent holds.
        if (e.code != 'NOT_FOUND') {
          firstError ??= e;
          continue;
        }
      } catch (e) {
        firstError ??= e;
        continue;
      }
      _forgetSubtree(entry.node.id);
      purged++;
    }
    if (firstError != null) _errorMessage = describeError(firstError);
    unawaited(_syncEngine.runOnce());
    notifyListeners();
    return purged;
  }

  /// Drops a purged node and everything below it from the local cache.
  void _forgetSubtree(String nodeId) {
    final pending = [nodeId];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      for (final child in _syncEngine.nodeCache.listChildrenIncludingDeleted(
        id,
      )) {
        pending.add(child.id);
      }
      _syncEngine.nodeCache.remove(id);
      _syncEngine.materializedFiles.remove(id);
      _syncEngine.materializedDirectories.remove(id);
      _syncEngine.favorites.remove(id);
    }
  }

  int _compareEntries(FileEntry a, FileEntry b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    // Folder names use a predictable alphabetical order (reversed only for
    // a reversed name sort). Extension, date and size sorts are useful for
    // files, not for navigating folders.
    if (a.isDirectory) {
      final byName = _compareNames(a, b);
      return _sort == FileListSort.name && _sortReversed ? -byName : byName;
    }
    final result = switch (_sort) {
      FileListSort.name => _compareNames(a, b),
      FileListSort.extension => _compareExtensions(a, b),
      FileListSort.updatedAt => _compareUpdatedAt(a, b),
      FileListSort.size => _compareSizes(a, b),
    };
    return _sortReversed ? -result : result;
  }

  int _compareSizes(FileEntry a, FileEntry b) {
    final sizeComparison = (b.metadata.plaintextSize ?? 0).compareTo(
      a.metadata.plaintextSize ?? 0,
    );
    return sizeComparison == 0 ? _compareNames(a, b) : sizeComparison;
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

  /// Every transfer reports progress through here, so this is also where a
  /// cancelled transfer is stopped (see [cancelTransfer]).
  void _setProgress(double value) {
    if (_activeTransferCancelled) throw const TransferCancelledException();
    _progress = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncEngine.removeListener(_onSyncEngineChanged);
    _searchIndex.dispose();
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
