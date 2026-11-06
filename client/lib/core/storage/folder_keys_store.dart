import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../transport/homebox_api_client.dart' show FolderKeyRecord;

/// The account's shared-folder keys, still wrapped by its personal Vault
/// Key (ADR-023). Cached locally so shared folders can be browsed, edited,
/// and mirrored while offline; the server copy is authoritative.
final class FolderKeysStore {
  FolderKeysStore(this._db);

  final Database _db;

  /// Replaces the cache with the server's complete list.
  void replaceAll(List<FolderKeyRecord> records) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM folder_keys');
      for (final record in records) {
        _db.execute(
          'INSERT OR REPLACE INTO folder_keys (folder_id, key_version, owner_envelope) VALUES (?, ?, ?)',
          [record.folderId, record.keyVersion, record.ownerEnvelope],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Records one key this device has just created.
  void add(String folderId, int keyVersion, Uint8List envelope) {
    _db.execute(
      'INSERT OR REPLACE INTO folder_keys (folder_id, key_version, owner_envelope) VALUES (?, ?, ?)',
      [folderId, keyVersion, envelope],
    );
  }

  /// Every wrapped key, grouped by folder and version.
  Map<String, Map<int, Uint8List>> all() {
    final result = <String, Map<int, Uint8List>>{};
    for (final row in _db.select(
      'SELECT folder_id, key_version, owner_envelope FROM folder_keys',
    )) {
      result.putIfAbsent(
        row['folder_id'] as String,
        () => {},
      )[row['key_version'] as int] = row['owner_envelope'] as Uint8List;
    }
    return result;
  }

  bool isKeyedFolder(String folderId) => _db.select(
    'SELECT 1 FROM folder_keys WHERE folder_id = ? LIMIT 1',
    [folderId],
  ).isNotEmpty;

  Set<String> keyedFolderIds() => {
    for (final row in _db.select('SELECT DISTINCT folder_id FROM folder_keys'))
      row['folder_id'] as String,
  };
}
