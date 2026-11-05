import 'package:sqlite3/sqlite3.dart';

/// How a sync conflict (spec §21) was resolved on this device. Every kind
/// keeps all content: either both versions survive side by side, or the
/// server state wins for a pure metadata change and the local intent is
/// reported instead of being applied blindly.
enum SyncConflictKind {
  /// The same file changed here and on another device. The server version
  /// stays at the original name; the local edit is kept as a conflict copy.
  bothModified('BOTH_MODIFIED'),

  /// A local file and a different server file have the same name. Both are
  /// kept; the local one becomes a conflict copy.
  bothCreated('BOTH_CREATED'),

  /// A file edited here was deleted on another device. The original stays in
  /// Trash; the local edit is kept as a conflict copy.
  modifiedLocallyDeletedRemotely('MODIFIED_LOCALLY_DELETED_REMOTELY'),

  /// A rename made here lost to a different rename (or a delete) on another
  /// device. The server name is kept.
  renameRejected('RENAME_REJECTED'),

  /// A move made here lost to a different move (or a delete) on another
  /// device. The server location is kept.
  moveRejected('MOVE_REJECTED'),

  /// A delete made here was not applied because the item changed on another
  /// device first. The item is kept so the newer content is not lost.
  deleteRejected('DELETE_REJECTED');

  const SyncConflictKind(this.wireValue);
  final String wireValue;

  /// True for conflicts that left a separate conflict copy behind.
  bool get keepsConflictCopy => switch (this) {
    bothModified || bothCreated || modifiedLocallyDeletedRemotely => true,
    renameRejected || moveRejected || deleteRejected => false,
  };

  static SyncConflictKind fromWire(String value) => values.firstWhere(
    (kind) => kind.wireValue == value,
    orElse: () => throw FormatException('Unknown sync conflict kind: $value'),
  );
}

/// One conflict this device detected and resolved.
final class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.kind,
    required this.detectedAt,
    this.nodeId,
    this.fileName,
    this.conflictCopyPath,
    this.copyNodeId,
    this.dismissed = false,
  });

  final String id;
  final SyncConflictKind kind;
  final DateTime detectedAt;

  /// The node the conflict was about, when known.
  final String? nodeId;

  /// The item's display name, when this device could decrypt it.
  final String? fileName;

  /// Sync-folder-relative path of the preserved conflict copy, if any.
  final String? conflictCopyPath;

  /// The node created by uploading that copy, once the upload succeeded.
  final String? copyNodeId;
  final bool dismissed;
}

/// CRUD for the local `sync_conflicts` table. Like the other local stores,
/// every call is a synchronous local-disk operation. The table lives in the
/// same trusted local database that already holds plaintext sync-folder
/// paths; it never leaves the device.
final class SyncConflictsStore {
  SyncConflictsStore(this._db);

  /// Dismissed rows beyond this many are pruned so the table stays bounded.
  static const int maxDismissedRows = 200;

  final Database _db;

  void record(SyncConflict conflict) {
    _db.execute(
      '''
      INSERT INTO sync_conflicts (id, kind, node_id, file_name, conflict_copy_path, copy_node_id, detected_at, dismissed)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        conflict.id,
        conflict.kind.wireValue,
        conflict.nodeId,
        conflict.fileName,
        conflict.conflictCopyPath,
        conflict.copyNodeId,
        conflict.detectedAt.toUtc().toIso8601String(),
        conflict.dismissed ? 1 : 0,
      ],
    );
  }

  /// Conflicts not yet dismissed by the user, newest first.
  List<SyncConflict> listOpen({int limit = 100}) => _db
      .select(
        'SELECT * FROM sync_conflicts WHERE dismissed = 0 ORDER BY detected_at DESC LIMIT ?',
        [limit],
      )
      .map(_fromRow)
      .toList(growable: false);

  int countOpen() =>
      _db
              .select(
                'SELECT COUNT(*) AS n FROM sync_conflicts WHERE dismissed = 0',
              )
              .first['n']
          as int;

  /// The conflict whose preserved copy at [relativePath] still waits for
  /// its first upload, if any.
  SyncConflict? copyAwaitingUpload(String relativePath) {
    final rows = _db.select(
      'SELECT * FROM sync_conflicts WHERE conflict_copy_path = ? AND copy_node_id IS NULL ORDER BY detected_at DESC LIMIT 1',
      [relativePath],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  void markCopyUploaded(String id, String copyNodeId) => _db.execute(
    'UPDATE sync_conflicts SET copy_node_id = ? WHERE id = ?',
    [copyNodeId, id],
  );

  void dismiss(String id) {
    _db.execute('UPDATE sync_conflicts SET dismissed = 1 WHERE id = ?', [id]);
    _pruneDismissed();
  }

  void dismissAll() {
    _db.execute('UPDATE sync_conflicts SET dismissed = 1 WHERE dismissed = 0');
    _pruneDismissed();
  }

  void _pruneDismissed() => _db.execute(
    '''
    DELETE FROM sync_conflicts WHERE id IN (
      SELECT id FROM sync_conflicts WHERE dismissed = 1
      ORDER BY detected_at DESC LIMIT -1 OFFSET ?
    )
    ''',
    [maxDismissedRows],
  );

  SyncConflict _fromRow(Row row) => SyncConflict(
    id: row['id'] as String,
    kind: SyncConflictKind.fromWire(row['kind'] as String),
    detectedAt: DateTime.parse(row['detected_at'] as String),
    nodeId: row['node_id'] as String?,
    fileName: row['file_name'] as String?,
    conflictCopyPath: row['conflict_copy_path'] as String?,
    copyNodeId: row['copy_node_id'] as String?,
    dismissed: (row['dismissed'] as int) != 0,
  );
}
