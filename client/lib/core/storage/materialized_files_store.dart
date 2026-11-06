import 'dart:io';

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
  const MaterializedFile({
    required this.nodeId,
    required this.relativePath,
    required this.contentVersionId,
    this.localSize,
    this.localModifiedAt,
    this.contentSha256,
  });

  final String nodeId;
  final String relativePath;
  final String? contentVersionId;

  /// Size and last-modified time of the local copy when it was last known to
  /// hold exactly [contentVersionId]'s plaintext. Null when unknown (e.g. a
  /// record written before these were tracked, or on Android storage).
  final int? localSize;
  final DateTime? localModifiedAt;

  /// Lowercase hex SHA-256 of [contentVersionId]'s plaintext, i.e. of what the
  /// local copy held when it was last in sync. Lets a sync pass tell a real
  /// local edit apart from a file whose timestamp merely changed. Null for
  /// records written before this was tracked: such a copy is treated as
  /// possibly edited, so it is preserved rather than overwritten.
  final String? contentSha256;

  /// True when [stat] still describes the copy recorded here, i.e. the file
  /// has very likely not been touched since. Used only to skip re-hashing;
  /// any mismatch falls back to comparing the full content hash.
  bool matchesLocalStat(FileStat stat) =>
      localModifiedAt != null &&
      matchesSizeAndModified(stat.size, stat.modified);

  /// Like [matchesLocalStat], for storage reached without a [FileStat] (an
  /// Android Storage Access Framework document). A provider that does not
  /// report modification times recorded a null [localModifiedAt], so only the
  /// size is compared then. False while no stat has been recorded at all.
  bool matchesSizeAndModified(int size, DateTime? modified) =>
      localSize != null &&
      localSize == size &&
      localModifiedAt?.millisecondsSinceEpoch ==
          modified?.millisecondsSinceEpoch;
}

/// CRUD for the local `materialized_files` table (spec §8: the sync-folder
/// mirror). Like [NodeCache], every call is a synchronous local-disk
/// operation.
final class MaterializedFilesStore {
  MaterializedFilesStore(this._db);

  final Database _db;

  MaterializedFile? getById(String nodeId) {
    final rows = _db.select(
      'SELECT * FROM materialized_files WHERE node_id = ?',
      [nodeId],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// The record of a node other than [excludingNodeId] whose local copy
  /// lives at [relativePath], if any. During one materialization pass two
  /// records can briefly share a path: once a node is relocated onto a path,
  /// the previous occupant's bytes there are gone, so that occupant must
  /// neither move nor delete the file it still points at.
  MaterializedFile? getByRelativePath(
    String relativePath, {
    required String excludingNodeId,
  }) {
    final rows = _db.select(
      'SELECT * FROM materialized_files WHERE relative_path = ? AND node_id != ? LIMIT 1',
      [relativePath, excludingNodeId],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  List<MaterializedFile> listAll() => _db
      .select('SELECT * FROM materialized_files')
      .map(_fromRow)
      .toList(growable: false);

  void upsert(MaterializedFile file) {
    _db.execute(
      '''
      INSERT INTO materialized_files (node_id, relative_path, content_version_id, local_size, local_modified_at, content_sha256) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(node_id) DO UPDATE SET relative_path = excluded.relative_path, content_version_id = excluded.content_version_id, local_size = excluded.local_size, local_modified_at = excluded.local_modified_at, content_sha256 = excluded.content_sha256
      ''',
      [
        file.nodeId,
        file.relativePath,
        file.contentVersionId,
        file.localSize,
        file.localModifiedAt?.millisecondsSinceEpoch,
        file.contentSha256?.toLowerCase(),
      ],
    );
  }

  void remove(String nodeId) =>
      _db.execute('DELETE FROM materialized_files WHERE node_id = ?', [nodeId]);

  void clear() => _db.execute('DELETE FROM materialized_files');

  MaterializedFile _fromRow(Row row) => MaterializedFile(
    nodeId: row['node_id'] as String,
    relativePath: row['relative_path'] as String,
    contentVersionId: row['content_version_id'] as String?,
    localSize: row['local_size'] as int?,
    localModifiedAt: switch (row['local_modified_at']) {
      final int millis => DateTime.fromMillisecondsSinceEpoch(
        millis,
        isUtc: true,
      ),
      _ => null,
    },
    contentSha256: row['content_sha256'] as String?,
  );
}
