import 'package:sqlite3/sqlite3.dart';

/// This account's favorite node IDs (spec §29), cached from the server.
///
/// [generation] increases on every local change, so a sync pass that
/// fetched the server list before a change can tell its copy is stale and
/// skip replacing the cache with it.
final class FavoritesStore {
  FavoritesStore(this._db);

  final Database _db;
  int _generation = 0;

  int get generation => _generation;

  Set<String> all() => {
    for (final row in _db.select('SELECT node_id FROM favorites'))
      row['node_id'] as String,
  };

  bool contains(String nodeId) => _db.select(
    'SELECT 1 FROM favorites WHERE node_id = ?',
    [nodeId],
  ).isNotEmpty;

  void add(String nodeId) {
    _db.execute('INSERT OR IGNORE INTO favorites (node_id) VALUES (?)', [
      nodeId,
    ]);
    _generation++;
  }

  void remove(String nodeId) {
    _db.execute('DELETE FROM favorites WHERE node_id = ?', [nodeId]);
    _generation++;
  }

  /// Replaces the cache with [nodeIds] unless the cache changed locally
  /// since [fetchedAtGeneration].
  bool replaceAllIfUnchanged(
    Iterable<String> nodeIds,
    int fetchedAtGeneration,
  ) {
    if (fetchedAtGeneration != _generation) return false;
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM favorites');
      for (final id in nodeIds) {
        _db.execute('INSERT OR IGNORE INTO favorites (node_id) VALUES (?)', [
          id,
        ]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return true;
  }
}
