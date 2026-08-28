import 'dart:async';
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
import '../../core/transport/homebox_api_client.dart' as transport;
import '../server/server_connection_controller.dart';

enum FilesStatus { idle, loading, ready, failed }

/// A decrypted-for-display file or folder entry. The server only ever knows
/// [node]'s opaque ID and ciphertext; [metadata] is decrypted locally.
final class FileEntry {
  const FileEntry({required this.node, required this.metadata});

  final transport.NodeInfo node;
  final SensitiveNodeMetadata metadata;

  bool get isDirectory => node.nodeType == 'DIRECTORY';
  String get name => metadata.fileName;
}

final class _Breadcrumb {
  const _Breadcrumb(this.id, this.name);
  final String id;
  final String name;
}

final class _UploadContext {
  const _UploadContext({required this.api, required this.accessToken, required this.vaultKey, required this.vaultId});
  final transport.HomeBoxApiClient api;
  final String accessToken;
  final SecretKey vaultKey;
  final Uint8List vaultId;
}

/// Drives the Files browser: lists a folder's decrypted contents, and
/// performs upload/download by composing the E2EE core (encrypt/decrypt,
/// key wrapping, metadata) with [transport.HomeBoxApiClient] (opaque nodes,
/// resumable ciphertext upload, ciphertext download). This is the first
/// place file content is ever encrypted or decrypted in this client — the
/// concrete proof of spec §10 end to end, not just the primitives in
/// isolation.
///
/// Scoped to this account's one personal vault (`vaultId == userId`, key
/// version 1); Folder-specific keys, sharing, and rotation are later
/// milestones (§28, §10.11).
final class FilesController extends ChangeNotifier {
  // Named rather than initializing formals so callers in other files get
  // readable named arguments instead of the private field names.
  FilesController({required ServerConnectionController serverConnection, required VaultKeyStore vaultKeyStore})
      // ignore: prefer_initializing_formals
      : _serverConnection = serverConnection,
        // ignore: prefer_initializing_formals
        _vaultKeyStore = vaultKeyStore;

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
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

  Future<void> refresh() async {
    final ctx = await _requireContext();
    if (ctx == null) {
      _setStatus(FilesStatus.failed);
      return;
    }
    _setStatus(FilesStatus.loading);
    try {
      final nodes = await ctx.api.listChildren(ctx.accessToken, parentId: _currentParentId);
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
      await ctx.api.createNode(
        ctx.accessToken,
        id: nodeId,
        operationId: generateUuidV4(),
        parentId: _currentParentId,
        nodeType: 'DIRECTORY',
        metadataCiphertext: envelope.encode(),
        metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
      );
      await refresh();
      return true;
    } catch (e) {
      // Broad on purpose: StateError/ArgumentError (thrown by this class's
      // own checks) do not extend Exception, so `on Exception` would miss
      // them and crash instead of surfacing errorMessage.
      _errorMessage = '$e';
      notifyListeners();
      return false;
    }
  }

  /// Encrypts and uploads a local file (spec §22): a new opaque node, a
  /// fresh random File DEK wrapped by the vault key, 4 MiB AEAD chunks, and
  /// a resumable-upload session driven to completion. Returns false and
  /// sets [errorMessage] on failure — a partial upload is never left
  /// referenced by the node (the server-side upload session simply expires
  /// unfinished).
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
        keyScopeId: _serverConnection.session!.user.id,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        expectedRevision: createdNode.revision,
      );

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

  Future<SensitiveNodeMetadata> _decryptMetadata(transport.NodeInfo node, _UploadContext ctx) {
    final envelope = EncryptedMetadataEnvelope.decode(node.metadataCiphertext);
    return _metadataCipher.decrypt(
      envelope: envelope,
      metadataKey: ctx.vaultKey,
      nodeType: node.nodeType == 'DIRECTORY' ? MetadataNodeType.directory : MetadataNodeType.file,
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
    super.dispose();
  }
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index == -1 ? normalized : normalized.substring(index + 1);
}
