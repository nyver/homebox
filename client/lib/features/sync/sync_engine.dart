// Constructor parameters are named to give callers in other files readable
// arguments (`serverConnection:`, `localDatabase:`) instead of the backing
// private field names.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/local_database.dart';
import '../../core/storage/materialized_files_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/storage/sync_state_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../server/server_connection_controller.dart';

enum SyncStatus { idle, syncing, offline, error }

/// Error codes a retry can never fix — the operation was rejected on its
/// merits, not because of a transient network/server problem (spec §19.5:
/// "Permanent error переводит operation в BLOCKED или FAILED").
const Set<String> _permanentFailureCodes = {
  'VALIDATION_ERROR',
  'FORBIDDEN',
  'NOT_FOUND',
  'REVISION_CONFLICT',
  'AUTH_INVALID_CREDENTIALS',
};

/// Reconciles the local outbox/cache with the server: pushes durable
/// [PendingOperation]s (spec §19.4 steps A-D) and pulls the sync revision
/// feed to keep [NodeCache] current (steps E-I). This is the only place
/// that talks to `/api/v1/nodes*` / `/api/v1/sync/changes` for metadata
/// mutations — everything else (FilesController) reads/writes the local
/// cache and outbox, which is what makes offline use possible at all.
///
/// Takes ownership of [localDatabase]: [dispose] closes it, so callers must
/// not also close it themselves or use it after disposing this engine.
final class SyncEngine extends ChangeNotifier {
  SyncEngine({required ServerConnectionController serverConnection, required LocalDatabase localDatabase})
      : _serverConnection = serverConnection,
        _localDatabase = localDatabase,
        nodeCache = NodeCache(localDatabase.db),
        pendingOperations = PendingOperationsStore(localDatabase.db),
        materializedFiles = MaterializedFilesStore(localDatabase.db),
        _syncState = SyncStateStore(localDatabase.db);

  final ServerConnectionController _serverConnection;
  final LocalDatabase _localDatabase;
  final NodeCache nodeCache;
  final PendingOperationsStore pendingOperations;
  final MaterializedFilesStore materializedFiles;
  final SyncStateStore _syncState;

  Timer? _timer;
  bool _runningNow = false;
  bool _disposed = false;
  SyncStatus _status = SyncStatus.idle;
  String? _errorMessage;

  SyncStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// Starts periodic background syncing and runs one pass immediately.
  void start({Duration interval = const Duration(seconds: 30)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(runOnce()));
    unawaited(runOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Pushes pending operations, then pulls remote changes. Safe to call
  /// concurrently — a run already in flight is not duplicated.
  Future<void> runOnce() async {
    if (_runningNow) return;
    final api = _serverConnection.api;
    final session = _serverConnection.session;
    if (api == null || session == null) {
      _setStatus(SyncStatus.offline);
      return;
    }
    _runningNow = true;
    _setStatus(SyncStatus.syncing);
    try {
      await _pushPending(api, session.accessToken);
      await _pullChanges(api, session.accessToken, session.user.id);
      _errorMessage = null;
      _setStatus(SyncStatus.idle);
    } catch (e) {
      _errorMessage = '$e';
      _setStatus(SyncStatus.error);
    } finally {
      _runningNow = false;
    }
  }

  Future<void> _pushPending(transport.HomeBoxApiClient api, String accessToken) async {
    for (final op in pendingOperations.listReady(DateTime.now())) {
      if (op.type != PendingOperationType.createNode &&
          pendingOperations.hasEarlierUnfinishedOperationForNode(op.nodeId, op.createdAt)) {
        // An earlier operation on the same node (almost always its own
        // CREATE) hasn't finished yet; wait for it rather than risk
        // reordering into a mutation on a node the server doesn't have.
        continue;
      }
      pendingOperations.markRunning(op.id);
      try {
        switch (op.type) {
          case PendingOperationType.createNode:
            await _applyCreate(api, accessToken, op);
          case PendingOperationType.updateNode:
            await _applyUpdate(api, accessToken, op);
          case PendingOperationType.deleteNode:
            await _applyDelete(api, accessToken, op);
          case PendingOperationType.restoreNode:
            await _applyRestore(api, accessToken, op);
        }
        pendingOperations.markDone(op.id);
      } catch (e) {
        _recordFailure(op, e);
      }
    }
  }

  Future<void> _applyCreate(transport.HomeBoxApiClient api, String accessToken, PendingOperation op) async {
    final payload = op.payload;
    await api.createNode(
      accessToken,
      id: op.nodeId,
      operationId: op.operationId,
      parentId: payload['parentId'] as String?,
      nodeType: payload['nodeType'] as String,
      metadataCiphertext: base64Decode(payload['metadataCiphertext'] as String),
      metadataKeyVersion: payload['metadataKeyVersion'] as int,
    );
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
  }

  Future<void> _applyUpdate(transport.HomeBoxApiClient api, String accessToken, PendingOperation op) async {
    final payload = op.payload;
    final metadataCiphertextB64 = payload['metadataCiphertext'] as String?;
    await api.updateNode(
      accessToken,
      op.nodeId,
      operationId: op.operationId,
      expectedRevision: op.baseRevision ?? 0,
      metadataCiphertext: metadataCiphertextB64 != null ? base64Decode(metadataCiphertextB64) : null,
      metadataKeyVersion: payload['metadataKeyVersion'] as int? ?? 1,
      moveParent: payload['moveParent'] as bool? ?? false,
      parentId: payload['parentId'] as String?,
    );
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
  }

  Future<void> _applyDelete(transport.HomeBoxApiClient api, String accessToken, PendingOperation op) async {
    await api.deleteNode(accessToken, op.nodeId, operationId: op.operationId, expectedRevision: op.baseRevision ?? 0);
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
  }

  Future<void> _applyRestore(transport.HomeBoxApiClient api, String accessToken, PendingOperation op) async {
    await api.restoreNode(accessToken, op.nodeId, operationId: op.operationId);
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
  }

  void _recordFailure(PendingOperation op, Object error) {
    final code = error is transport.HomeBoxApiException ? error.code : null;
    if (code != null && _permanentFailureCodes.contains(code)) {
      pendingOperations.markFailed(op.id, errorCode: code);
      return;
    }
    final retryCount = op.retryCount + 1;
    pendingOperations.markRetry(
      op.id,
      retryCount: retryCount,
      nextRetryAt: DateTime.now().add(Duration(seconds: _backoffSeconds(retryCount))),
      errorCode: code ?? error.runtimeType.toString(),
    );
  }

  /// 1s, 2s, 4s, 8s, 16s, ... capped at 5 minutes (spec §19.5's example
  /// sequence), plus a little jitter so many devices don't retry in lockstep.
  int _backoffSeconds(int retryCount) {
    final exponential = 1 << retryCount.clamp(0, 8);
    final capped = exponential.clamp(1, 300);
    final jitter = (capped * 0.2 * (DateTime.now().microsecond / 1000000)).round();
    return capped + jitter;
  }

  Future<void> _pullChanges(transport.HomeBoxApiClient api, String accessToken, String serverScopeId) async {
    var after = _syncState.lastSyncRevision(serverScopeId);
    while (true) {
      final page = await api.syncChanges(accessToken, after: after, pageSize: 200);
      for (final change in page.changes) {
        final nodeId = change.nodeId;
        if (nodeId != null) {
          await _refreshNodeFromServer(api, accessToken, nodeId, allowMissing: true);
        }
      }
      if (page.changes.isNotEmpty) {
        after = page.nextAfter;
        _syncState.advance(serverScopeId, after);
      }
      if (!page.hasMore) break;
    }
  }

  Future<void> _refreshNodeFromServer(
    transport.HomeBoxApiClient api,
    String accessToken,
    String nodeId, {
    bool allowMissing = false,
  }) async {
    try {
      final node = await api.getNode(accessToken, nodeId);
      nodeCache.upsert(_toLocalNode(node));
    } on transport.HomeBoxApiException catch (e) {
      if (allowMissing && (e.code == 'NOT_FOUND' || e.code == 'FORBIDDEN')) {
        nodeCache.remove(nodeId);
        return;
      }
      rethrow;
    }
  }

  LocalNode _toLocalNode(transport.NodeInfo node) => LocalNode(
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
      );

  void _setStatus(SyncStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _localDatabase.dispose();
    super.dispose();
  }
}
