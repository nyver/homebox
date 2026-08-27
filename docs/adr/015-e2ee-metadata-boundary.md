# ADR-015: E2EE Metadata Boundary

Status: accepted for protocol version 1

## Decision

The client encrypts the following node metadata before it crosses the trusted client boundary:

- filename;
- MIME type;
- plaintext SHA-256;
- conflict details;
- user labels.

The server may retain opaque node IDs, parent relationships, revisions, timestamps, ciphertext sizes, and ACL routing fields needed for authorization and synchronization. It never receives plaintext filenames or content hashes.

Metadata is encoded as canonical field-ordered JSON and encrypted with XChaCha20-Poly1305 using the current vault or folder metadata key. Every update uses a fresh random 24-byte nonce. The envelope contains:

```text
magic              4 bytes  "HBXM"
protocol_version   2 bytes  unsigned big-endian, value 1
key_version        4 bytes  unsigned big-endian
nonce             24 bytes
ciphertext_length  4 bytes  unsigned big-endian
ciphertext         variable, maximum 64 KiB
mac               16 bytes  Poly1305 tag
```

AAD contains `"HBXN"`, protocol version, key version, node type, 16-byte key-scope ID, and 16-byte node ID. Copying ciphertext to another node, type, scope, or key version therefore fails authentication.

## Portable filenames

Before encryption, both Windows and Android clients apply the same algorithm:

1. Normalize to Unicode NFC.
2. Reject empty names, `.` and `..`.
3. Reject control characters and `<>:"/\\|?*`.
4. Reject trailing dots or spaces.
5. Reject Windows reserved base names such as `CON`, `NUL`, `COM1`, and `LPT9`, including names with extensions.
6. Limit names to 255 UTF-16 code units.
7. Preserve the original normalized case for display.
8. Compare sibling names using NFC-normalized uppercase keys.

Concurrent offline duplicates are resolved after decryption. The opaque node ID remains object identity; a plaintext path is never used as server identity or blob storage address.

## Consequences

- The server cannot search, validate, or deduplicate by plaintext filename or hash.
- Client-side validation must run before every create or rename operation.
- Authentication failure blocks metadata materialization and file placement.
- Future metadata fields can be added inside the encrypted JSON without changing server storage.
