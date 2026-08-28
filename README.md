# HomeBox

HomeBox is a self-hosted, zero-knowledge file-storage service for a small family.
Its security boundary is deliberate: clients encrypt file content and sensitive metadata before upload; the server stores only opaque identifiers, encrypted metadata/key envelopes, and ciphertext blobs. It never receives a File DEK, vault key, folder key, user master key, or recovery secret.

This repository currently provides the security-first Go server foundation and a Windows 11 Flutter desktop client foundation. The client authenticates against the server over pinned TLS, creates its own E2EE vault, and can browse, upload, and download real encrypted files against the live server API from its UI. Folder create/rename/move/delete go through a local SQLite cache and durable outbox, so they apply instantly and work offline, syncing to the server opportunistically in the background; a real filesystem watcher/tray integration for automatic local folder sync remains a roadmap milestone — today's upload/download is still user-triggered, not a background watcher. Android remains a later roadmap target, not the current client deliverable.

## Current capabilities

- Safe YAML configuration with mandatory E2EE and no server decryption mode.
- Versioned SQLite migrations (WAL, foreign keys) instead of an inline schema dump.
- Persistent ECDSA P-256 server transport identity and a SHA-256 fingerprint (P-256, not Ed25519 — Dart's bundled TLS client rejects Ed25519 certificates; see ADR-008).
- **Secure Transport is closed (ADR-008/009):** the server terminates TLS 1.3 using a self-signed certificate derived from its identity key. There is no plaintext HTTP mode in any configuration. Clients trust the connection by pinning the identity fingerprint, not a certificate authority.
- Argon2id password hashing, a first-admin bootstrap command, and a full authenticated session lifecycle: login, refresh-token rotation, logout, and device registration/revocation (`/api/v1/auth/*`, `/api/v1/devices*`). Login is timing-safe against username enumeration and rate-limited per username with exponential backoff.
- Encrypted key-envelope delivery between a user's own trusted devices (`/api/v1/devices/{id}/key-envelope`) so a newly provisioned device can fetch the vault key an existing device wrapped for it. Cross-account sharing (Family Vault, §28) is a later milestone.
- Opaque node CRUD (create/rename/move/soft-delete/restore/Trash) with optimistic concurrency and idempotent mutation (`/api/v1/nodes*`, `/api/v1/trash`), and a paged, per-account sync revision feed (`/api/v1/sync/changes`).
- Ciphertext-only resumable upload wired end to end: create/chunk/complete/abort over HTTP (`/api/v1/uploads*`) and streamed unmodified back on download (`/api/v1/files/{id}/content`), with opaque IDs, per-chunk SHA-256 storage checks, idempotent completion, and atomic blob commit.
- A unified error-mapping layer (`internal/httpapi`'s `writeServiceError`) that only ever returns a raw error message to the client when a domain service explicitly marked it safe to show (`internal/apierror.Validation`) — every other failure logs server-side and returns a generic `INTERNAL_ERROR`, so a database/driver error can never leak through the API.
- Health and metrics endpoints.

## Run the server foundation

Copy [config.example.yaml](config.example.yaml) to `config.yaml` and choose a durable `storage.path`.

```powershell
go build -o bin/homebox.exe ./cmd/homebox
./bin/homebox.exe fingerprint --config config.yaml
"a-long-unique-password" | ./bin/homebox.exe bootstrap-admin --config config.yaml --username admin --password-stdin
./bin/homebox.exe server --config config.yaml
```

Every endpoint, including health and metrics, is served over TLS — there is no separate plaintext port:

- `GET /health/live`
- `GET /health/ready`
- `GET /metrics`
- `POST /api/v1/auth/{login,refresh,logout}`
- `GET /api/v1/users/me`
- `GET /api/v1/devices`, `DELETE /api/v1/devices/{id}`
- `POST` / `GET /api/v1/devices/{id}/key-envelope`
- `POST /api/v1/nodes`, `GET /api/v1/nodes/{id}`, `GET /api/v1/nodes/children?parentId=`, `PATCH`/`DELETE /api/v1/nodes/{id}`, `POST /api/v1/nodes/{id}/restore`, `GET /api/v1/trash`
- `GET /api/v1/sync/changes?after=&pageSize=`
- `POST /api/v1/uploads`, `GET`/`DELETE /api/v1/uploads/{id}`, `PUT /api/v1/uploads/{id}/chunks/{chunkNo}`, `POST /api/v1/uploads/{id}/complete`
- `GET /api/v1/files/{id}/content`

The fingerprint must be verified out of band before a client trusts the server identity (ADR-009); a client must refuse to connect if the presented certificate resolves to a different fingerprint than the one it pinned. The certificate is self-signed but uses ECDSA P-256, which is broadly supported (Go, the Flutter client's bundled BoringSSL, OpenSSL, and Windows' own Schannel stack all complete the handshake), so ordinary tools like `curl.exe -k` work for manual poking as long as certificate verification is disabled — there is no CA behind this certificate on purpose.

## Server storage

With `storage.path: ./data`, HomeBox creates:

```text
data/
  database/homebox.db       SQLite: accounts, opaque metadata and ciphertext envelopes
  blobs/<blob-id>.hbxblob  immutable E2EE ciphertext only
  temp/uploads/            uncommitted E2EE ciphertext chunks only
  keys/server_identity.key transport identity only, never a file key
```

Do not place recovery material or client E2EE private keys in this directory. Backups of the server data remain ciphertext-only and cannot recover plaintext without a trusted client or the user's recovery secret.

## Development checks

```powershell
gofmt -w cmd internal
go test ./...
go vet ./...
go build ./cmd/homebox
```

## Client foundation

The Flutter client is in [client](client) and currently targets Windows 11. Its desktop UI provides the Files, Sync, and Settings sections, uses the native Windows folder picker to select a local sync folder (for the still-unimplemented automatic sync milestone), and keeps the vault explicitly locked until it is created or restored. Credentials and file content both now travel over the pinned TLS connection to the server (see below).

The Settings page's "Connect to a HomeBox server" flow discovers a server's identity fingerprint (without trusting it), requires the user to explicitly confirm it before pinning, then supports login/logout. `core/transport/pinned_http_client.dart` mirrors the Go server's fingerprint-pinning logic: it extracts the leaf certificate's P-256 public key using the same fixed RFC 5480 SubjectPublicKeyInfo prefix the server's certificate always has, hashes it with SHA-256, and refuses the connection on any mismatch — normal certificate-authority validation is replaced by this check, not skipped. A device ID and refresh token are persisted (`flutter_secure_storage`) so the app restores its session silently on restart; the short-lived access token is not persisted and is re-derived via refresh. Server login only proves account identity — it never unlocks the E2EE vault (ADR-012), and the UI reflects that as a separate "Signed in" vs. "Vault locked" state.

The client E2EE core now defines protocol-v1 file headers and independently encrypts 4 MB chunks with XChaCha20-Poly1305. Each file version uses a random 256-bit File DEK and a 128-bit nonce prefix; the big-endian chunk number completes the 192-bit nonce. AAD binds the protocol version, opaque file-version ID, chunk number, and total chunk count. Fixed vectors and tamper tests protect the protocol contract.

File DEKs and vault/provisioning keys are serialized only as versioned XChaCha20-Poly1305 envelopes. Envelope AAD binds the purpose, key version, vault/folder scope, and subject file/device ID, so the server cannot substitute an envelope into a different context. Temporary extracted key buffers are erased after wrapping or unwrapping.

Sensitive node metadata is also encrypted client-side. Protocol-v1 metadata envelopes contain NFC-normalized portable filenames, MIME types, plaintext hashes, conflict details, and labels. AAD binds each envelope to its opaque node ID, node type, key scope, and key version. Windows reserved names and non-portable path characters are rejected before encryption, while case is preserved for display and compared through a normalized case-insensitive key.

Recovery uses a random 256-bit printable `HBXR1-...` Recovery Secret that is never uploaded. Clients derive a package key with Argon2id (19 MiB, two iterations), encrypt the User Master Key with XChaCha20-Poly1305, and bind the package to the account's opaque user ID. A server backup alone cannot restore plaintext; recovery requires this secret or an existing trusted device.

**Vault bootstrap** (`core/e2ee/vault_key_store.dart`, `features/vault/vault_setup_controller.dart`) fills in the one step ADR-011/013 described but didn't implement: creating the very first device's vault, with no existing trusted device or Recovery Package to restore from. The Settings page's "Create vault" action generates a random User Master Key and Vault Key together, persists both directly via OS secure storage (the same way the device identity key is stored — at-rest confidentiality comes from the OS layer, not a second wrapping pass), creates the Recovery Secret + Recovery Package, and shows the secret exactly once behind an explicit "I have saved this" confirmation before the dialog can be dismissed. This account's personal vault ID is simply its own opaque user ID; per-folder vault keys and sharing are later milestones (§28).

**The Files page** (`features/files/files_controller.dart`) is the first place this client actually encrypts or decrypts a file, wiring the E2EE core together with the server API end to end: creating a folder or file node, chunking and encrypting a picked file with a fresh random File DEK (wrapped by the vault key), driving the resumable-upload HTTP calls to completion, and — on download — unwrapping the key, re-splitting the downloaded ciphertext blob back into its AEAD frames (storage has no per-chunk delimiters, so the frame count comes from the server's file-version descriptor), decrypting each one, and refusing to save anything whose plaintext SHA-256 doesn't match the encrypted metadata. The `core/e2ee` crypto primitives were exercised only in isolated unit tests before this; `client/test/files/files_controller_test.dart` proves the full loop — including a tampered-blob case — against a fake server.

**The local-first sync engine** (`core/storage/*.dart`, `features/sync/sync_engine.dart`) is what makes folder create/rename/move/delete work offline instead of requiring a live connection for every click. `LocalDatabase` opens a versioned-migration SQLite database per pinned server fingerprint (mirroring the server's own migration approach); `NodeCache` mirrors decrypted-on-demand node metadata for instant, offline-capable browsing; `PendingOperationsStore` is the durable outbox a mutation is written to before (or instead of, while offline) it reaches the server. `SyncEngine` reconciles the two with the server in the background: it pushes ready outbox entries in creation order — an update/delete/restore always waits for its own node's create to be confirmed first, even across retries — classifies failures as permanent (`VALIDATION_ERROR`, `FORBIDDEN`, `NOT_FOUND`, `REVISION_CONFLICT`, `AUTH_INVALID_CREDENTIALS`, which mark the operation failed without retrying) or transient (exponential backoff with jitter, capped at five minutes), and pulls the sync revision feed to catch up on changes made from other devices. File upload/download stay direct, synchronous, online-only calls — transferring the bytes themselves needs connectivity regardless, so queuing them is a documented future improvement rather than part of this slice. `client/test/sync/sync_engine_test.dart` and `client/test/storage/*.dart` cover the ordering guarantee, pull discovery, and both failure classes against a fake server.

The Windows Settings page checks device identity state without creating a key automatically. After explicit confirmation, it creates an X25519 identity whose private key is stored only through Windows Credential Manager-backed authenticated storage. The UI displays a copyable SHA-256 public-key fingerprint while keeping the vault locked until provisioning. Corrupt key records fail closed instead of silently rotating the identity.

Trusted-device provisioning uses ephemeral X25519 and HKDF-SHA256 to derive a one-time wrapping key, then delivers the vault key in the existing XChaCha20-Poly1305 key-envelope format. The derivation and envelope bind the vault, recipient device, key version, ephemeral public key, and random salt. Login without a valid recipient-specific envelope leaves the vault locked.

```powershell
cd client
flutter analyze
flutter test
flutter build windows --debug
```

Windows builds require Visual Studio 2022 with the **Desktop development with C++** workload and the Windows 10/11 SDK.

## Security status

Secure Transport is closed (ADR-008/009/020): TLS 1.3 with self-signed, fingerprint-pinned server identity, and an authenticated login/device/key-envelope API built on top of it. A full opaque-node + ciphertext-upload/download round trip now works end to end from the real Flutter UI down to the Go server and back — create a folder, upload a file, download it, and get the exact original bytes back — proven by both `internal/httpapi/nodes_uploads_test.go` (server side) and `client/test/files/files_controller_test.dart` (client side, including the vault bootstrap this required). Folder metadata mutations now go through a local SQLite cache and durable outbox (`client/lib/features/sync/sync_engine.dart`), so they apply offline and sync opportunistically once connectivity returns. The full product is still not production-ready: cross-account sharing (Family Vault), the Windows filesystem watcher/tray integration and Android client, camera upload, server backup/restore, and maintenance/GC remain roadmap milestones. The server intentionally contains no file decryption implementation to preserve that boundary, and this document's own roadmap sections track exactly what is and isn't built yet.
