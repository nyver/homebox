import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/local_database.dart';

void main() {
  test('migrations are idempotent across repeated opens of the same file', () async {
    final path = '${Directory.systemTemp.createTempSync('homebox_localdb_').path}/test.sqlite3';
    final first = LocalDatabase.openAtPath(path);
    first.dispose();
    final second = LocalDatabase.openAtPath(path);
    addTearDown(second.dispose);

    final versions = second.db.select('SELECT version FROM schema_migrations ORDER BY version');
    expect(versions.map((r) => r['version']), [1, 2]);
    // Re-opening must not error re-applying earlier migrations, and the
    // nodes table from migration 1 must still exist and be usable.
    second.db.execute(
      "INSERT INTO nodes (id, node_type, metadata_ciphertext, metadata_key_version, revision, created_at, updated_at) "
      "VALUES ('n', 'FILE', X'00', 1, 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
    );
    expect(second.db.select('SELECT COUNT(*) AS c FROM nodes').first['c'], 1);
  });

  test('openInMemory is immediately usable and isolated per instance', () {
    final a = LocalDatabase.openInMemory();
    addTearDown(a.dispose);
    final b = LocalDatabase.openInMemory();
    addTearDown(b.dispose);

    a.db.execute("INSERT INTO sync_state (server_id, last_sync_revision, last_successful_sync_at) VALUES ('s', 5, '2026-01-01T00:00:00Z')");
    expect(a.db.select('SELECT last_sync_revision FROM sync_state').first['last_sync_revision'], 5);
    expect(b.db.select('SELECT COUNT(*) AS c FROM sync_state').first['c'], 0);
  });
}
