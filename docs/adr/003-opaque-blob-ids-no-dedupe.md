# ADR-003: Opaque Blob IDs and No Server-Side Deduplication

Status: accepted for protocol version 1

## Decision

Every uploaded ciphertext blob is stored under a random, client-generated opaque ID (UUID), never under a content hash. The server performs no cross-user or cross-version deduplication of file content.

## Context

A content-addressed store (path derived from `sha256(plaintext)`) is the conventional way to deduplicate storage, but it requires the server to know the plaintext hash — which it must never learn under the zero-knowledge model (§2.2, §10.1). Even a ciphertext-hash address would leak equality information (two uploads with the same address are the same plaintext) across a household of five users, which the specification explicitly rejects for a security-privacy trade-off that isn't justified at this scale (§10.8, §43 P2).

## Implementation

`internal/uploads.Service.Create` requires a client-supplied, random `BlobID`; `Complete` writes the assembled ciphertext to `blobs/<blob-id>.hbxblob` and records `blobs.ciphertext_sha256` purely as a storage/transport integrity check (§12.6), not as a lookup key. Every new `FileVersion` gets its own blob, even if the plaintext is byte-identical to an existing one.

## Consequences

- Storage usage scales with total uploaded versions, not distinct content — acceptable at the specified scale (≤5 users, ≤30 devices, §36.2).
- Client-side local duplicate detection for UX (e.g. camera upload skipping already-uploaded photos, §26) is unaffected; it happens before any network call and never changes server-side addressing.
- A future keyed-digest dedupe scheme scoped to a single vault (§10.8) would need its own ADR and security review before implementation.
