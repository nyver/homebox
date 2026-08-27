# ADR-008: Secure Transport Protocol and Library Choice

Status: accepted for protocol version 1

## Decision

Secure Transport is TLS 1.3, terminated directly by the HomeBox server process, using a self-signed certificate whose key is the server's existing ECDSA P-256 identity key (`internal/serveridentity`). Clients trust this certificate by pinning the SHA-256 fingerprint of that public key out of band — never through a certificate authority.

## Context

The specification originally called for `Noise_NK_25519_ChaChaPoly_SHA256` (§15.2) specifically so a home server on a bare `http://host:custom-port` could be trusted by fingerprint instead of requiring a CA-issued certificate. The specification's Security Gate requires a mature, actively maintained implementation on both platforms before adoption, and explicitly forbids a hand-rolled protocol (§15.2 point 4) or an unvetted library (§35.15).

`flynn/noise` is a mature, widely deployed Go implementation (it backs Tailscale's control protocol). No comparably mature Dart/Flutter Noise implementation exists: the only package on pub.dev is a small, single-maintainer port with negligible adoption. Adopting it would make this the one cryptographic dependency in the whole stack that fails the project's own maturity bar.

The specification anticipates exactly this outcome and prescribes the resolution (§15.2 point 5): do not hand-roll a protocol; fall back to an HTTPS-equivalent transport until a proven cross-platform library exists.

## Why TLS instead of "just require a real certificate"

Requiring operators to obtain a CA-issued certificate (or run a reverse proxy) would remove the "direct HTTP + app-layer encryption on a bare port" deployment mode (§7.1) that the specification treats as a first-class scenario for home users without a domain name. Reusing the server's own identity key as a self-signed certificate, verified by fingerprint instead of a CA chain, preserves that deployment mode and reproduces the exact trust model the specification described for Noise:

- the server exposes a stable fingerprint via `homebox server fingerprint`;
- the operator verifies it out of band once (SSH, QR code, etc.);
- the client pins it and refuses any future connection presenting a different key (ADR-009);
- there is no downgrade to plaintext under any configuration.

Both platforms implement this with their own mature, standard TLS stack — Go's `crypto/tls` (stdlib) and Dart's `dart:io` TLS layer (BoringSSL, bundled with the Dart SDK on every platform including Windows — it does not depend on or route through the OS-native TLS stack). No custom handshake, key exchange, or AEAD framing is implemented by this project for the transport layer.

## Identity key algorithm: ECDSA P-256, not Ed25519

The first implementation of this ADR used an Ed25519 identity key, matching the algorithm the original Noise proposal would have used. Empirically testing a real Dart TLS client against the real Go server found that **Dart's bundled BoringSSL TLS client rejects an Ed25519 server certificate outright**, failing the handshake with `HANDSHAKE_FAILURE_ON_CLIENT_HELLO` before the certificate is even inspected — Dart's client does not advertise Ed25519 among its supported signature algorithms. Go's `crypto/tls` and OpenSSL both accept the same certificate without issue; Ed25519 support is simply not universal across TLS 1.3 stacks.

The identity key algorithm was changed to ECDSA P-256, which is supported by every stack this project targets — verified with a live Go server and a live Dart client completing a real handshake, and (as a side effect) also restored compatibility with Windows' native Schannel TLS stack, which does not support Ed25519 either but does support P-256. Nothing else about the design changed: the fingerprint is still `sha256` of the canonical public-key encoding (`internal/serveridentity.FingerprintFromPublicKey`), computed identically by the server, the Go pinning helper, and the Flutter client's fixed-prefix SubjectPublicKeyInfo extraction (RFC 5480 for P-256, rather than RFC 8410 for Ed25519).

**Lesson recorded for future ADRs in this space:** verify a cross-language TLS/crypto decision with an actual client-library-to-actual-server-library handshake before treating it as settled — a spec compatible in theory (both platforms support "TLS 1.3") can still fail in practice over an algorithm-level detail neither platform's own conformance suite would catch on its own.

## Consequences

- `internal/securetransport` builds the self-signed certificate from the identity key with a fixed validity window; the certificate's *signature bytes* are not deterministic across restarts (ECDSA signing uses a random nonce), but the embedded public key — and therefore the pinned fingerprint — is always identical for the same identity key, which is the only property clients actually depend on.
- `security.application_encryption.protocol` records `"tls1.3-ecdsa-p256-cert-pinning"`, superseding both the original `Noise_NK_25519_ChaChaPoly_SHA256` proposal and the initial Ed25519-based TLS implementation.
- If a mature cross-platform Noise implementation later emerges, this decision can be revisited in a new ADR without changing the server's E2EE data model, since Secure Transport and E2EE are independent layers (§15.1).
