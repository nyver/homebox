import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Opens and migrates the client's local SQLite database (spec §13): a
/// cache of decrypted-on-demand node metadata plus the durable outbox that
/// makes offline mutation possible. This mirrors the server's own
/// versioned-migration approach (`internal/database`) rather than an
/// inline schema dump, for the same reason: schema changes must never
/// require deleting an existing local database.
final class LocalDatabase {
  LocalDatabase._(this.db);

  final Database db;

  /// Opens the database at the platform's application-support directory,
  /// scoped by [serverFingerprint] so switching between HomeBox servers
  /// (each a different pinned identity) never mixes their local caches.
  static Future<LocalDatabase> open(String serverFingerprint) async {
    final supportDir = await getApplicationSupportDirectory();
    final dbDir = Directory('${supportDir.path}/homebox/local-db');
    await dbDir.create(recursive: true);
    final safeName = serverFingerprint.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    return openAtPath('${dbDir.path}/$safeName.sqlite3');
  }

  static LocalDatabase openAtPath(String path) => _openAndMigrate(sqlite3.open(path));

  static LocalDatabase openInMemory() => _openAndMigrate(sqlite3.openInMemory());

  static LocalDatabase _openAndMigrate(Database db) {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    _migrate(db);
    return LocalDatabase._(db);
  }

  static void _migrate(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
    ''');
    final applied = <int>{
      for (final row in db.select('SELECT version FROM schema_migrations')) row['version'] as int,
    };
    for (final migration in _migrations) {
      if (applied.contains(migration.version)) continue;
      db.execute('BEGIN');
      try {
        db.execute(migration.sql);
        db.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [migration.version, DateTime.now().toUtc().toIso8601String()],
        );
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  void dispose() => db.close();
}

final class _Migration {
  const _Migration(this.version, this.sql);
  final int version;
  final String sql;
}

// Migrations must only ever be appended to, never edited in place — the
// same rule the server's internal/database/migrations.go follows.
final List<_Migration> _migrations = [
  _Migration(1, '''
    CREATE TABLE IF NOT EXISTS nodes (
      id TEXT PRIMARY KEY,
      parent_id TEXT,
      node_type TEXT NOT NULL CHECK(node_type IN ('FILE', 'DIRECTORY')),
      metadata_ciphertext BLOB NOT NULL,
      metadata_key_version INTEGER NOT NULL,
      current_version_id TEXT,
      revision INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT,
      pending_create INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id);

    CREATE TABLE IF NOT EXISTS pending_operations (
      id TEXT PRIMARY KEY,
      operation_id TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      node_id TEXT NOT NULL,
      payload TEXT NOT NULL,
      base_revision INTEGER,
      created_at TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      next_retry_at TEXT,
      status TEXT NOT NULL CHECK(status IN ('PENDING', 'RUNNING', 'BLOCKED', 'DONE', 'FAILED')),
      last_error_code TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_pending_operations_status ON pending_operations(status, created_at);
    CREATE INDEX IF NOT EXISTS idx_pending_operations_node ON pending_operations(node_id);

    CREATE TABLE IF NOT EXISTS sync_state (
      server_id TEXT PRIMARY KEY,
      last_sync_revision INTEGER NOT NULL,
      last_successful_sync_at TEXT
    );
  '''),
  _Migration(2, '''
    CREATE TABLE IF NOT EXISTS materialized_files (
      node_id TEXT PRIMARY KEY,
      relative_path TEXT NOT NULL,
      content_version_id TEXT
    );
  '''),
];
