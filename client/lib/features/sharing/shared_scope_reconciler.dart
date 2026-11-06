// ignore_for_file: prefer_initializing_formals
import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/scoped_metadata.dart';
import '../../core/storage/node_cache.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/transport/network_errors.dart';
import '../files/file_transfer.dart' show rewrapFileKey;
import '../sync/sync_engine.dart';

/// What one reconciliation pass did.
final class ReconcileResult {
  const ReconcileResult({required this.moved, required this.skipped});

  /// Nodes moved into their shared folder's key scope.
  final int moved;

  /// Nodes that could not be moved this time (for example metadata this
  /// device cannot decrypt); members cannot read them until they are.
  final int skipped;
}

/// Moves content below a shared folder into that folder's key scope
/// (ADR-023). A folder's subtree must be readable with its Folder Key
/// before members can use it, and anything later moved or uploaded into it
/// with the owner's personal Vault Key must follow. Each node's metadata is
/// re-encrypted and every File DEK of every version rewrapped on this
/// device; the server only swaps ciphertext and never sees a key.
///
/// Idempotent and safe to run after every sync pass: nodes already in the
/// right scope are skipped, nodes with a queued local change wait for it, a
/// batch that loses a revision race is retried next time, and one node that
/// cannot be moved never holds up the others.
final class SharedScopeReconciler {
  SharedScopeReconciler({required SyncEngine syncEngine})
    : _syncEngine = syncEngine;

  final SyncEngine _syncEngine;

  /// Nodes per rekey request; well below the server's limit of 200.
  static const int batchSize = 50;

  /// The server's limit of rewrapped versions per node.
  static const int _maxVersionsPerNode = 256;

  /// Live nodes at or below each folder in [folderIds] that are not yet
  /// encrypted with that folder's key, parents before children. Reads only
  /// the local cache and needs no key, so a caller can skip opening the key
  /// ring when there is nothing to do.
  Map<String, List<LocalNode>> staleNodes({
    required String userId,
    required Iterable<String> folderIds,
  }) {
    final busy = _syncEngine.pendingOperations
        .nodeIdsWithUnfinishedOperations();
    final result = <String, List<LocalNode>>{};
    for (final folderId in folderIds) {
      final root = _syncEngine.nodeCache.getById(folderId);
      if (root == null || root.isDeleted || !root.isDirectory) continue;
      final stale = <LocalNode>[];
      final queue = <LocalNode>[root];
      final visited = <String>{};
      for (var i = 0; i < queue.length; i++) {
        final node = queue[i];
        if (!visited.add(node.id)) continue;
        if (node.scopeOrOwner(userId) != folderId &&
            !node.pendingCreate &&
            !busy.contains(node.id)) {
          stale.add(node);
        }
        if (node.isDirectory) {
          queue.addAll(_syncEngine.nodeCache.listChildren(node.id));
        }
      }
      if (stale.isNotEmpty) result[folderId] = stale;
    }
    return result;
  }

  /// Rekeys every stale node below the shared folders in [folderIds] (all
  /// of this account's shared folders when null). Network failures stop the
  /// pass and are rethrown; anything wrong with a single node only skips it.
  Future<ReconcileResult> reconcile({
    required transport.HomeBoxApiClient api,
    required String accessToken,
    required OwnerKeyRing keys,
    Iterable<String>? folderIds,
  }) async {
    var moved = 0;
    var skipped = 0;
    final stale = staleNodes(
      userId: keys.userId,
      folderIds: (folderIds ?? keys.keyedFolderIds).toList(),
    );
    for (final MapEntry(key: folderId, value: nodes) in stale.entries) {
      for (var start = 0; start < nodes.length; start += batchSize) {
        final items = <transport.RekeyItem>[];
        for (final node in nodes.skip(start).take(batchSize)) {
          try {
            items.add(await _rekeyItem(api, accessToken, keys, node, folderId));
          } catch (e) {
            if (isTransientNetworkError(e)) rethrow;
            skipped++;
          }
        }
        if (items.isEmpty) continue;
        final result = await _send(api, accessToken, items);
        moved += result.moved;
        skipped += result.skipped;
      }
    }
    return ReconcileResult(moved: moved, skipped: skipped);
  }

  /// Sends one batch. A batch the server rejects as a whole for a reason
  /// other than a revision race is retried node by node, so one bad item
  /// cannot block the rest.
  Future<ReconcileResult> _send(
    transport.HomeBoxApiClient api,
    String accessToken,
    List<transport.RekeyItem> items,
  ) async {
    try {
      final updated = await api.rekeyNodes(accessToken, items);
      for (final node in updated) {
        _syncEngine.nodeCache.upsert(localNodeFromServerNode(node));
      }
      return ReconcileResult(moved: updated.length, skipped: 0);
    } on transport.HomeBoxApiException catch (e) {
      // Another device changed one of these nodes first; the next sync
      // pass brings the newer state and the next run retries it.
      if (e.code == 'REVISION_CONFLICT') {
        return const ReconcileResult(moved: 0, skipped: 0);
      }
      if (items.length == 1) {
        return const ReconcileResult(moved: 0, skipped: 1);
      }
      var moved = 0;
      var skipped = 0;
      for (final item in items) {
        final result = await _send(api, accessToken, [item]);
        moved += result.moved;
        skipped += result.skipped;
      }
      return ReconcileResult(moved: moved, skipped: skipped);
    }
  }

  Future<transport.RekeyItem> _rekeyItem(
    transport.HomeBoxApiClient api,
    String accessToken,
    OwnerKeyRing keys,
    LocalNode node,
    String folderId,
  ) async {
    final metadata = await decryptNodeMetadata(
      keys: keys,
      ciphertext: node.metadataCiphertext,
      scopeId: node.scopeOrOwner(keys.userId),
      isDirectory: node.isDirectory,
      nodeId: node.id,
    );
    final target = await keys.current(folderId);
    final versions = <transport.RekeyFileVersion>[];
    if (!node.isDirectory && node.currentVersionId != null) {
      final stored = await api.listFileVersions(accessToken, node.id);
      if (stored.length > _maxVersionsPerNode) {
        throw StateError('Too many versions to move in one request.');
      }
      for (final version in stored) {
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
      metadataCiphertext: await encryptNodeMetadata(
        key: target,
        metadata: metadata,
        isDirectory: node.isDirectory,
        nodeId: node.id,
      ),
      metadataKeyVersion: target.version,
      metadataKeyScopeId: target.scopeId,
      fileVersions: versions,
    );
  }
}
