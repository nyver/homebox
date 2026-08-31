import 'package:sqlite3/sqlite3.dart';

/// A directory node this device has successfully created in its local sync
/// folder. This record lets the uploader distinguish a user-deleted synced
/// directory from a directory that has not yet been downloaded.
final class MaterializedDirectory {
  const MaterializedDirectory({
    required this.nodeId,
    required this.relativePath,
  });

  final String nodeId;
  final String relativePath;
}

/// CRUD for directory entries in the local sync-folder mirror.
final class MaterializedDirectoriesStore {
  MaterializedDirectoriesStore(this._db);

  final Database _db;

  MaterializedDirectory? getById(String nodeId) {
    final rows = _db.select(
      'SELECT * FROM materialized_directories WHERE node_id = ?',
      [nodeId],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  List<MaterializedDirectory> listAll() => _db
      .select('SELECT * FROM materialized_directories')
      .map(_fromRow)
      .toList(growable: false);

  void upsert(MaterializedDirectory directory) {
    _db.execute(
      '''
      INSERT INTO materialized_directories (node_id, relative_path) VALUES (?, ?)
      ON CONFLICT(node_id) DO UPDATE SET relative_path = excluded.relative_path
      ''',
      [directory.nodeId, directory.relativePath],
    );
  }

  void remove(String nodeId) => _db.execute(
    'DELETE FROM materialized_directories WHERE node_id = ?',
    [nodeId],
  );

  MaterializedDirectory _fromRow(Row row) => MaterializedDirectory(
    nodeId: row['node_id'] as String,
    relativePath: row['relative_path'] as String,
  );
}
