# HomeBox

HomeBox is a self-hosted, zero-knowledge file-storage service for a small family.
Its security boundary is deliberate: clients encrypt file content and sensitive metadata before upload; the server stores only opaque identifiers, encrypted metadata/key envelopes, and ciphertext blobs. It never receives a File DEK, vault key, folder key, user master key, or recovery secret.

This repository currently provides the security-first Go server foundation. The Windows and Android Flutter clients, including the interoperable E2EE implementation and secure transport, are the next milestones from the included roadmap.

## Current capabilities

- Safe YAML configuration with mandatory E2EE and no server decryption mode.
- SQLite database with WAL, foreign keys, and the initial zero-knowledge schema.
- Persistent Ed25519 server transport identity and a SHA-256 fingerprint.
- Argon2id password hashing and a first-admin bootstrap command.
- Ciphertext-only resumable upload domain service with opaque IDs, per-chunk SHA-256 storage checks, idempotent completion, atomic blob commit, and global sync revision creation.
- Health and metrics endpoints.
- A hard plaintext-API guard: all business paths below `/api/` return `426 SECURE_TRANSPORT_REQUIRED` until the Noise/Dart interoperability security gate is completed. This is intentional; a fake or plaintext fallback would violate the specification.

## Run the server foundation

Copy [config.example.yaml](config.example.yaml) to `config.yaml` and choose a durable `storage.path`.

```powershell
go build -o bin/homebox.exe ./cmd/homebox
./bin/homebox.exe fingerprint --config config.yaml
"a-long-unique-password" | ./bin/homebox.exe bootstrap-admin --config config.yaml --username admin --password-stdin
./bin/homebox.exe server --config config.yaml
```

The server exposes only the following cleartext technical endpoints:

- `GET /health/live`
- `GET /health/ready`
- `GET /metrics`

The fingerprint must be verified out of band before a client trusts the server identity. The application business API is intentionally unavailable without the specified authenticated secure transport, regardless of whether TLS is also enabled.

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

The Flutter client is in [client](client). It targets Android and Windows. The Windows UI provides the Files, Sync, and Settings sections, uses the native folder picker to select a local sync folder, and keeps the vault explicitly locked until trusted-device provisioning or Recovery Secret recovery. It does not transmit credentials or files until the secure transport and client E2EE milestones are implemented.

```powershell
cd client
flutter analyze
flutter test
flutter build apk --debug
```

The Android SDK was verified with `D:\usr\android-cli`. Windows builds additionally require Visual Studio with the **Desktop development with C++** workload.

## Security status

The full product must not be treated as production-ready until the roadmap's security gate is closed: a maintained Go/Dart secure-transport pair must be selected, tested with cross-platform vectors, and the Flutter E2EE client must implement client-side key management, provisioning, recovery, and AEAD file framing. The server intentionally contains no file decryption implementation to preserve that boundary.
