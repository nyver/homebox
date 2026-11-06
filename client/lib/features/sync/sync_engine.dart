// Constructor parameters are named to give callers in other files readable
// arguments (`serverConnection:`, `localDatabase:`) instead of the backing
// private field names.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/e2ee/opaque_id.dart';
import '../../core/storage/favorites_store.dart';
import '../../core/storage/folder_keys_store.dart';
import '../../core/storage/local_database.dart';
import '../../core/storage/materialized_directories_store.dart';
import '../../core/storage/materialization_failures_store.dart';
import '../../core/storage/materialized_files_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/storage/pending_operations_store.dart';
import '../../core/storage/sync_conflicts_store.dart';
import '../../core/storage/sync_state_store.dart';
import '../../core/storage/trusted_accounts_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import 'outbox_conflict_resolver.dart';
import 'sync_conflict_log.dart';
import '../server/server_connection_controller.dart';
import '../../core/util/user_facing_error.dart';
import '../../core/transport/network_errors.dart';

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
  /// [conflictResolver] replays an outbox rename/move that lost a revision
  /// race when that is safe (spec §21). Without one, every such conflict
  /// keeps the server state and is reported in [conflicts].
  SyncEngine({
    required ServerConnectionController serverConnection,
    required LocalDatabase localDatabase,
    OutboxConflictResolver? conflictResolver,
  }) : _serverConnection = serverConnection,
       _localDatabase = localDatabase,
       _conflictResolver = conflictResolver,
       nodeCache = NodeCache(localDatabase.db),
       folderKeys = FolderKeysStore(localDatabase.db),
       favorites = FavoritesStore(localDatabase.db),
       trustedAccounts = TrustedAccountsStore(localDatabase.db),
       pendingOperations = PendingOperationsStore(localDatabase.db),
       materializedDirectories = MaterializedDirectoriesStore(localDatabase.db),
       materializationFailures = MaterializationFailuresStore(localDatabase.db),
       materializedFiles = MaterializedFilesStore(localDatabase.db),
       conflicts = SyncConflictLog(SyncConflictsStore(localDatabase.db)),
       _syncState = SyncStateStore(localDatabase.db) {
    _connectionWasAuthenticated =
        serverConnection.status == ServerConnectionStatus.authenticated;
    _serverConnection.addListener(_onServerConnectionChanged);
  }

  final ServerConnectionController _serverConnection;
  final LocalDatabase _localDatabase;
  final OutboxConflictResolver? _conflictResolver;
  final NodeCache nodeCache;

  /// This account's shared-folder keys, still wrapped by its Vault Key,
  /// refreshed from the server on every pass (ADR-023).
  final FolderKeysStore folderKeys;

  /// This account's favorite node IDs, refreshed from the server on every
  /// pass (spec §29).
  final FavoritesStore favorites;

  /// Family members whose account identity the user verified on this
  /// device, for Family Vault sharing.
  final TrustedAccountsStore trustedAccounts;
  final PendingOperationsStore pendingOperations;
  final MaterializedDirectoriesStore materializedDirectories;
  final MaterializationFailuresStore materializationFailures;
  final MaterializedFilesStore materializedFiles;

  /// Conflicts resolved on this device, shared with the sync-folder
  /// components so the Sync page can list them all in one place.
  final SyncConflictLog conflicts;
  final SyncStateStore _syncState;

  /// How many times one pass re-resolves the same operation's revision
  /// conflict before giving up on it (another device keeps winning the race).
  static const int _maxConflictRebasesPerPass = 3;

  Timer? _timer;
  Duration _interval = const Duration(seconds: 30);
  bool _started = false;
  bool _paused = false;
  bool _runningNow = false;
  Future<void>? _inFlight;

  /// The pass queued to start once [_inFlight] finishes; see [runOnce].
  Future<void>? _followUp;
  bool _disposed = false;
  bool _connectionWasAuthenticated = false;
  SyncStatus _status = SyncStatus.idle;
  String? _errorMessage;
  DateTime? _lastSyncedAt;

  SyncStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get isPaused => _paused;

  /// When the last pass completed successfully on this run of the app, so
  /// the user can tell "up to date" from "up to date as of yesterday".
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// Local changes not yet pushed to the server.
  int get pendingChangeCount => pendingOperations.unfinishedOperationCount;

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
    // A tick during a long pass is simply skipped: nothing new was queued,
    // so it must not chain a follow-up pass the way runOnce() does.
    _timer = Timer.periodic(_interval, (_) {
      if (_inFlight == null) unawaited(runOnce());
    });
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
  /// concurrently — a run already in flight is not duplicated. A call that
  /// arrives mid-run instead schedules one follow-up pass right after it
  /// (shared by every such call), because whatever the caller just queued
  /// may have missed the running pass's outbox snapshot; without it, an
  /// Undo or edit made during a pass would wait for the next periodic tick,
  /// while that pass's pull briefly showed the stale server state. The
  /// returned future completes once that follow-up has finished too (e.g.
  /// so pull-to-refresh genuinely waits for fresh data).
  Future<void> runOnce() {
    // Checked before _paused: pause() only cancels the timer, it does not
    // interrupt a run already underway (see its doc comment), so a caller
    // arriving after a pause mid-run must still await that real pass
    // rather than getting an instantly-resolved future while it's still
    // pulling changes in the background. The follow-up itself is a no-op
    // once paused.
    final inFlight = _inFlight;
    if (inFlight != null) {
      return _followUp ??= inFlight.then((_) {
        _followUp = null;
        return _disposed ? null : runOnce();
      });
    }
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
      await _pushPending(api, session.accessToken, session.user.id);
      await _pullChanges(api, session.accessToken, session.user.id);
      await _refreshFolderKeys(api, session.accessToken);
      await _refreshFavorites(api, session.accessToken);
      _errorMessage = null;
      _lastSyncedAt = DateTime.now().toUtc();
      if (!_paused) _setStatus(SyncStatus.idle);
    } catch (e) {
      if (isTransientNetworkError(e)) {
        // A timeout, offline Wi-Fi, a stalled connection, or a temporarily
        // unreachable server is an expected mobile-network condition. Keep
        // the outbox intact and let the periodic pass retry rather than
        // presenting it as a sync failure.
        _errorMessage = 'Cannot reach the HomeBox server. Check the network and server address.';
        if (!_paused) _setStatus(SyncStatus.offline);
      } else {
        _errorMessage = describeError(e);
        if (!_paused) _setStatus(SyncStatus.error);
      }
    } finally {
      _runningNow = false;
      _inFlight = null;
    }
  }

  Future<void> _pushPending(
    transport.HomeBoxApiClient api,
    String accessToken,
    String scopeId,
  ) async {
    for (final snapshot in pendingOperations.listReady(DateTime.now())) {
      // Re-read: an operation earlier in this pass may have rebased this one
      // onto the revision it produced (see _pushOne).
      final op = pendingOperations.getById(snapshot.id);
      if (op == null || op.status != PendingOperationStatus.pending) continue;
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
      final parentId = op.type == PendingOperationType.restoreNode
          ? nodeCache.getById(op.nodeId)?.parentId
          : null;
      if (parentId != null &&
          pendingOperations.hasUnfinishedRestoreForNode(parentId)) {
        // The server restores a node whose folder is still in Trash to the
        // root, so a parent folder's own restore must land first. A parent
        // restore that failed permanently no longer blocks this one.
        continue;
      }
      await _pushOne(api, accessToken, scopeId, op);
    }
  }

  Future<void> _pushOne(
    transport.HomeBoxApiClient api,
    String accessToken,
    String scopeId,
    PendingOperation queued,
  ) async {
    // Later operations on this node were queued on top of the revision this
    // one started from — locally a node keeps its last server revision until
    // its own mutation is pushed.
    final queuedOnRevision = queued.baseRevision ?? 0;
    var op = queued;
    pendingOperations.markRunning(op.id);
    for (var rebases = 0; ; rebases++) {
      try {
        final revision = switch (op.type) {
          PendingOperationType.createNode => await _applyCreate(
            api,
            accessToken,
            op,
          ),
          PendingOperationType.updateNode => await _applyUpdate(
            api,
            accessToken,
            op,
          ),
          PendingOperationType.deleteNode => await _applyDelete(
            api,
            accessToken,
            op,
          ),
          PendingOperationType.restoreNode => await _applyRestore(
            api,
            accessToken,
            op,
          ),
        };
        pendingOperations.markDone(op.id);
        if (revision != null) {
          _rebaseLaterOperations(op, queuedOnRevision, revision);
        }
        return;
      } on transport.HomeBoxApiException catch (e) {
        if (e.code == 'REVISION_CONFLICT' &&
            (op.type == PendingOperationType.updateNode ||
                op.type == PendingOperationType.deleteNode)) {
          final PendingOperation? rebased;
          try {
            rebased = await _resolveRevisionConflict(
              api,
              accessToken,
              scopeId,
              op,
              queuedOnRevision: queuedOnRevision,
              mayRetry: rebases < _maxConflictRebasesPerPass,
            );
          } catch (resolutionError) {
            // Never leave the operation RUNNING: settle it like any other
            // failure (a transient error retries the whole conflict later).
            await _recordFailure(api, accessToken, op, resolutionError);
            return;
          }
          if (rebased == null) return;
          op = rebased;
          pendingOperations.markRunning(op.id);
          continue;
        }
        await _recordFailure(api, accessToken, op, e);
        return;
      } catch (e) {
        await _recordFailure(api, accessToken, op, e);
        return;
      }
    }
  }

  void _rebaseLaterOperations(
    PendingOperation op,
    int queuedOnRevision,
    int newRevision,
  ) {
    pendingOperations.rebaseLaterOperations(
      nodeId: op.nodeId,
      afterOperationId: op.id,
      createdAtOrAfter: op.createdAt,
      fromRevision: queuedOnRevision,
      toRevision: newRevision,
    );
  }

  /// Handles an UPDATE/DELETE the server rejected because the node changed
  /// on another device first (spec §21). Returns the rebased operation to
  /// retry right away, or null once the operation is settled: already
  /// satisfied, or kept as the server's state with the conflict reported.
  Future<PendingOperation?> _resolveRevisionConflict(
    transport.HomeBoxApiClient api,
    String accessToken,
    String scopeId,
    PendingOperation op, {
    required int queuedOnRevision,
    required bool mayRetry,
  }) async {
    final transport.NodeInfo server;
    try {
      server = await api.getNode(accessToken, op.nodeId);
    } catch (e) {
      await _recordFailure(api, accessToken, op, e);
      return null;
    }
    final resolver = _conflictResolver;
    if (op.type == PendingOperationType.deleteNode && server.isDeleted) {
      // Another device moved it to Trash first: the intent already holds.
      pendingOperations.markDone(op.id);
      nodeCache.upsert(localNodeFromServerNode(server));
      return null;
    }
    if (op.type == PendingOperationType.deleteNode) {
      // DELETE vs UPDATE/RENAME: never destroy the newer remote state.
      await _keepServerState(
        op,
        server,
        SyncConflictKind.deleteRejected,
        fileName: await resolver?.displayName(server: server, scopeId: scopeId),
      );
      return null;
    }
    final fallbackKind = (op.payload['moveParent'] as bool? ?? false)
        ? SyncConflictKind.moveRejected
        : SyncConflictKind.renameRejected;
    if (resolver == null || !mayRetry) {
      await _keepServerState(
        op,
        server,
        fallbackKind,
        fileName: await resolver?.displayName(server: server, scopeId: scopeId),
      );
      return null;
    }
    final resolution = await resolver.resolveUpdate(
      operation: op,
      server: server,
      scopeId: scopeId,
    );
    switch (resolution) {
      case RetryUpdate(:final payload):
        return pendingOperations.rebase(
          op.id,
          operationId: generateUuidV4(),
          payload: payload,
          baseRevision: server.revision,
        );
      case UpdateAlreadyApplied():
        pendingOperations.markDone(op.id);
        nodeCache.upsert(localNodeFromServerNode(server));
        _rebaseLaterOperations(op, queuedOnRevision, server.revision);
        return null;
      case UpdateConflicts(:final kind, :final fileName):
        await _keepServerState(op, server, kind, fileName: fileName);
        return null;
    }
  }

  /// Settles [op] as FAILED in favor of the server's state and reports the
  /// conflict. The optimistic local change is replaced by [server] so the
  /// Files page and sync folder show what actually exists.
  Future<void> _keepServerState(
    PendingOperation op,
    transport.NodeInfo server,
    SyncConflictKind kind, {
    String? fileName,
  }) async {
    pendingOperations.markFailed(op.id, errorCode: 'REVISION_CONFLICT');
    nodeCache.upsert(localNodeFromServerNode(server));
    conflicts.record(kind: kind, nodeId: op.nodeId, fileName: fileName);
  }

  /// Each `_apply*` returns the node revision its own mutation produced, so
  /// later queued operations on the same node can be rebased onto it.
  Future<int?> _applyCreate(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
  ) async {
    final payload = op.payload;
    final created = await api.createNode(
      accessToken,
      id: op.nodeId,
      operationId: op.operationId,
      parentId: payload['parentId'] as String?,
      nodeType: payload['nodeType'] as String,
      metadataCiphertext: base64Decode(payload['metadataCiphertext'] as String),
      metadataKeyVersion: payload['metadataKeyVersion'] as int,
      metadataKeyScopeId: payload[metadataScopePayloadKey] as String?,
    );
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
    return created.revision;
  }

  Future<int?> _applyUpdate(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
  ) async {
    final payload = op.payload;
    final metadataCiphertextB64 = payload['metadataCiphertext'] as String?;
    final updated = await api.updateNode(
      accessToken,
      op.nodeId,
      operationId: op.operationId,
      expectedRevision: op.baseRevision ?? 0,
      metadataCiphertext: metadataCiphertextB64 != null
          ? base64Decode(metadataCiphertextB64)
          : null,
      metadataKeyVersion: payload['metadataKeyVersion'] as int? ?? 1,
      metadataKeyScopeId: payload[metadataScopePayloadKey] as String?,
      moveParent: payload['moveParent'] as bool? ?? false,
      parentId: payload['parentId'] as String?,
    );
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
    return updated.revision;
  }

  Future<int?> _applyDelete(
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
    return nodeCache.getById(op.nodeId)?.revision;
  }

  Future<int?> _applyRestore(
    transport.HomeBoxApiClient api,
    String accessToken,
    PendingOperation op,
  ) async {
    final restored = await api.restoreNode(
      accessToken,
      op.nodeId,
      operationId: op.operationId,
    );
    await _refreshNodeFromServer(api, accessToken, op.nodeId);
    return restored.revision;
  }

  /// Optimistically moves an integrity-failed immutable file version to
  /// Trash and durably queues the server mutation. This is deliberately a
  /// soft delete: normal server retention remains responsible for eventual
  /// blob removal, so an operator can still recover the node.
  Future<bool> trashAfterIntegrityFailure(LocalNode snapshot) async {
    final current = nodeCache.getById(snapshot.id);
    if (current == null || current.isDeleted) return true;
    if (current.revision != snapshot.revision ||
        current.currentVersionId != snapshot.currentVersionId) {
      return false;
    }
    final now = DateTime.now().toUtc();
    nodeCache.upsert(current.copyWith(updatedAt: now, deletedAt: now));
    final operation = PendingOperation(
      id: generateUuidV4(),
      operationId: generateUuidV4(),
      type: PendingOperationType.deleteNode,
      nodeId: current.id,
      payload: const {},
      baseRevision: current.revision,
      createdAt: now,
      retryCount: 0,
      status: PendingOperationStatus.pending,
    );
    pendingOperations.enqueue(operation);
    await runOnce();
    return pendingOperations.getById(operation.id)?.status !=
        PendingOperationStatus.failed;
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
      // A refresh reads the node's *current* state, so a node changed several
      // times within one page (create, rename, new versions, ...) needs only
      // one request. This matters most on a fresh device replaying the whole
      // history from revision 0.
      final changedNodeIds = <String>{
        for (final change in page.changes)
          if (change.nodeId != null) change.nodeId!,
      };
      for (final nodeId in changedNodeIds) {
        // A mutation queued after this pass's push phase started (e.g. Move
        // to Trash while a pass was in flight) is applied optimistically in
        // the cache only. Overwriting it with the server's older state would
        // resurrect the node until the next pass, and the sync folder would
        // download it again. Its own push refreshes the node afterwards.
        if (!pendingOperations.hasPendingOperationsForNode(nodeId)) {
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

  /// Mirrors the account's wrapped folder keys so shared folders can be
  /// used offline and new content lands in the right key scope. A server
  /// that predates Family Vault folder keys answers 404, which simply
  /// means there are none.
  Future<void> _refreshFolderKeys(
    transport.HomeBoxApiClient api,
    String accessToken,
  ) async {
    try {
      folderKeys.mergeAll(await api.listFolderKeys(accessToken));
    } on transport.HomeBoxApiException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
  }

  /// Mirrors the server's favorites. A local change made while the list
  /// was in flight wins until the next pass. A server that predates
  /// favorites answers 404, which means there are none.
  Future<void> _refreshFavorites(
    transport.HomeBoxApiClient api,
    String accessToken,
  ) async {
    final generation = favorites.generation;
    try {
      favorites.replaceAllIfUnchanged(
        await api.listFavorites(accessToken),
        generation,
      );
    } on transport.HomeBoxApiException catch (e) {
      if (e.statusCode != 404) rethrow;
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
    conflicts.dispose();
    _localDatabase.dispose();
    super.dispose();
  }
}
