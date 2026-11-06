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
	{5, "device_last_sync", migration0005DeviceLastSync},
	{6, "upload_metadata_version", migration0006UploadMetadataVersion},
	{7, "trash_retention_index", migration0007TrashRetentionIndex},
	{8, "authenticated_device_keys", migration0008AuthenticatedDeviceKeys},
	{9, "hot_path_indexes_and_token_rotation", migration0009HotPathIndexesAndTokenRotation},
	{10, "recovery_bundles", migration0010RecoveryBundles},
	{11, "file_version_retention_index", migration0011FileVersionRetentionIndex},
	{12, "gc_and_lookup_indexes", migration0012GCAndLookupIndexes},
	{13, "family_vault_folder_keys", migration0013FamilyVaultFolderKeys},
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

// migration0005DeviceLastSync keeps a truthful device-activity timestamp for
// the Settings trusted-device list. Unlike last_seen_at (which is refreshed
// at login), this changes only after a device successfully reads the sync
// feed.
const migration0005DeviceLastSync = `
ALTER TABLE devices ADD COLUMN last_sync_at TEXT;
CREATE INDEX IF NOT EXISTS idx_devices_user_last_sync ON devices(user_id,last_sync_at);
`

// migration0006UploadMetadataVersion lets upload completion publish the file
// version and its encrypted metadata in the same transaction. The default
// keeps already-open sessions from an older server version completable.
const migration0006UploadMetadataVersion = `
ALTER TABLE upload_sessions ADD COLUMN metadata_key_version INTEGER NOT NULL DEFAULT 1;
`

// migration0007TrashRetentionIndex keeps the hourly retention scan bounded to
// deleted nodes instead of walking every active node in a large vault.
const migration0007TrashRetentionIndex = `
CREATE INDEX IF NOT EXISTS idx_nodes_deleted_at ON nodes(deleted_at) WHERE deleted_at IS NOT NULL;
`

// migration0008AuthenticatedDeviceKeys keeps legacy provisioning envelopes
// readable while allowing new clients to attach an Ed25519 account-identity
// certificate to the exact X25519 device key they approved out of band.
const migration0008AuthenticatedDeviceKeys = `
ALTER TABLE vault_key_envelopes ADD COLUMN signature_version INTEGER;
ALTER TABLE vault_key_envelopes ADD COLUMN account_identity_public_key BLOB;
ALTER TABLE vault_key_envelopes ADD COLUMN device_key_signature BLOB;
CREATE INDEX IF NOT EXISTS idx_vault_envelopes_certificates
  ON vault_key_envelopes(target_user_id,target_device_id,created_at)
  WHERE signature_version IS NOT NULL AND revoked_at IS NULL;
`

// migration0009HotPathIndexesAndTokenRotation indexes the per-account sync
// feed, refresh-token lookup, and blob-ID reservation checks, and records
// which refresh token replaced a rotated one. rotated_to distinguishes a
// rotation (where a briefly late retry is tolerated and a later reuse means
// theft) from an explicit logout or device revocation.
const migration0009HotPathIndexesAndTokenRotation = `
CREATE INDEX IF NOT EXISTS idx_sync_changes_user_revision ON sync_changes(user_scope_id, revision);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_hash ON refresh_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_device ON refresh_tokens(device_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_upload_sessions_blob ON upload_sessions(blob_id);
CREATE INDEX IF NOT EXISTS idx_upload_sessions_file_version ON upload_sessions(file_version_id);
ALTER TABLE refresh_tokens ADD COLUMN rotated_to TEXT;
`

// migration0010RecoveryBundles stores each account's client-encrypted
// recovery bundle (its Recovery Package plus the Vault Key wrapped by the
// User Master Key) so a Recovery Secret alone can restore a clean device.
// The bundle is opaque: decrypting it requires the Recovery Secret, which
// never reaches the server. The account-identity signature lets the server
// refuse a replacement from a session that does not hold the Vault Key.
const migration0010RecoveryBundles = `
CREATE TABLE IF NOT EXISTS recovery_bundles (
  user_id TEXT PRIMARY KEY REFERENCES users(id), bundle BLOB NOT NULL,
  account_identity_public_key BLOB NOT NULL, signature BLOB NOT NULL,
  updated_at TEXT NOT NULL, updated_by_device_id TEXT NOT NULL REFERENCES devices(id)
);
`

// migration0011FileVersionRetentionIndex keeps the per-file version
// retention scan and the version-history listing ordered by an index.
const migration0011FileVersionRetentionIndex = `
CREATE INDEX IF NOT EXISTS idx_file_versions_node_created ON file_versions(node_id, created_at);
`

// migration0012GCAndLookupIndexes indexes the reverse lookups that run for
// every row of large tables. Without file_versions(blob_id) the hourly blob GC
// scans the whole version table once per blob while holding SQLite's write
// lock, which stalls every client write on a vault with a long history.
const migration0012GCAndLookupIndexes = `
CREATE INDEX IF NOT EXISTS idx_file_versions_blob ON file_versions(blob_id);
CREATE INDEX IF NOT EXISTS idx_upload_sessions_target_node ON upload_sessions(target_node_id);
CREATE INDEX IF NOT EXISTS idx_vault_envelopes_target_device
  ON vault_key_envelopes(target_device_id, created_at) WHERE revoked_at IS NULL;
`

// migration0013FamilyVaultFolderKeys adds what Family Vault sharing needs
// beyond read-only grants (spec §28, ADR-023):
//
//   - nodes.metadata_key_scope_id records which key encrypts a node's
//     metadata. NULL keeps the owner's personal Vault Key; otherwise it is the
//     ID of a shared folder whose own Folder Key encrypts the whole subtree.
//     It is a routing hint only: the AEAD context still binds every envelope
//     to its scope, so a wrong value fails decryption instead of leaking.
//   - folder_keys holds every version of a shared folder's key, wrapped by
//     the owner's Vault Key so all of the owner's devices can open it.
//     folder_id is deliberately not a foreign key: a node moved out of a
//     shared folder keeps its encryption scope, so the key must outlive a
//     purge of the folder itself for as long as anything still uses it.
//   - share_device_envelopes gains the owner's account-identity signature,
//     which lets a recipient reject an envelope the server forged.
const migration0013FamilyVaultFolderKeys = `
ALTER TABLE nodes ADD COLUMN metadata_key_scope_id TEXT;
CREATE TABLE IF NOT EXISTS folder_keys (
  folder_id TEXT NOT NULL, key_version INTEGER NOT NULL,
  owner_user_id TEXT NOT NULL REFERENCES users(id), owner_envelope BLOB NOT NULL,
  created_at TEXT NOT NULL, created_by_device_id TEXT NOT NULL REFERENCES devices(id),
  PRIMARY KEY(folder_id, key_version)
);
CREATE INDEX IF NOT EXISTS idx_folder_keys_owner ON folder_keys(owner_user_id, folder_id);
ALTER TABLE share_device_envelopes ADD COLUMN owner_identity_public_key BLOB;
ALTER TABLE share_device_envelopes ADD COLUMN owner_signature BLOB;
CREATE INDEX IF NOT EXISTS idx_shares_target_active ON shares(target_user_id, node_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_shares_node_active ON shares(node_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_nodes_metadata_scope ON nodes(metadata_key_scope_id) WHERE metadata_key_scope_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_file_versions_key_scope ON file_versions(key_scope_id);
`
