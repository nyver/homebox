import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

enum PendingOperationType {
  createNode('CREATE_NODE'),
  updateNode('UPDATE_NODE'),
  deleteNode('DELETE_NODE'),
  restoreNode('RESTORE_NODE');

  const PendingOperationType(this.wireValue);
  final String wireValue;

  static PendingOperationType fromWire(String value) =>
      values.firstWhere((v) => v.wireValue == value, orElse: () => throw FormatException('Unknown operation type: $value'));
}

enum PendingOperationStatus {
  pending('PENDING'),
  running('RUNNING'),
  blocked('BLOCKED'),
  done('DONE'),
  failed('FAILED');

  const PendingOperationStatus(this.wireValue);
  final String wireValue;

  static PendingOperationStatus fromWire(String value) =>
      values.firstWhere((v) => v.wireValue == value, orElse: () => throw FormatException('Unknown operation status: $value'));
}

/// One durable outbox entry (spec §13.1): a mutation recorded locally
/// before (or instead of, while offline) it reaches the server. `payload`
/// carries whatever fields that specific [type] needs to replay the call;
/// see `SyncEngine._payloadFor*`/`_apply*` for the shape each type expects.
final class PendingOperation {
  const PendingOperation({
    required this.id,
    required this.operationId,
    required this.type,
    required this.nodeId,
    required this.payload,
    this.baseRevision,
    required this.createdAt,
    required this.retryCount,
    this.nextRetryAt,
    required this.status,
    this.lastErrorCode,
  });

  final String id;
  final String operationId;
  final PendingOperationType type;
  final String nodeId;
  final Map<String, dynamic> payload;
  final int? baseRevision;
  final DateTime createdAt;
  final int retryCount;
  final DateTime? nextRetryAt;
  final PendingOperationStatus status;
  final String? lastErrorCode;
}

/// CRUD for the local `pending_operations` outbox table. Like [NodeCache],
/// every call is a synchronous local-disk operation.
final class PendingOperationsStore {
  PendingOperationsStore(this._db);

  final Database _db;

  void enqueue(PendingOperation op) {
    _db.execute(
      '''
      INSERT INTO pending_operations (id, operation_id, type, node_id, payload, base_revision, created_at, retry_count, next_retry_at, status, last_error_code)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        op.id,
        op.operationId,
        op.type.wireValue,
        op.nodeId,
        jsonEncode(op.payload),
        op.baseRevision,
        op.createdAt.toUtc().toIso8601String(),
        op.retryCount,
        op.nextRetryAt?.toUtc().toIso8601String(),
        op.status.wireValue,
        op.lastErrorCode,
      ],
    );
  }

  PendingOperation? getById(String id) {
    final rows = _db.select('SELECT * FROM pending_operations WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Operations ready to attempt now, oldest first: PENDING, and either
  /// never backed off or whose backoff window has already passed.
  List<PendingOperation> listReady(DateTime now) {
    final rows = _db.select(
      '''
      SELECT * FROM pending_operations
      WHERE status = ? AND (next_retry_at IS NULL OR next_retry_at <= ?)
      ORDER BY created_at
      ''',
      [PendingOperationStatus.pending.wireValue, now.toUtc().toIso8601String()],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  bool hasUnfinishedOperationsForNode(String nodeId) {
    final rows = _db.select(
      "SELECT 1 FROM pending_operations WHERE node_id = ? AND status IN ('PENDING', 'RUNNING', 'BLOCKED') LIMIT 1",
      [nodeId],
    );
    return rows.isNotEmpty;
  }

  /// True if an older, still-unfinished operation exists for [nodeId]. A
  /// backoff on an earlier operation (e.g. a CREATE) must not let a later
  /// one (e.g. an UPDATE enqueued right after it) jump ahead and run
  /// against a node the server doesn't know about yet — see SyncEngine.
  bool hasEarlierUnfinishedOperationForNode(String nodeId, DateTime strictlyBefore) {
    final rows = _db.select(
      "SELECT 1 FROM pending_operations WHERE node_id = ? AND created_at < ? AND status IN ('PENDING', 'RUNNING', 'BLOCKED') LIMIT 1",
      [nodeId, strictlyBefore.toUtc().toIso8601String()],
    );
    return rows.isNotEmpty;
  }

  void markRunning(String id) => _db.execute("UPDATE pending_operations SET status = 'RUNNING' WHERE id = ?", [id]);

  void markDone(String id) => _db.execute("UPDATE pending_operations SET status = 'DONE' WHERE id = ?", [id]);

  void markRetry(String id, {required int retryCount, required DateTime nextRetryAt, String? errorCode}) {
    _db.execute(
      "UPDATE pending_operations SET status = 'PENDING', retry_count = ?, next_retry_at = ?, last_error_code = ? WHERE id = ?",
      [retryCount, nextRetryAt.toUtc().toIso8601String(), errorCode, id],
    );
  }

  void markFailed(String id, {String? errorCode}) {
    _db.execute("UPDATE pending_operations SET status = 'FAILED', last_error_code = ? WHERE id = ?", [errorCode, id]);
  }

  PendingOperation _fromRow(Row row) => PendingOperation(
        id: row['id'] as String,
        operationId: row['operation_id'] as String,
        type: PendingOperationType.fromWire(row['type'] as String),
        nodeId: row['node_id'] as String,
        payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
        baseRevision: row['base_revision'] as int?,
        createdAt: DateTime.parse(row['created_at'] as String),
        retryCount: row['retry_count'] as int,
        nextRetryAt: row['next_retry_at'] != null ? DateTime.parse(row['next_retry_at'] as String) : null,
        status: PendingOperationStatus.fromWire(row['status'] as String),
        lastErrorCode: row['last_error_code'] as String?,
      );
}
