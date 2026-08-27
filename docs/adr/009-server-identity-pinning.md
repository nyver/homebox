# ADR-009: Server Identity Pinning

Status: accepted for protocol version 1

## Decision

A HomeBox server is identified solely by the SHA-256 fingerprint of its ECDSA P-256 identity public key (`internal/serveridentity.Identity.Fingerprint`), never by a certificate authority chain or hostname. A client must obtain this fingerprint out of band before its first connection and refuses any future connection whose presented certificate resolves to a different key.

## Mechanism

- The server generates and persists `keys/server_identity.key` on first run and never regenerates it afterward (`serveridentity.LoadOrCreate`).
- `homebox server fingerprint` prints the fingerprint for the operator to copy over a trusted channel (SSH, QR code, hand-typed).
- The TLS certificate presented during the handshake (ADR-008) is a self-signed wrapper around that same key, regenerated on every server start. Its serial number and validity window are derived only from the key. Its signature is not deterministic (ECDSA signing uses a random nonce), but this doesn't matter: the embedded public key — the only thing the fingerprint is computed from — is always identical for the same identity key.
- A client validates a connection by parsing the leaf certificate's public key and comparing its SHA-256 fingerprint against the pinned value (`securetransport.PinnedClientConfig` on the Go side; the Flutter client performs the equivalent comparison against the fixed 26-byte P-256 SubjectPublicKeyInfo prefix defined by RFC 5480). Normal CA/hostname validation is replaced by this check, not skipped in favor of no check.
- A fingerprint mismatch is a hard failure (`SERVER_IDENTITY_CHANGED`, §18) with no automatic re-trust and no fallback to an unauthenticated connection.

## First-trust models

Per §15.3, in descending order of assurance:

1. manual fingerprint verification over an independent channel (SSH, phone call);
2. QR code displayed by the server / printed by `homebox server fingerprint`;
3. imported public key file;
4. Trust-On-First-Use — the client accepts whatever fingerprint it first sees and pins it. This is explicitly the least protected option and is only appropriate for a home network where the operator accepts the residual MITM risk during that first connection.

## Consequences

- Losing `keys/server_identity.key` (e.g. restoring from a backup that predates it, or wiping `/data/keys`) invalidates every client's pin; all clients must re-verify and re-pin the new fingerprint. This is intentional — a silently different key must never be trusted automatically.
- The identity key is transport-only. It is never used to derive, wrap, or unwrap any E2EE key material (Vault/Folder/File DEK) — see §10.2 and ADR-011.
