import 'package:sqlite3/sqlite3.dart';

/// Remembers an immutable file version whose decrypted bytes did not match
/// the SHA-256 stored in its encrypted metadata. Re-downloading the same
/// version cannot repair that mismatch, so the sync folder suppresses the
/// transfer until either the version or node revision changes. Storing the
/// revision instead of the expected plaintext hash keeps decrypted content
/// fingerprints out of the local metadata cache.
final class MaterializationFailuresStore {
  MaterializationFailuresStore(this._db);

  final Database _db;

  bool contains({
    required String nodeId,
    required String contentVersionId,
    required int nodeRevision,
  }) {
    final rows = _db.select(
      '''
      SELECT 1 FROM materialization_failures
      WHERE node_id = ? AND content_version_id = ? AND node_revision = ?
      ''',
      [nodeId, contentVersionId, nodeRevision],
    );
    return rows.isNotEmpty;
  }

  void record({
    required String nodeId,
    required String contentVersionId,
    required int nodeRevision,
  }) {
    _db.execute(
      '''
      INSERT INTO materialization_failures (node_id, content_version_id, node_revision)
      VALUES (?, ?, ?)
      ON CONFLICT(node_id) DO UPDATE SET
        content_version_id = excluded.content_version_id,
        node_revision = excluded.node_revision
      ''',
      [nodeId, contentVersionId, nodeRevision],
    );
  }

  void remove(String nodeId) {
    _db.execute('DELETE FROM materialization_failures WHERE node_id = ?', [
      nodeId,
    ]);
  }

  List<String> listNodeIds() => _db
      .select('SELECT node_id FROM materialization_failures')
      .map((row) => row['node_id'] as String)
      .toList(growable: false);
}
