// ignore_for_file: prefer_initializing_formals
import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/storage/node_cache.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../files/file_transfer.dart' show rewrapFileKey;
import '../sync/sync_engine.dart';

/// Moves content below a shared folder into that folder's key scope
/// (ADR-023). A folder's subtree must be readable with its Folder Key
/// before members can use it, and anything later moved or uploaded into it
/// with the owner's personal Vault Key must follow. Each node's metadata is
/// re-encrypted and every File DEK of every version rewrapped on this
/// device; the server only swaps ciphertext and never sees a key.
///
/// Idempotent and safe to run after every sync pass: nodes already in the
/// right scope are skipped, nodes with a queued local change wait for it,
/// and a batch that loses a revision race is simply retried next time.
final class SharedScopeReconciler {
  SharedScopeReconciler({required SyncEngine syncEngine})
    : _syncEngine = syncEngine;

  final SyncEngine _syncEngine;
  final MetadataCipher _cipher = MetadataCipher();

  /// Nodes per rekey request; well below the server's limit of 200.
  static const int batchSize = 50;

  /// Rekeys every node below the shared folders in [folderIds] (all of this
  /// account's shared folders when null). Returns how many nodes moved.
  /// Throws only for errors that are not a revision race.
  Future<int> reconcile({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeyRing keys,
    Iterable<String>? folderIds,
  }) async {
    var moved = 0;
    for (final folderId in (folderIds ?? keys.keyedFolderIds).toList()) {
      final root = _syncEngine.nodeCache.getById(folderId);
      if (root == null || root.isDeleted || !root.isDirectory) continue;
      final stale = _nodesOutsideScope(root, keys.userId);
      for (var start = 0; start < stale.length; start += batchSize) {
        final batch = stale.sublist(
          start,
          (start + batchSize).clamp(0, stale.length),
        );
        final items = <transport.RekeyItem>[];
        for (final node in batch) {
          items.add(await _rekeyItem(api, accessToken, keys, node, folderId));
        }
        try {
          final updated = await api.rekeyNodes(accessToken, items);
          for (final node in updated) {
            _syncEngine.nodeCache.upsert(localNodeFromServerNode(node));
          }
          moved += updated.length;
        } on transport.HomeBoxApiException catch (e) {
          // Another device changed one of these nodes first; the next sync
          // pass brings the newer state and the next run retries it.
          if (e.code != 'REVISION_CONFLICT') rethrow;
        }
      }
    }
    return moved;
  }

  /// Every live node at or below [root] that is not yet encrypted with the
  /// folder's key, parents before children.
  List<LocalNode> _nodesOutsideScope(LocalNode root, String userId) {
    final result = <LocalNode>[];
    final pending = <LocalNode>[root];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final node = pending.removeAt(0);
      if (!visited.add(node.id)) continue;
      if (node.scopeOrOwner(userId) != root.id &&
          !node.pendingCreate &&
          !_syncEngine.pendingOperations.hasPendingOperationsForNode(node.id)) {
        result.add(node);
      }
      if (node.isDirectory) {
        pending.addAll(_syncEngine.nodeCache.listChildren(node.id));
      }
    }
    return result;
  }

  Future<transport.RekeyItem> _rekeyItem(
    transport.HomeBoxApiClient api,
    String accessToken,
    OwnerKeyRing keys,
    LocalNode node,
    String folderId,
  ) async {
    final nodeType = node.isDirectory
        ? MetadataNodeType.directory
        : MetadataNodeType.file;
    final nodeId = uuidStringToBytes(node.id);
    final envelope = EncryptedMetadataEnvelope.decode(node.metadataCiphertext);
    final source = await keys.key(
      node.scopeOrOwner(keys.userId),
      envelope.keyVersion,
    );
    final metadata = await _cipher.decrypt(
      envelope: envelope,
      metadataKey: source.key,
      nodeType: nodeType,
      scopeId: source.scopeIdBytes,
      nodeId: nodeId,
    );
    final target = await keys.current(folderId);
    final reencrypted = await _cipher.encrypt(
      metadata: metadata,
      metadataKey: target.key,
      keyVersion: target.version,
      nodeType: nodeType,
      scopeId: target.scopeIdBytes,
      nodeId: nodeId,
    );
    final versions = <transport.RekeyFileVersion>[];
    if (!node.isDirectory && node.currentVersionId != null) {
      for (final version in await api.listFileVersions(accessToken, node.id)) {
        if (version.keyScopeId == folderId) continue;
        versions.add(
          transport.RekeyFileVersion(
            id: version.id,
            wrappedFileKey: await rewrapFileKey(
              keys: keys,
              version: version,
              target: target,
            ),
            keyScopeId: target.scopeId,
            keyVersion: target.version,
          ),
        );
      }
    }
    return transport.RekeyItem(
      nodeId: node.id,
      expectedRevision: node.revision,
      metadataCiphertext: reencrypted.encode(),
      metadataKeyVersion: target.version,
      metadataKeyScopeId: target.scopeId,
      fileVersions: versions,
    );
  }
}
