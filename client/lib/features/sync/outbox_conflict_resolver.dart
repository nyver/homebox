import 'dart:convert';
import 'dart:typed_data';

import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/scoped_metadata.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/storage/sync_conflicts_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;

/// Payload keys an UPDATE_NODE outbox entry carries so a revision conflict
/// can be rebased: the node's parent and encrypted metadata as they were
/// when the local change was made. Their absence (entries queued by an older
/// client) means the operation cannot be rebased safely.
const String baseParentIdPayloadKey = 'baseParentId';
const String baseMetadataPayloadKey = 'baseMetadataCiphertext';

/// What to do with an UPDATE_NODE operation the server rejected with
/// `REVISION_CONFLICT` (spec §21's RENAME/MOVE rows).
sealed class UpdateConflictResolution {
  const UpdateConflictResolution();
}

/// The local intent does not collide with the remote change: retry it
/// against the server's current revision with [payload].
final class RetryUpdate extends UpdateConflictResolution {
  const RetryUpdate(this.payload);
  final Map<String, dynamic> payload;
}

/// The server already reflects everything the local change wanted.
final class UpdateAlreadyApplied extends UpdateConflictResolution {
  const UpdateAlreadyApplied();
}

/// The local and remote changes genuinely collide: the server state wins
/// and the conflict is reported.
final class UpdateConflicts extends UpdateConflictResolution {
  const UpdateConflicts(this.kind, {this.fileName});
  final SyncConflictKind kind;
  final String? fileName;
}

/// Decides how an outbox mutation that lost a revision race is replayed.
/// [SyncEngine] holds no key material, so this is the boundary through which
/// it asks a vault-aware component to compare encrypted metadata.
/// Outbox payload key of the key scope [metadataCiphertext] is encrypted
/// with. Absent in operations queued before Family Vault folder keys,
/// which always used the account's personal Vault Key.
const String metadataScopePayloadKey = 'metadataKeyScopeId';

/// Outbox payload key of the key scope of [baseMetadataPayloadKey].
const String baseMetadataScopePayloadKey = 'baseMetadataKeyScopeId';

abstract interface class OutboxConflictResolver {
  Future<UpdateConflictResolution> resolveUpdate({
    required PendingOperation operation,
    required transport.NodeInfo server,
    required String scopeId,
  });

  /// The decrypted display name of [server], for the conflict log.
  Future<String?> displayName({
    required transport.NodeInfo server,
    required String scopeId,
  });
}

/// [OutboxConflictResolver] for the personal vault (spec §21):
/// - a rename is replayed when the remote side did not rename the item too
///   (or chose the same name), re-encrypting the *server's* current metadata
///   with the new name so a concurrent content update's hash and size are
///   never overwritten by stale values;
/// - a move is replayed when the remote side did not move the item to a
///   different folder;
/// - a change to an item deleted remotely is never replayed, so it cannot
///   silently undo the delete.
final class VaultOutboxConflictResolver implements OutboxConflictResolver {
  /// [folderKeys] supplies the account's wrapped shared-folder keys, so a
  /// conflict on a node inside a shared folder can be decrypted too.
  VaultOutboxConflictResolver(
    this._vaultKeyStore, {
    Map<String, Map<int, Uint8List>> Function()? folderKeys,
  }) : _folderKeys = folderKeys; // ignore: prefer_initializing_formals

  final VaultKeyStore _vaultKeyStore;
  final Map<String, Map<int, Uint8List>> Function()? _folderKeys;
  final MetadataCipher _cipher = MetadataCipher();

  Future<OwnerKeyRing?> _openKeys(String userId) => openOwnerKeyRing(
    vaultKeyStore: _vaultKeyStore,
    userId: userId,
    wrappedFolderKeys: _folderKeys?.call() ?? {},
  );

  @override
  Future<UpdateConflictResolution> resolveUpdate({
    required PendingOperation operation,
    required transport.NodeInfo server,
    required String scopeId,
  }) async {
    final payload = operation.payload;
    final requestedMove = payload['moveParent'] as bool? ?? false;
    final fallbackKind = requestedMove
        ? SyncConflictKind.moveRejected
        : SyncConflictKind.renameRejected;
    final keys = await _openKeys(scopeId);
    if (keys == null) return UpdateConflicts(fallbackKind);
    try {
      return await _resolve(operation, server, scopeId, keys, fallbackKind);
    } finally {
      keys.dispose();
    }
  }

  Future<UpdateConflictResolution> _resolve(
    PendingOperation operation,
    transport.NodeInfo server,
    String userId,
    KeyRing keys,
    SyncConflictKind fallbackKind,
  ) async {
    final payload = operation.payload;
    final localMetadataB64 = payload['metadataCiphertext'] as String?;
    final requestedMove = payload['moveParent'] as bool? ?? false;
    final targetParentId = payload['parentId'] as String?;
    final nodeId = uuidStringToBytes(server.id);
    final nodeType = server.nodeType == 'DIRECTORY'
        ? MetadataNodeType.directory
        : MetadataNodeType.file;

    // Each ciphertext names its own scope: the node may have moved into a
    // shared folder's key between when the change was queued and now.
    Future<SensitiveNodeMetadata> decrypt(List<int> ciphertext, String scope) =>
        _decryptIn(keys, ciphertext, scope, nodeType, nodeId);

    final remoteScope = server.metadataKeyScopeId ?? userId;
    final SensitiveNodeMetadata remote;
    final SensitiveNodeMetadata? local;
    try {
      remote = await decrypt(server.metadataCiphertext, remoteScope);
      local = localMetadataB64 == null
          ? null
          : await decrypt(
              base64Decode(localMetadataB64),
              payload[metadataScopePayloadKey] as String? ?? userId,
            );
    } catch (_) {
      return UpdateConflicts(fallbackKind);
    }

    final baseMetadataB64 = payload[baseMetadataPayloadKey] as String?;
    if (server.isDeleted ||
        baseMetadataB64 == null ||
        !payload.containsKey(baseParentIdPayloadKey)) {
      return UpdateConflicts(
        fallbackKind,
        fileName: local?.fileName ?? remote.fileName,
      );
    }
    final SensitiveNodeMetadata base;
    try {
      base = await decrypt(
        base64Decode(baseMetadataB64),
        payload[baseMetadataScopePayloadKey] as String? ?? userId,
      );
    } catch (_) {
      return UpdateConflicts(fallbackKind, fileName: remote.fileName);
    }
    final baseParentId = payload[baseParentIdPayloadKey] as String?;

    final localRename = local != null && local.fileName != base.fileName;
    final remoteRename = remote.fileName != base.fileName;
    final localMove = requestedMove && targetParentId != baseParentId;
    final remoteMove = server.parentId != baseParentId;

    if (localRename && remoteRename && remote.fileName != local.fileName) {
      return UpdateConflicts(
        SyncConflictKind.renameRejected,
        fileName: local.fileName,
      );
    }
    if (localMove && remoteMove && server.parentId != targetParentId) {
      return UpdateConflicts(
        SyncConflictKind.moveRejected,
        fileName: remote.fileName,
      );
    }

    final applyRename = localRename && remote.fileName != local.fileName;
    final applyMove = localMove && server.parentId != targetParentId;
    if (!applyRename && !applyMove) return const UpdateAlreadyApplied();

    Uint8List? metadataCiphertext;
    var metadataKeyVersion = 0;
    if (applyRename) {
      // Re-encrypted in the server node's current scope, which its File
      // DEKs share.
      final key = await keys.current(remoteScope);
      final envelope = await _cipher.encrypt(
        metadata: SensitiveNodeMetadata(
          fileName: local.fileName,
          mimeType: remote.mimeType,
          plaintextSha256: remote.plaintextSha256,
          plaintextSize: remote.plaintextSize,
          conflictDetails: remote.conflictDetails,
          labels: remote.labels,
        ),
        metadataKey: key.key,
        keyVersion: key.version,
        nodeType: nodeType,
        scopeId: key.scopeIdBytes,
        nodeId: nodeId,
      );
      metadataCiphertext = envelope.encode();
      metadataKeyVersion = key.version;
    }
    return RetryUpdate({
      if (metadataCiphertext != null)
        'metadataCiphertext': base64Encode(metadataCiphertext),
      if (metadataCiphertext != null) 'metadataKeyVersion': metadataKeyVersion,
      if (metadataCiphertext != null) metadataScopePayloadKey: remoteScope,
      'moveParent': applyMove,
      'parentId': applyMove ? targetParentId : server.parentId,
      baseParentIdPayloadKey: server.parentId,
      baseMetadataPayloadKey: base64Encode(server.metadataCiphertext),
      baseMetadataScopePayloadKey: remoteScope,
    });
  }

  Future<SensitiveNodeMetadata> _decryptIn(
    KeyRing keys,
    List<int> ciphertext,
    String scope,
    MetadataNodeType nodeType,
    Uint8List nodeId,
  ) => decryptNodeMetadata(
    keys: keys,
    ciphertext: ciphertext,
    scopeId: scope,
    isDirectory: nodeType == MetadataNodeType.directory,
    nodeId: bytesToUuidString(nodeId),
    cipher: _cipher,
  );

  @override
  Future<String?> displayName({
    required transport.NodeInfo server,
    required String scopeId,
  }) async {
    OwnerKeyRing? keys;
    try {
      keys = await _openKeys(scopeId);
      if (keys == null) return null;
      final metadata = await _decryptIn(
        keys,
        server.metadataCiphertext,
        server.metadataKeyScopeId ?? scopeId,
        server.nodeType == 'DIRECTORY'
            ? MetadataNodeType.directory
            : MetadataNodeType.file,
        uuidStringToBytes(server.id),
      );
      return metadata.fileName;
    } catch (_) {
      return null;
    } finally {
      keys?.dispose();
    }
  }
}
