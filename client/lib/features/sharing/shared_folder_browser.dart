// Constructor parameters are named for readable call sites, as elsewhere.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/portable_name.dart';
import '../../core/e2ee/scoped_metadata.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/local_path.dart';
import '../../core/util/user_facing_error.dart';
import '../files/file_transfer.dart';
import '../server/server_connection_controller.dart';

/// One decrypted entry of a folder shared with this account.
final class SharedEntry {
  const SharedEntry({required this.node, required this.metadata});

  final transport.NodeInfo node;
  final SensitiveNodeMetadata metadata;

  bool get isDirectory => node.nodeType == 'DIRECTORY';
  String get name => metadata.fileName;
}

/// Browses one folder another family member shared with this account
/// (spec §28). Unlike the personal Vault this works online against the
/// server, and everything is decrypted with the shared folder's key, which
/// [keys] holds. With READ_WRITE permission the member can also add,
/// rename, replace, and delete content; it is encrypted with the newest
/// folder key so every member can read it.
final class SharedFolderBrowser extends ChangeNotifier {
  SharedFolderBrowser({
    required ServerConnectionController serverConnection,
    required this.share,
    required this.rootName,
    required SharedKeyRing keys,
  }) : _serverConnection = serverConnection,
       _keys = keys;

  final ServerConnectionController _serverConnection;
  final transport.FamilyShare share;
  final String rootName;
  final SharedKeyRing _keys;
  final MetadataCipher _cipher = MetadataCipher();

  final List<({String id, String name})> _path = [];
  List<SharedEntry> _entries = const [];
  bool _loading = false;
  bool _busy = false;
  double? _progress;
  String? _errorMessage;
  bool _disposed = false;

  List<SharedEntry> get entries => _entries;
  bool get loading => _loading;
  bool get busy => _busy;
  double? get progress => _progress;
  String? get errorMessage => _errorMessage;
  bool get canWrite => share.canWrite;
  bool get canGoUp => _path.isNotEmpty;
  List<String> get breadcrumbNames => [rootName, for (final p in _path) p.name];

  String get _currentFolderId => _path.isEmpty ? share.nodeId : _path.last.id;

  Future<void> refresh() async {
    final ctx = await _session();
    if (ctx == null) return;
    _loading = true;
    _notify();
    try {
      final nodes = await ctx.api.listChildren(
        ctx.accessToken,
        parentId: _currentFolderId,
      );
      final entries = <SharedEntry>[];
      for (final node in nodes) {
        try {
          entries.add(SharedEntry(node: node, metadata: await _decrypt(node)));
        } catch (_) {
          // Not yet re-encrypted for sharing by the owner's device, or a
          // key version this device was not given: skip it.
        }
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      _entries = entries;
      _errorMessage = null;
    } catch (e) {
      _errorMessage = describeError(e);
    } finally {
      _loading = false;
      _notify();
    }
  }

  void open(SharedEntry entry) {
    if (!entry.isDirectory) return;
    _path.add((id: entry.node.id, name: entry.name));
    unawaited(refresh());
  }

  void goUp() {
    if (_path.isEmpty) return;
    _path.removeLast();
    unawaited(refresh());
  }

  /// [index] 0 is the shared folder itself.
  void goToBreadcrumb(int index) {
    if (index < 0 || index > _path.length) return;
    _path.removeRange(index, _path.length);
    unawaited(refresh());
  }

  Future<bool> download(SharedEntry entry, String destinationPath) =>
      _transfer(() async {
        final ctx = await _session();
        if (ctx == null) return false;
        await downloadAndDecryptFileToPath(
          api: ctx.api,
          accessToken: ctx.accessToken,
          keys: _keys,
          nodeId: entry.node.id,
          expectedVersionId: entry.node.currentVersionId,
          destinationPath: destinationPath,
          expectedPlaintextSha256: entry.metadata.plaintextSha256,
          onProgress: _setProgress,
        );
        return true;
      });

  /// Uploads [localPaths] into the open folder. A name that already exists
  /// there is refused rather than overwritten.
  Future<bool> uploadFiles(List<String> localPaths) => _transfer(() async {
    _requireWrite();
    final ctx = await _session();
    if (ctx == null) return false;
    final taken = {
      for (final e in _entries) PortableName.comparisonKey(e.name),
    };
    var failures = 0;
    for (final (index, path) in localPaths.indexed) {
      try {
        final name = basenameOfLocalPath(path);
        if (!taken.add(PortableName.comparisonKey(name))) {
          throw StateError('"$name" already exists in this folder.');
        }
        await _uploadNew(ctx, File(path), name, (progress) {
          _setProgress((index + progress) / localPaths.length);
        });
      } catch (e) {
        failures++;
        _errorMessage = describeError(e);
      }
    }
    await refresh();
    return failures == 0;
  });

  /// Replaces [entry]'s content with [localPath] as a new version.
  Future<bool> replaceContent(SharedEntry entry, String localPath) =>
      _transfer(() async {
        _requireWrite();
        final ctx = await _session();
        if (ctx == null) return false;
        final file = File(localPath);
        final length = await file.length();
        final hash = await plaintextFileSha256(file);
        final key = await _keys.current(share.nodeId);
        final metadata = await _encrypt(
          key,
          entry.node.id,
          SensitiveNodeMetadata(
            fileName: entry.name,
            mimeType: entry.metadata.mimeType,
            plaintextSha256: hash,
            plaintextSize: length,
          ),
          MetadataNodeType.file,
        );
        await uploadFilePathVersion(
          api: ctx.api,
          accessToken: ctx.accessToken,
          key: key,
          targetNodeId: entry.node.id,
          expectedRevision: entry.node.revision,
          file: file,
          plaintextLength: length,
          expectedPlaintextSha256: hash,
          metadataCiphertext: metadata,
          onProgress: _setProgress,
        );
        await refresh();
        return true;
      });

  Future<bool> createFolder(String name) => _mutate(() async {
    _requireWrite();
    final ctx = await _session();
    if (ctx == null) return false;
    _checkNameFree(name);
    final key = await _keys.current(share.nodeId);
    final id = generateUuidV4();
    await ctx.api.createNode(
      ctx.accessToken,
      id: id,
      operationId: generateUuidV4(),
      parentId: _currentFolderId,
      nodeType: 'DIRECTORY',
      metadataCiphertext: await _encrypt(
        key,
        id,
        SensitiveNodeMetadata(fileName: name),
        MetadataNodeType.directory,
      ),
      metadataKeyVersion: key.version,
      metadataKeyScopeId: key.scopeId,
    );
    return true;
  });

  Future<bool> rename(SharedEntry entry, String newName) => _mutate(() async {
    _requireWrite();
    final ctx = await _session();
    if (ctx == null) return false;
    _checkNameFree(newName, except: entry);
    final key = await _keys.current(share.nodeId);
    final m = entry.metadata;
    await ctx.api.updateNode(
      ctx.accessToken,
      entry.node.id,
      operationId: generateUuidV4(),
      expectedRevision: entry.node.revision,
      metadataCiphertext: await _encrypt(
        key,
        entry.node.id,
        SensitiveNodeMetadata(
          fileName: newName,
          mimeType: m.mimeType,
          plaintextSha256: m.plaintextSha256,
          plaintextSize: m.plaintextSize,
          conflictDetails: m.conflictDetails,
          labels: m.labels,
        ),
        entry.isDirectory ? MetadataNodeType.directory : MetadataNodeType.file,
      ),
      metadataKeyVersion: key.version,
      metadataKeyScopeId: key.scopeId,
      parentId: entry.node.parentId,
    );
    return true;
  });

  /// Moves [entry] to the owner's Trash, from which the owner can restore it.
  Future<bool> delete(SharedEntry entry) => _mutate(() async {
    _requireWrite();
    final ctx = await _session();
    if (ctx == null) return false;
    await ctx.api.deleteNode(
      ctx.accessToken,
      entry.node.id,
      operationId: generateUuidV4(),
      expectedRevision: entry.node.revision,
    );
    return true;
  });

  Future<void> _uploadNew(
    _Session ctx,
    File file,
    String name,
    void Function(double progress) onProgress,
  ) async {
    final length = await file.length();
    if (length > homeBoxMaxPlaintextFileSize) {
      throw const FormatException('HomeBox files are limited to 500 MiB.');
    }
    final hash = await plaintextFileSha256(file);
    final key = await _keys.current(share.nodeId);
    final id = generateUuidV4();
    final metadata = await _encrypt(
      key,
      id,
      SensitiveNodeMetadata(
        fileName: name,
        plaintextSha256: hash,
        plaintextSize: length,
      ),
      MetadataNodeType.file,
    );
    final created = await ctx.api.createNode(
      ctx.accessToken,
      id: id,
      operationId: generateUuidV4(),
      parentId: _currentFolderId,
      nodeType: 'FILE',
      metadataCiphertext: metadata,
      metadataKeyVersion: key.version,
      metadataKeyScopeId: key.scopeId,
    );
    await uploadFilePathVersion(
      api: ctx.api,
      accessToken: ctx.accessToken,
      key: key,
      targetNodeId: id,
      expectedRevision: created.revision,
      file: file,
      plaintextLength: length,
      expectedPlaintextSha256: hash,
      metadataCiphertext: metadata,
      onProgress: onProgress,
    );
  }

  void _checkNameFree(String name, {SharedEntry? except}) {
    final key = PortableName.comparisonKey(
      PortableName.normalizeAndValidate(name),
    );
    for (final entry in _entries) {
      if (identical(entry, except)) continue;
      if (PortableName.comparisonKey(entry.name) == key) {
        throw StateError('"$name" already exists in this folder.');
      }
    }
  }

  void _requireWrite() {
    if (!canWrite) {
      throw StateError('This folder was shared with you as view only.');
    }
  }

  Future<SensitiveNodeMetadata> _decrypt(transport.NodeInfo node) =>
      decryptNodeMetadata(
        keys: _keys,
        ciphertext: node.metadataCiphertext,
        scopeId: node.metadataKeyScopeId ?? share.ownerUserId,
        isDirectory: node.nodeType == 'DIRECTORY',
        nodeId: node.id,
        cipher: _cipher,
      );

  Future<Uint8List> _encrypt(
    ScopedKey key,
    String nodeId,
    SensitiveNodeMetadata metadata,
    MetadataNodeType type,
  ) => encryptNodeMetadata(
    key: key,
    metadata: metadata,
    isDirectory: type == MetadataNodeType.directory,
    nodeId: nodeId,
    cipher: _cipher,
  );

  Future<bool> _transfer(Future<bool> Function() body) async {
    if (_busy) return false;
    _busy = true;
    _progress = 0;
    _notify();
    try {
      return await body();
    } catch (e) {
      _errorMessage = describeError(e);
      return false;
    } finally {
      _busy = false;
      _progress = null;
      _notify();
    }
  }

  Future<bool> _mutate(Future<bool> Function() body) async {
    try {
      final ok = await body();
      await refresh();
      return ok;
    } catch (e) {
      _errorMessage = describeError(e);
      _notify();
      return false;
    }
  }

  void _setProgress(double value) {
    _progress = value;
    _notify();
  }

  Future<_Session?> _session() async {
    final api = _serverConnection.api;
    final session = await _serverConnection.ensureFreshSession();
    if (api == null || session == null) {
      _errorMessage = 'Connect to the server and sign in first.';
      _notify();
      return null;
    }
    return _Session(api, session.accessToken);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _keys.dispose();
    super.dispose();
  }
}

final class _Session {
  const _Session(this.api, this.accessToken);

  final transport.HomeBoxApiClient api;
  final String accessToken;
}
