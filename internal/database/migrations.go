package database

type migration struct {
	Version int
	Name    string
	SQL     string
}

// migrations must only ever be appended to. Never edit a previously released
// migration's SQL in place; ship a new numbered migration instead, so that a
// database created by an older build can always be brought forward without
// deleting existing data.
var migrations = []migration{
	{1, "initial_schema", migration0001InitialSchema},
	{2, "access_tokens", migration0002AccessTokens},
	{3, "maintenance_gc_candidates", migration0003MaintenanceGCCandidates},
	{4, "share_device_envelopes", migration0004ShareDeviceEnvelopes},
}

const migration0001InitialSchema = `
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

// migration0002AccessTokens backs short-lived bearer access tokens with a
// table (rather than an in-memory map) so a server restart mid-session only
// costs clients a refresh, not a forced re-login, and so revocation/expiry
// are plain SQL rather than a second source of truth.
const migration0002AccessTokens = `
CREATE TABLE IF NOT EXISTS access_tokens (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), device_id TEXT NOT NULL REFERENCES devices(id),
  token_hash BLOB NOT NULL, created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_access_tokens_hash ON access_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_access_tokens_expires ON access_tokens(expires_at);
`

// migration0003MaintenanceGCCandidates records the first pass of two-phase
// ciphertext garbage collection. A candidate must remain unreachable through
// a full grace period before maintenance may remove it.
const migration0003MaintenanceGCCandidates = `
CREATE TABLE IF NOT EXISTS gc_blob_candidates (
  blob_id TEXT PRIMARY KEY REFERENCES blobs(id), marked_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS gc_orphan_blob_files (
  storage_rel_path TEXT PRIMARY KEY, marked_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_gc_blob_candidates_marked_at ON gc_blob_candidates(marked_at);
CREATE INDEX IF NOT EXISTS idx_gc_orphan_blob_files_marked_at ON gc_orphan_blob_files(marked_at);
`

// migration0004ShareDeviceEnvelopes adds recipient-device envelopes without
// changing the server's zero-knowledge boundary. The legacy shares envelope
// remains opaque compatibility data; all new sharing reads use this table.
const migration0004ShareDeviceEnvelopes = `
CREATE TABLE IF NOT EXISTS share_device_envelopes (
  id TEXT PRIMARY KEY, share_id TEXT NOT NULL REFERENCES shares(id),
  target_device_id TEXT NOT NULL REFERENCES devices(id), key_version INTEGER NOT NULL,
  envelope_ciphertext BLOB NOT NULL, created_at TEXT NOT NULL, revoked_at TEXT,
  UNIQUE(share_id,target_device_id,key_version)
);
CREATE INDEX IF NOT EXISTS idx_active_share_per_recipient
  ON shares(node_id,target_user_id,revoked_at);
CREATE INDEX IF NOT EXISTS idx_share_device_envelopes_recipient
  ON share_device_envelopes(target_device_id,share_id) WHERE revoked_at IS NULL;
`
