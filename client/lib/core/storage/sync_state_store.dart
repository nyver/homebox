import 'package:sqlite3/sqlite3.dart';

/// Tracks `last_sync_revision` per server (spec §13.2/ADR-005): the cursor
/// a client resumes the sync changes feed from after being offline.
final class SyncStateStore {
  SyncStateStore(this._db);

  final Database _db;

  int lastSyncRevision(String serverId) {
    final rows = _db.select('SELECT last_sync_revision FROM sync_state WHERE server_id = ?', [serverId]);
    if (rows.isEmpty) return 0;
    return rows.first['last_sync_revision'] as int;
  }

  /// Advances the cursor. Callers must only do this after every change up
  /// to and including [revision] has been durably applied locally (spec
  /// §19.4) — advancing early risks silently skipping a change on crash.
  void advance(String serverId, int revision) {
    _db.execute(
      '''
      INSERT INTO sync_state (server_id, last_sync_revision, last_successful_sync_at) VALUES (?, ?, ?)
      ON CONFLICT(server_id) DO UPDATE SET
        last_sync_revision = excluded.last_sync_revision,
        last_successful_sync_at = excluded.last_successful_sync_at
      ''',
      [serverId, revision, DateTime.now().toUtc().toIso8601String()],
    );
  }
}
