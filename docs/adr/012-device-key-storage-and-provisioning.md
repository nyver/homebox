# ADR-012: Device Key Storage and Trusted-Device Provisioning

Status: accepted for protocol version 1

## Decision

Each HomeBox installation creates a local X25519 device identity. Only its 32-byte public key may be registered with the server. The versioned private-key representation is stored through `flutter_secure_storage` and is never written to the application database, configuration, logs, or server storage.

- Windows protects the storage encryption key through Windows Credential Manager and stores authenticated ciphertext in the application support directory.
- Android protects the storage encryption key through Android Keystore and stores authenticated ciphertext in the application sandbox. Android cloud backup is disabled so encrypted preferences cannot be restored without their non-exportable device key.

The in-memory identity must be destroyed when the vault locks or the client exits. Corrupt secure-storage data is a hard error and never causes silent identity rotation.

An existing trusted client provisions a random 256-bit vault key to a target device with an ephemeral X25519 key pair:

```text
shared_secret = X25519(ephemeral_private_key, recipient_public_key)
wrapping_key  = HKDF-SHA256(shared_secret, random_salt, context)
envelope      = XChaCha20-Poly1305(wrapping_key, vault_key, AAD)
```

The HKDF context binds the protocol version, vault-key version, opaque vault ID, opaque recipient-device ID, ephemeral public key, and salt. The nested key-envelope AAD independently binds its provisioning purpose, key version, vault ID, and recipient-device ID. All-zero X25519 shared secrets are rejected.

The outer protocol-v1 format is:

```text
magic                 4 bytes  "HBXD"
protocol_version      2 bytes  unsigned big-endian, value 1
ephemeral_public_key 32 bytes  X25519
hkdf_salt             16 bytes
wrapped_vault_key     83 bytes  protocol-v1 "HBXK" envelope
```

## Provisioning flow

1. The new device authenticates to the server, creates its device identity, and registers only its public key.
2. The vault remains locked until provisioning succeeds.
3. A trusted device verifies the target device out of band, obtains its public key, and uploads the recipient-specific envelope.
4. The target downloads only its envelope and unwraps it locally with its device private key.
5. Device revocation stops token and future-envelope delivery. Keys already obtained by a compromised device require vault-key rotation for future data.

Recovery Secret provisioning remains the independent recovery path described by ADR-013.

## Consequences

- Account login alone never grants E2EE access.
- The server cannot derive the shared secret or unwrap the vault key.
- Copying an envelope to another vault, device, or key version fails authentication.
- Losing both all trusted devices and the Recovery Secret makes recovery intentionally impossible.
- OS secure storage reduces key exposure at rest but does not protect an unlocked client process from a fully compromised operating system.
