package database

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

func Open(storagePath string) (*sql.DB, error) {
	databaseDir := filepath.Join(storagePath, "database")
	if err := os.MkdirAll(databaseDir, 0o700); err != nil {
		return nil, fmt.Errorf("create database directory: %w", err)
	}
	db, err := sql.Open("sqlite", filepath.Join(databaseDir, "homebox.db"))
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;`); err != nil {
		db.Close()
		return nil, fmt.Errorf("configure database: %w", err)
	}
	if err := Migrate(context.Background(), db); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func Migrate(ctx context.Context, db *sql.DB) error {
	_, err := db.ExecContext(ctx, schema)
	if err != nil {
		return fmt.Errorf("migrate database: %w", err)
	}
	return nil
}

const schema = `
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY, username TEXT NOT NULL, username_norm TEXT NOT NULL UNIQUE,
  display_name TEXT, password_hash TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('ADMIN','USER')),
  status TEXT NOT NULL CHECK(status IN ('ACTIVE','DISABLED')), created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name TEXT NOT NULL,
  platform TEXT NOT NULL CHECK(platform IN ('WINDOWS','ANDROID','OTHER')), e2ee_public_key BLOB NOT NULL,
  e2ee_key_version INTEGER NOT NULL, created_at TEXT NOT NULL, last_seen_at TEXT NOT NULL, revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), device_id TEXT NOT NULL REFERENCES devices(id),
  token_hash BLOB NOT NULL, created_at TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS vault_key_envelopes (
  id TEXT PRIMARY KEY, vault_id TEXT NOT NULL, target_user_id TEXT NOT NULL REFERENCES users(id),
  target_device_id TEXT REFERENCES devices(id), key_version INTEGER NOT NULL, envelope_ciphertext BLOB NOT NULL,
  created_at TEXT NOT NULL, revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES users(id), parent_id TEXT REFERENCES nodes(id),
  node_type TEXT NOT NULL CHECK(node_type IN ('FILE','DIRECTORY')), metadata_ciphertext BLOB NOT NULL,
  metadata_key_version INTEGER NOT NULL, current_version_id TEXT, revision INTEGER NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE IF NOT EXISTS blobs (
  id TEXT PRIMARY KEY, ciphertext_size INTEGER NOT NULL, storage_rel_path TEXT NOT NULL UNIQUE,
  ciphertext_sha256 TEXT NOT NULL, format_version INTEGER NOT NULL, chunk_count INTEGER NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS file_versions (
  id TEXT PRIMARY KEY, node_id TEXT NOT NULL REFERENCES nodes(id), blob_id TEXT NOT NULL REFERENCES blobs(id),
  e2ee_header BLOB NOT NULL, wrapped_file_key BLOB NOT NULL, key_scope_id TEXT NOT NULL, key_version INTEGER NOT NULL,
  created_at TEXT NOT NULL, created_by_device_id TEXT NOT NULL REFERENCES devices(id), revision INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_changes (
  revision INTEGER PRIMARY KEY AUTOINCREMENT, user_scope_id TEXT, node_id TEXT, operation TEXT NOT NULL,
  payload_ciphertext BLOB, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS processed_operations (
  operation_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), device_id TEXT NOT NULL REFERENCES devices(id),
  operation_type TEXT NOT NULL, result_code TEXT NOT NULL, result_payload BLOB, created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS upload_sessions (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), device_id TEXT NOT NULL REFERENCES devices(id),
  target_node_id TEXT REFERENCES nodes(id), file_version_id TEXT NOT NULL, blob_id TEXT NOT NULL,
  expected_revision INTEGER, chunk_size INTEGER NOT NULL, chunk_count INTEGER NOT NULL, max_ciphertext_size INTEGER NOT NULL,
  metadata_ciphertext BLOB, wrapped_file_key BLOB NOT NULL, e2ee_header BLOB NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('OPEN','COMMITTING','COMPLETED','ABORTED','EXPIRED')),
  created_at TEXT NOT NULL, expires_at TEXT NOT NULL, completed_at TEXT
);
CREATE TABLE IF NOT EXISTS upload_chunks (
  upload_id TEXT NOT NULL REFERENCES upload_sessions(id), chunk_no INTEGER NOT NULL, ciphertext_size INTEGER NOT NULL,
  ciphertext_sha256 TEXT NOT NULL, temp_rel_path TEXT NOT NULL, received_at TEXT NOT NULL, PRIMARY KEY(upload_id, chunk_no)
);
CREATE TABLE IF NOT EXISTS shares (
  id TEXT PRIMARY KEY, node_id TEXT NOT NULL REFERENCES nodes(id), owner_user_id TEXT NOT NULL REFERENCES users(id),
  target_user_id TEXT NOT NULL REFERENCES users(id), permission TEXT NOT NULL CHECK(permission IN ('READ','READ_WRITE')),
  key_envelope BLOB NOT NULL, key_version INTEGER NOT NULL, created_at TEXT NOT NULL, created_by TEXT NOT NULL REFERENCES users(id), revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS favorites (
  user_id TEXT NOT NULL REFERENCES users(id), node_id TEXT NOT NULL REFERENCES nodes(id), created_at TEXT NOT NULL,
  PRIMARY KEY(user_id, node_id)
);
CREATE TABLE IF NOT EXISTS sync_cursors (
  device_id TEXT PRIMARY KEY REFERENCES devices(id), last_ack_revision INTEGER NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, user_id TEXT, device_id TEXT,
  event_type TEXT NOT NULL, subject_id TEXT, request_id TEXT, metadata TEXT
);
CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id);
CREATE INDEX IF NOT EXISTS idx_sync_changes_revision ON sync_changes(revision);
CREATE INDEX IF NOT EXISTS idx_upload_chunks_upload ON upload_chunks(upload_id);
CREATE INDEX IF NOT EXISTS idx_upload_sessions_status ON upload_sessions(status, expires_at);
`
