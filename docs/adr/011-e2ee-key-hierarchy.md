# ADR-011: Client E2EE Key Hierarchy and Envelopes

Status: accepted for protocol version 1

## Decision

All HomeBox E2EE keys are random 256-bit values generated on trusted clients. Account passwords remain limited to server authentication and are not file-decryption keys.

```text
Recovery Secret
  -> protects a recovery package

User Master Key
  -> wraps vault keys and private account material

Vault or Folder Key
  -> encrypts sensitive metadata
  -> wraps per-file DEKs

File DEK
  -> encrypts one immutable file version
```

The server stores only encrypted envelopes. Protocol-v1 envelopes use XChaCha20-Poly1305 with a fresh random 24-byte nonce. Their binary format is:

```text
magic             4 bytes  "HBXK"
protocol_version  2 bytes  unsigned big-endian, value 1
purpose           1 byte
key_version       4 bytes  unsigned big-endian
nonce            24 bytes
ciphertext       32 bytes  encrypted key
mac              16 bytes  Poly1305 tag
```

Envelope AAD contains `"HBXA"`, protocol version, purpose, key version, the 16-byte scope ID, and the 16-byte subject ID. For a File DEK, the scope identifies the vault/folder key and the subject identifies the file version. For device provisioning, these fields identify the vault and recipient device.

## Consequences

- Moving an envelope to another vault, file version, device, purpose, or key version invalidates authentication.
- The server can authorize delivery but cannot unwrap an envelope.
- Removing a member prevents future envelope delivery but cannot revoke keys already obtained by that member.
- Revocation requires a new vault/folder key for future versions and client-side rewrapping where appropriate.
- Extracted key bytes exist only in bounded client memory and are overwritten after use when the runtime permits it.
