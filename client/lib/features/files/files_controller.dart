// Constructor parameters are named to give callers readable arguments
// (`serverConnection:`, `vaultKeyStore:`, `syncEngine:`) instead of the
// backing private field names (matches ServerConnectionController/SyncEngine).
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/file_cipher.dart';
import '../../core/e2ee/key_envelope.dart';
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../server/server_connection_controller.dart';
import '../sync/sync_engine.dart';

enum FilesStatus { idle, loading, ready, failed }

/// A decrypted-for-display file or folder entry. The server only ever knows
/// [node]'s opaque ID and ciphertext; [metadata] is decrypted locally.
final class FileEntry {
  const FileEntry({required this.node, required this.metadata});

  final LocalNode node;
  final SensitiveNodeMetadata metadata;

  bool get isDirectory => node.isDirectory;
  String get name => metadata.fileName;
}

final class _Breadcrumb {
  const _Breadcrumb(this.id, this.name);
  final String id;
  final String name;
}

final class _UploadContext {
  const _UploadContext({required this.api, required this.accessToken, required this.vaultKey, required this.vaultId, required this.userId});
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
  })  : _serverConnection = serverConnection,
        _vaultKeyStore = vaultKeyStore,
        _syncEngine = syncEngine {
    _syncEngine.addListener(_onSyncEngineChanged);
  }

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final SyncEngine _syncEngine;
  final MetadataCipher _metadataCipher = MetadataCipher();
  final E2eeFileCipher _fileCipher = E2eeFileCipher();
  final KeyEnvelopeCipher _keyEnvelopeCipher = KeyEnvelopeCipher();

  FilesStatus _status = FilesStatus.idle;
  String? _errorMessage;
  List<FileEntry> _entries = const [];
  final List<_Breadcrumb> _path = [];
  bool _busy = false;
  double? _progress;
  bool _disposed = false;

  FilesStatus get status => _status;
  String? get errorMessage => _errorMessage;
  List<FileEntry> get entries => _entries;
  bool get busy => _busy;
  double? get progress => _progress;
  bool get canGoUp => _path.isNotEmpty;
  List<String> get breadcrumbNames => _path.map((e) => e.name).toList(growable: false);
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
          decrypted.add(FileEntry(node: node, metadata: await _decryptMetadata(node, ctx)));
        } catch (_) {
          // A node this device cannot decrypt or parse (wrong/missing key
          // version, or malformed metadata) is skipped rather than failing
          // the whole listing. Broad catch: envelope decoding can throw
          // ArgumentError, which does not extend Exception.
        }
      }
      decrypted.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
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
      _syncEngine.nodeCache.upsert(LocalNode(
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
      ));
      _syncEngine.pendingOperations.enqueue(PendingOperation(
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
      ));
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
  Future<bool> renameNode(FileEntry entry, String newName, {bool move = false, String? newParentId}) async {
    final ctx = await _requireContext();
    if (ctx == null) return false;
    try {
      final envelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(fileName: newName, mimeType: entry.metadata.mimeType, plaintextSha256: entry.metadata.plaintextSha256),
        metadataKey: ctx.vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: entry.isDirectory ? MetadataNodeType.directory : MetadataNodeType.file,
        scopeId: ctx.vaultId,
        nodeId: uuidStringToBytes(entry.node.id),
      );
      final metadataCiphertext = envelope.encode();
      final targetParentId = move ? newParentId : entry.node.parentId;
      _syncEngine.nodeCache.upsert(LocalNode(
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
      ));
      _enqueueUpdate(entry.node, baseRevision: entry.node.revision, metadataCiphertext: metadataCiphertext, moveParent: move, parentId: targetParentId);
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
      _syncEngine.nodeCache.upsert(LocalNode(
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
      ));
      _syncEngine.pendingOperations.enqueue(PendingOperation(
        id: generateUuidV4(),
        operationId: generateUuidV4(),
        type: PendingOperationType.deleteNode,
        nodeId: entry.node.id,
        payload: const {},
        baseRevision: entry.node.revision,
        createdAt: now,
        retryCount: 0,
        status: PendingOperationStatus.pending,
      ));
      unawaited(_syncEngine.runOnce());
      await refresh();
      return true;
    } catch (e) {
      _errorMessage = '$e';
      notifyListeners();
      return false;
    }
  }

  void _enqueueUpdate(LocalNode node, {required int baseRevision, Uint8List? metadataCiphertext, bool moveParent = false, String? parentId}) {
    _syncEngine.pendingOperations.enqueue(PendingOperation(
      id: generateUuidV4(),
      operationId: generateUuidV4(),
      type: PendingOperationType.updateNode,
      nodeId: node.id,
      payload: {
        if (metadataCiphertext != null) 'metadataCiphertext': base64Encode(metadataCiphertext),
        if (metadataCiphertext != null) 'metadataKeyVersion': homeBoxPersonalVaultKeyVersion,
        'moveParent': moveParent,
        'parentId': parentId,
      },
      baseRevision: baseRevision,
      createdAt: DateTime.now().toUtc(),
      retryCount: 0,
      status: PendingOperationStatus.pending,
    ));
  }

  /// Encrypts and uploads a local file (spec §22): a new opaque node, a
  /// fresh random File DEK wrapped by the vault key, 4 MiB AEAD chunks, and
  /// a resumable-upload session driven to completion. Returns false and
  /// sets [errorMessage] on failure — a partial upload is never left
  /// referenced by the node (the server-side upload session simply expires
  /// unfinished). Unlike folder/rename/delete, this requires connectivity
  /// up front rather than queuing — see the class doc comment.
  Future<bool> uploadFile(String localPath) async {
    final ctx = await _requireContext();
    if (ctx == null) return false;
    _setBusy(true);
    try {
      final bytes = await File(localPath).readAsBytes();
      if (bytes.length > 100 * 1024 * 1024) {
        throw const FormatException('HomeBox files are limited to 100 MB.');
      }
      final fileName = _basename(localPath);
      final plaintextHash = sha256.convert(bytes).toString();

      final nodeId = generateUuidV4();
      final fileVersionId = generateUuidV4();
      final blobId = generateUuidV4();
      final nodeIdBytes = uuidStringToBytes(nodeId);
      final fileVersionIdBytes = uuidStringToBytes(fileVersionId);

      final metadataEnvelope = await _metadataCipher.encrypt(
        metadata: SensitiveNodeMetadata(fileName: fileName, plaintextSha256: plaintextHash),
        metadataKey: ctx.vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        nodeType: MetadataNodeType.file,
        scopeId: ctx.vaultId,
        nodeId: nodeIdBytes,
      );

      final createdNode = await ctx.api.createNode(
        ctx.accessToken,
        id: nodeId,
        operationId: generateUuidV4(),
        parentId: _currentParentId,
        nodeType: 'FILE',
        metadataCiphertext: metadataEnvelope.encode(),
        metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
      );
      _upsertFromServer(createdNode);

      final fileKey = await _fileCipher.newFileKey();
      final header = _fileCipher.newHeader();
      final totalChunks = bytes.isEmpty ? 1 : (bytes.length / homeBoxPlaintextChunkSize).ceil();
      final frames = <Uint8List>[];
      for (var i = 0; i < totalChunks; i++) {
        final start = i * homeBoxPlaintextChunkSize;
        final end = start + homeBoxPlaintextChunkSize < bytes.length ? start + homeBoxPlaintextChunkSize : bytes.length;
        final frame = await _fileCipher.encryptChunk(
          plaintext: Uint8List.sublistView(bytes, start, end),
          fileKey: fileKey,
          header: header,
          fileVersionId: fileVersionIdBytes,
          chunkNumber: i,
          totalChunks: totalChunks,
        );
        frames.add(frame);
        _setProgress((i + 1) / (totalChunks * 2));
      }

      final wrappedFileKey = await _keyEnvelopeCipher.wrapKey(
        wrappingKey: ctx.vaultKey,
        keyToWrap: fileKey,
        purpose: KeyEnvelopePurpose.fileKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        scopeId: ctx.vaultId,
        subjectId: fileVersionIdBytes,
      );

      final uploadSession = await ctx.api.createUpload(
        ctx.accessToken,
        targetNodeId: nodeId,
        fileVersionId: fileVersionId,
        blobId: blobId,
        chunkSize: homeBoxPlaintextChunkSize + homeBoxChunkMacLength,
        chunkCount: totalChunks,
        metadataCiphertext: metadataEnvelope.encode(),
        wrappedFileKey: wrappedFileKey.encode(),
        e2eeHeader: header.encode(),
      );

      for (var i = 0; i < totalChunks; i++) {
        await ctx.api.putUploadChunk(ctx.accessToken, uploadSession.id, i, frames[i]);
        _setProgress(0.5 + (i + 1) / (totalChunks * 2));
      }

      await ctx.api.completeUpload(
        ctx.accessToken,
        uploadSession.id,
        operationId: generateUuidV4(),
        keyScopeId: ctx.userId,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        expectedRevision: createdNode.revision,
      );
      _upsertFromServer(await ctx.api.getNode(ctx.accessToken, nodeId));

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
    final ctx = await _requireContext();
    if (ctx == null) return false;
    _setBusy(true);
    try {
      final versions = await ctx.api.listFileVersions(ctx.accessToken, entry.node.id);
      if (versions.isEmpty) {
        throw StateError('This file has no uploaded content yet.');
      }
      final version = versions.first; // newest first, per the server's ordering.
      final versionIdBytes = uuidStringToBytes(version.id);

      final fileKey = await _keyEnvelopeCipher.unwrapKey(
        wrappingKey: ctx.vaultKey,
        envelope: KeyEnvelope.decode(version.wrappedFileKey),
        scopeId: ctx.vaultId,
        subjectId: versionIdBytes,
      );
      final header = E2eeFileHeader.decode(version.e2eeHeader);

      final blob = await ctx.api.downloadFileContent(ctx.accessToken, entry.node.id);
      final frames = splitChunkFrames(blob, chunkCount: version.chunkCount);

      final output = BytesBuilder(copy: false);
      for (var i = 0; i < frames.length; i++) {
        final plaintext = await _fileCipher.decryptChunk(
          ciphertextFrame: frames[i],
          fileKey: fileKey,
          header: header,
          fileVersionId: versionIdBytes,
          chunkNumber: i,
          totalChunks: frames.length,
        );
        output.add(plaintext);
        _setProgress((i + 1) / frames.length);
      }
      final plaintextBytes = output.takeBytes();

      final expectedHash = entry.metadata.plaintextSha256;
      if (expectedHash != null) {
        final actualHash = sha256.convert(plaintextBytes).toString();
        if (actualHash.toLowerCase() != expectedHash.toLowerCase()) {
          throw StateError('Downloaded content failed integrity verification; the file was not saved.');
        }
      }

      await File(destinationPath).writeAsBytes(plaintextBytes, flush: true);
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

  void _upsertFromServer(transport.NodeInfo node) {
    _syncEngine.nodeCache.upsert(LocalNode(
      id: node.id,
      parentId: node.parentId,
      nodeType: node.nodeType,
      metadataCiphertext: node.metadataCiphertext,
      metadataKeyVersion: node.metadataKeyVersion,
      currentVersionId: node.currentVersionId,
      revision: node.revision,
      createdAt: node.createdAt,
      updatedAt: node.updatedAt,
      deletedAt: node.deletedAt,
      pendingCreate: false,
    ));
  }

  Future<SensitiveNodeMetadata> _decryptMetadata(LocalNode node, _UploadContext ctx) {
    final envelope = EncryptedMetadataEnvelope.decode(node.metadataCiphertext);
    return _metadataCipher.decrypt(
      envelope: envelope,
      metadataKey: ctx.vaultKey,
      nodeType: node.isDirectory ? MetadataNodeType.directory : MetadataNodeType.file,
      scopeId: ctx.vaultId,
      nodeId: uuidStringToBytes(node.id),
    );
  }

  Future<_UploadContext?> _requireContext() async {
    final api = _serverConnection.api;
    final session = _serverConnection.session;
    final vaultKey = await _vaultKeyStore.loadVaultKey();
    if (api == null || session == null || vaultKey == null) {
      _errorMessage = 'Connect to a server, sign in, and set up the vault first.';
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

  void _setStatus(FilesStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  void _setBusy(bool value) {
    _busy = value;
    _progress = value ? 0 : null;
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
    super.dispose();
  }
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index == -1 ? normalized : normalized.substring(index + 1);
}
