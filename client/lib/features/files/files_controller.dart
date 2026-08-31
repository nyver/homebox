// Constructor parameters are named to give callers readable arguments
// (`serverConnection:`, `vaultKeyStore:`, `syncEngine:`) instead of the
// backing private field names (matches ServerConnectionController/SyncEngine).
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/local_path.dart';
import '../server/server_connection_controller.dart';
import '../sync/sync_engine.dart';
import 'file_transfer.dart';

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
}

/// The outcome of one user-initiated batch of file uploads.
final class FileUploadBatchResult {
  const FileUploadBatchResult({required this.succeeded, required this.failed});

  final int succeeded;
  final int failed;
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
  FilesController({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required SyncEngine syncEngine,
  }) : _serverConnection = serverConnection,
       _vaultKeyStore = vaultKeyStore,
       _syncEngine = syncEngine {
    _syncEngine.addListener(_onSyncEngineChanged);
  }

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;
  final MetadataCipher _metadataCipher = MetadataCipher();
  static const int _maxImagePreviewSourceSize = 12 * 1024 * 1024;
  static const int _maxCachedImagePreviews = 8;
  static const int _maxConcurrentImagePreviews = 2;
  final Map<String, Uint8List?> _imagePreviewCache = {};
  final Map<String, Future<Uint8List?>> _imagePreviewLoads = {};

  FilesStatus _status = FilesStatus.idle;
  String? _errorMessage;
  List<FileEntry> _entries = const [];
  final List<_Breadcrumb> _path = [];
  bool _busy = false;
  double? _progress;
  FileTransferDirection? _transferDirection;
  FileListSort _sort = FileListSort.name;
  bool _disposed = false;

  FilesStatus get status => _status;
  String? get errorMessage => _errorMessage;
  List<FileEntry> get entries => _entries;
  bool get busy => _busy;
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

  /// Returns a decrypted image source for a compact list preview. Previews
  /// deliberately use a separate, bounded cache and never claim the primary
  /// transfer state, so rendering a list cannot block an explicit upload or
  /// download. Large images remain a regular file icon to avoid excessive
  /// network and memory use while scrolling.
  Future<Uint8List?> imagePreview(FileEntry entry) {
    if (!canShowImagePreview(entry)) {
      return Future<Uint8List?>.value(null);
    }
    final key = '${entry.node.id}:${entry.node.currentVersionId}';
    if (_imagePreviewCache.containsKey(key)) {
      return Future<Uint8List?>.value(_imagePreviewCache[key]);
    }
    final pending = _imagePreviewLoads[key];
    if (pending != null) return pending;
    if (_imagePreviewLoads.length >= _maxConcurrentImagePreviews) {
      return Future<Uint8List?>.value(null);
    }
    final preview = _downloadImagePreview(entry);
    _imagePreviewLoads[key] = preview;
    unawaited(
      preview.then((bytes) {
        _imagePreviewLoads.remove(key);
        if (_imagePreviewCache.length >= _maxCachedImagePreviews) {
          _imagePreviewCache.remove(_imagePreviewCache.keys.first);
        }
        _imagePreviewCache[key] = bytes;
        if (!_disposed) notifyListeners();
      }),
    );
    return preview;
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
      _setStatus(FilesStatus.ready);
    } catch (e) {
      // Broad on purpose: StateError/ArgumentError (thrown by this class's
      // own checks) do not extend Exception, so `on Exception` would miss
      // them and crash instead of surfacing errorMessage.
      _errorMessage = '$e';
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
      _errorMessage = '$e';
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
      _errorMessage = '$e';
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
      _errorMessage = '$e';
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
    if (_busy) {
      _errorMessage = 'Another file transfer is already in progress.';
      notifyListeners();
      return FileUploadBatchResult(succeeded: 0, failed: uniquePaths.length);
    }
    // Claimed synchronously, before any `await` — see replaceFileContent.
    _setBusy(true, direction: FileTransferDirection.upload);
    _errorMessage = null;
    var succeeded = 0;
    var failed = 0;
    try {
      final ctx = await _requireContext();
      if (ctx == null) {
        return FileUploadBatchResult(succeeded: 0, failed: uniquePaths.length);
      }
      // Capture this before any asynchronous work. A user may navigate
      // while a large drop is uploading, but that must not move later
      // files elsewhere.
      final targetParentId = _currentParentId;
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
        } catch (e) {
          // Continue so a single unreadable or oversized dropped file does
          // not prevent the rest of the selection from being backed up.
          failed++;
          _errorMessage = '$e';
          notifyListeners();
        }
      }
      await refresh();
      return FileUploadBatchResult(succeeded: succeeded, failed: failed);
    } finally {
      _setBusy(false);
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
    if (_busy) {
      _errorMessage = 'Another file transfer is already in progress.';
      notifyListeners();
      return false;
    }
    // Claimed synchronously, before any `await`, so two calls arriving
    // close together can't both observe `_busy == false` and both proceed
    // — Dart can't interleave them without an await in between.
    _setBusy(true, direction: FileTransferDirection.upload);
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
        onProgress: _setProgress,
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
      _errorMessage = '$e';
      notifyListeners();
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// Downloads, decrypts, and saves [entry] to [destinationPath] (spec
  /// §23): unwraps the File DEK from the newest version's key envelope,
  /// splits the downloaded ciphertext blob back into AEAD frames, decrypts
  /// each (any authentication failure aborts before anything is written),
  /// and verifies the plaintext SHA-256 recorded in the encrypted metadata
  /// before the file is saved.
  Future<bool> downloadFile(FileEntry entry, String destinationPath) async {
    if (_busy) {
      _errorMessage = 'Another file transfer is already in progress.';
      notifyListeners();
      return false;
    }
    // Claimed synchronously, before any `await` — see replaceFileContent.
    _setBusy(true, direction: FileTransferDirection.download);
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
      _errorMessage = '$e';
      notifyListeners();
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<Uint8List?> _downloadImagePreview(FileEntry entry) async {
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
    _imagePreviewLoads.clear();
    super.dispose();
  }
}
