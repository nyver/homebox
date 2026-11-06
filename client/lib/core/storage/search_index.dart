import 'package:sqlite3/sqlite3.dart';

/// A full-text index of decrypted file and folder names (spec §29: search
/// runs on the client, never on the server).
///
/// It lives in an in-memory SQLite database with an FTS5 trigram table, so
/// any part of a name matches, in any language, while plaintext names are
/// never written to disk. It is rebuilt lazily once per app session and
/// then kept current incrementally: each entry remembers a stamp of the
/// metadata it was built from, so only changed nodes are decrypted again.
final class SearchIndex {
  SearchIndex() : _db = sqlite3.openInMemory() {
    _db.execute('''
      CREATE TABLE entries (
        node_id TEXT PRIMARY KEY,
        stamp TEXT NOT NULL
      );
      CREATE VIRTUAL TABLE names USING fts5(
        node_id UNINDEXED,
        folded,
        tokenize = 'trigram'
      );
    ''');
  }

  final Database _db;
  bool _disposed = false;

  /// FTS5's trigram tokenizer needs at least three characters per term.
  static const int _minTrigramLength = 3;

  /// The stamp each node was indexed with.
  Map<String, String> stamps() => {
    for (final row in _db.select('SELECT node_id, stamp FROM entries'))
      row['node_id'] as String: row['stamp'] as String,
  };

  void put(String nodeId, String stamp, String name) {
    _db.execute('DELETE FROM names WHERE node_id = ?', [nodeId]);
    _db.execute('INSERT INTO names (node_id, folded) VALUES (?, ?)', [
      nodeId,
      fold(name),
    ]);
    _db.execute(
      'INSERT OR REPLACE INTO entries (node_id, stamp) VALUES (?, ?)',
      [nodeId, stamp],
    );
  }

  void remove(String nodeId) {
    _db.execute('DELETE FROM names WHERE node_id = ?', [nodeId]);
    _db.execute('DELETE FROM entries WHERE node_id = ?', [nodeId]);
  }

  /// Runs [body] in one transaction, which makes a full rebuild fast.
  void batch(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// IDs of nodes whose name contains every whitespace-separated term of
  /// [query], case-insensitively, best matches first.
  List<String> search(String query, {int limit = 200}) {
    final terms = fold(query)
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return const [];
    final ResultSet rows;
    if (terms.every((term) => term.length >= _minTrigramLength)) {
      // Each term as an FTS5 string: implicit AND, substring match.
      final match = terms.map((t) => '"${t.replaceAll('"', '""')}"').join(' ');
      rows = _db.select(
        'SELECT node_id FROM names WHERE names MATCH ? ORDER BY rank LIMIT ?',
        [match, limit],
      );
    } else {
      final where = List.filled(
        terms.length,
        r"folded LIKE ? ESCAPE '\'",
      ).join(' AND ');
      rows = _db.select(
        'SELECT node_id FROM names WHERE $where ORDER BY length(folded) LIMIT ?',
        [for (final term in terms) '%${_escapeLike(term)}%', limit],
      );
    }
    return [for (final row in rows) row['node_id'] as String];
  }

  /// Case folding shared by indexing and queries.
  static String fold(String value) => value.toLowerCase();

  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _db.close();
  }
}
