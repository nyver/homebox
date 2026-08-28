import 'package:sqlite3/sqlite3.dart';

/// One file node this device has already written into the local sync
/// folder, at [relativePath] under its root, with content matching file
/// version [contentVersionId]. Lets `SyncFolderMaterializer` skip
/// re-downloading content that has not changed server-side, cheaply detect
/// a pure move/rename (the node's current path no longer matches
/// [relativePath] even though [contentVersionId] is unchanged — a rename
/// bumps the node's revision without creating a new file version, so
/// revision alone cannot tell the two apart), and prune files whose node
/// was deleted or is no longer reachable from the vault root.
final class MaterializedFile {
  const MaterializedFile({required this.nodeId, required this.relativePath, required this.contentVersionId});

  final String nodeId;
  final String relativePath;
  final String? contentVersionId;
}

/// CRUD for the local `materialized_files` table (spec §8: the sync-folder
/// mirror). Like [NodeCache], every call is a synchronous local-disk
/// operation.
final class MaterializedFilesStore {
  MaterializedFilesStore(this._db);

  final Database _db;

  MaterializedFile? getById(String nodeId) {
    final rows = _db.select('SELECT * FROM materialized_files WHERE node_id = ?', [nodeId]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  List<MaterializedFile> listAll() => _db.select('SELECT * FROM materialized_files').map(_fromRow).toList(growable: false);

  void upsert(MaterializedFile file) {
    _db.execute(
      '''
      INSERT INTO materialized_files (node_id, relative_path, content_version_id) VALUES (?, ?, ?)
      ON CONFLICT(node_id) DO UPDATE SET relative_path = excluded.relative_path, content_version_id = excluded.content_version_id
      ''',
      [file.nodeId, file.relativePath, file.contentVersionId],
    );
  }

  void remove(String nodeId) => _db.execute('DELETE FROM materialized_files WHERE node_id = ?', [nodeId]);

  MaterializedFile _fromRow(Row row) => MaterializedFile(
        nodeId: row['node_id'] as String,
        relativePath: row['relative_path'] as String,
        contentVersionId: row['content_version_id'] as String?,
      );
}
