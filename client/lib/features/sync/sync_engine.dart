// Constructor parameters are named to give callers in other files readable
// arguments (`serverConnection:`, `localDatabase:`) instead of the backing
// private field names.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/storage/local_database.dart';
import '../../core/storage/materialized_directories_store.dart';
import '../../core/storage/materialization_failures_store.dart';
import '../../core/storage/materialized_files_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/storage/sync_state_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../server/server_connection_controller.dart';

enum SyncStatus { idle, syncing, paused, offline, error }

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
  SyncEngine({
    required ServerConnectionController serverConnection,
    required LocalDatabase localDatabase,
  }) : _serverConnection = serverConnection,
       _localDatabase = localDatabase,
       nodeCache = NodeCache(localDatabase.db),
       pendingOperations = PendingOperationsStore(localDatabase.db),
       materializedDirectories = MaterializedDirectoriesStore(localDatabase.db),
       materializationFailures = MaterializationFailuresStore(localDatabase.db),
       materializedFiles = MaterializedFilesStore(localDatabase.db),
       _syncState = SyncStateStore(localDatabase.db) {
    _connectionWasAuthenticated =
        serverConnection.status == ServerConnectionStatus.authenticated;
    _serverConnection.addListener(_onServerConnectionChanged);
  }

  final ServerConnectionController _serverConnection;
  final LocalDatabase _localDatabase;
  final NodeCache nodeCache;
  final PendingOperationsStore pendingOperations;
  final MaterializedDirectoriesStore materializedDirectories;
  final MaterializationFailuresStore materializationFailures;
  final MaterializedFilesStore materializedFiles;
  final SyncStateStore _syncState;

  Timer? _timer;
  Duration _interval = const Duration(seconds: 30);
  bool _started = false;
  bool _paused = false;
  bool _runningNow = false;
  Future<void>? _inFlight;
  bool _disposed = false;
  bool _connectionWasAuthenticated = false;
  SyncStatus _status = SyncStatus.idle;
  String? _errorMessage;

  SyncStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get isPaused => _paused;

  /// Starts periodic background syncing and runs one pass immediately.
  void start({Duration interval = const Duration(seconds: 30)}) {
    _interval = interval;
    _started = true;
    _scheduleIfActive();
  }

  /// Stops new sync passes without interrupting an in-flight network write.
  /// Resume later starts a fresh pass and retains the local outbox/cache.
  void pause() {
    if (_paused) return;
    _paused = true;
    _timer?.cancel();
    _timer = null;
    _setStatus(SyncStatus.paused);
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _scheduleIfActive();
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleIfActive() {
    _timer?.cancel();
    _timer = null;
    if (!_started || _paused) {
      if (_paused && !_runningNow) _setStatus(SyncStatus.paused);
      return;
    }
    _timer = Timer.periodic(_interval, (_) => unawaited(runOnce()));
    unawaited(runOnce());
  }

  /// The engine can be created while the persisted refresh-token exchange is
  /// still in flight. Its initial pass correctly reports Offline then, but
  /// waiting for the periodic timer after authentication makes the header
  /// look disconnected for up to one interval. Start a pass immediately
  /// when the connection becomes usable instead.
  void _onServerConnectionChanged() {
    final authenticated =
        _serverConnection.status == ServerConnectionStatus.authenticated;
    final justAuthenticated = authenticated && !_connectionWasAuthenticated;
    _connectionWasAuthenticated = authenticated;
    if (justAuthenticated && _started && !_paused) {
      unawaited(runOnce());
    }
  }

  /// Pushes pending operations, then pulls remote changes. Safe to call
  /// concurrently — a run already in flight is not duplicated, but every
  /// caller's returned future still only completes once that shared run
  /// actually finishes (e.g. so pull-to-refresh genuinely waits for it,
  /// rather than the second caller seeing an instant no-op).
  Future<void> runOnce() {
    // Checked before _paused: pause() only cancels the timer, it does not
    // interrupt a run already underway (see its doc comment), so a caller
    // arriving after a pause mid-run must still await that real pass
    // rather than getting an instantly-resolved future while it's still
    // pulling changes in the background.
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    if (_paused) {
      _setStatus(SyncStatus.paused);
      return Future<void>.value();
    }
    final api = _serverConnection.api;
    if (api == null ||
        (_serverConnection.session == null &&
            !_serverConnection.hasSavedRefreshToken)) {
      _setStatus(SyncStatus.offline);
      return Future<void>.value();
    }
    // Assigning _inFlight here, synchronously (invoking an async function
    // returns its Future immediately, before the function body reaches its
    // first await), is what lets a concurrent runOnce() call above see it
    // non-null and share this same pass instead of racing to start a
    // second one.
    return _inFlight = _runOnce(api);
  }

  Future<void> _runOnce(transport.HomeBoxApiClient api) async {
    _runningNow = true;
    _setStatus(SyncStatus.syncing);
    try {
      // Refreshed here rather than trusting the session read in runOnce():
      // mobile OSes can suspend a backgrounded app's Dart timers, so the
      // proactive refresh timer (ServerConnectionController) does not
      // reliably fire while HomeBox sits in the background — without this,
      // a sync pass run right after returning from a long background spell
      // would hit a stale-token 401 (AUTH_TOKEN_EXPIRED) instead.
      final session = await _serverConnection.ensureFreshSession();
      if (session == null) {
        _setStatus(SyncStatus.offline);
        return;
      }
      await _pushPending(api, session.accessToken);
      await _pullChanges(api, session.accessToken, session.user.id);
      _errorMessage = null;
      if (!_paused) _setStatus(SyncStatus.idle);
    } on SocketException {
      // A timeout, offline Wi-Fi, or a temporarily unreachable server is an
      // expected mobile-network condition. Keep the outbox intact and let the
      // periodic pass retry rather than presenting it as a sync failure.
      _errorMessage = 'Cannot reach the HomeBox server. Check the network and server address.';
      if (!_paused) _setStatus(SyncStatus.offline);
    } catch (e) {
      _errorMessage = '$e';
      if (!_paused) _setStatus(SyncStatus.error);
    } finally {
      _runningNow = false;
      _inFlight = null;
    }
  }

  Future<void> _pushPending(
    transport.HomeBoxApiClient api,
    String accessToken,
  ) async {
    for (final op in pendingOperations.listReady(DateTime.now())) {
      if (op.type != PendingOperationType.createNode &&
          pendingOperations.hasEarlierUnfinishedOperationForNode(
            op.nodeId,
            op.createdAt,
          )) {
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
        await _recordFailure(api, accessToken, op, e);
      }
    }
  }

  Future<void> _applyCreate(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
  ) async {
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

  Future<void> _applyUpdate(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
  ) async {
    final payload = op.payload;
    final metadataCiphertextB64 = payload['metadataCiphertext'] as String?;
    await api.updateNode(
      accessToken,
      op.nodeId,
      operationId: op.operationId,
      expectedRevision: op.baseRevision ?? 0,
      metadataCiphertext: metadataCiphertextB64 != null
          ? base64Decode(metadataCiphertextB64)
          : null,
      metadataKeyVersion: payload['metadataKeyVersion'] as int? ?? 1,
      moveParent: payload['moveParent'] as bool? ?? false,
      parentId: payload['parentId'] as String?,
    );
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
  }

  Future<void> _applyDelete(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
  ) async {
    await api.deleteNode(
      accessToken,
      op.nodeId,
      operationId: op.operationId,
      expectedRevision: op.baseRevision ?? 0,
    );
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
  }

  Future<void> _applyRestore(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
  ) async {
    await api.restoreNode(accessToken, op.nodeId, operationId: op.operationId);
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
  }

  Future<void> _recordFailure(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
    Object error,
  ) async {
    final code = error is transport.HomeBoxApiException ? error.code : null;
    if (code != null && _permanentFailureCodes.contains(code)) {
      pendingOperations.markFailed(op.id, errorCode: code);
      try {
        // The Files UI applies mutations optimistically. If the server
        // permanently rejects one (especially a stale-revision delete),
        // restore the authoritative node instead of leaving it hidden only
        // in this device's cache while background materialization still sees
        // it after the next cache rebuild.
        await _refreshNodeFromServer(
          api,
          accessToken,
          op.nodeId,
          allowMissing: true,
        );
      } catch (_) {
        // The operation is already durably FAILED. A later pull can still
        // reconcile the cache if this best-effort refresh cannot run now.
      }
      return;
    }
    final retryCount = op.retryCount + 1;
    pendingOperations.markRetry(
      op.id,
      retryCount: retryCount,
      nextRetryAt: DateTime.now().add(
        Duration(seconds: _backoffSeconds(retryCount)),
      ),
      errorCode: code ?? error.runtimeType.toString(),
    );
  }

  /// 1s, 2s, 4s, 8s, 16s, ... capped at 5 minutes (spec §19.5's example
  /// sequence), plus a little jitter so many devices don't retry in lockstep.
  int _backoffSeconds(int retryCount) {
    final exponential = 1 << retryCount.clamp(0, 8);
    final capped = exponential.clamp(1, 300);
    final jitter = (capped * 0.2 * (DateTime.now().microsecond / 1000000))
        .round();
    return capped + jitter;
  }

  Future<void> _pullChanges(
    transport.HomeBoxApiClient api,
    String accessToken,
    String serverScopeId,
  ) async {
    var after = _syncState.lastSyncRevision(serverScopeId);
    while (true) {
      final page = await api.syncChanges(
        accessToken,
        after: after,
        pageSize: 200,
      );
      for (final change in page.changes) {
        final nodeId = change.nodeId;
        if (nodeId != null) {
          await _refreshNodeFromServer(
            api,
            accessToken,
            nodeId,
            allowMissing: true,
          );
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
      nodeCache.upsert(localNodeFromServerNode(node));
    } on transport.HomeBoxApiException catch (e) {
      if (allowMissing && (e.code == 'NOT_FOUND' || e.code == 'FORBIDDEN')) {
        nodeCache.remove(nodeId);
        return;
      }
      rethrow;
    }
  }

  void _setStatus(SyncStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _serverConnection.removeListener(_onServerConnectionChanged);
    _localDatabase.dispose();
    super.dispose();
  }
}
