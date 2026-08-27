# ADR-013: Recovery Secret and Recovery Package

Status: accepted for protocol version 1

## Decision

The account password authenticates to the HomeBox server and is not an E2EE recovery key. During initial vault setup, the client generates a random 256-bit Recovery Secret and displays it in a versioned printable form:

```text
HBXR1-<43 base64url characters without padding>
```

The secret is never uploaded. The user must keep it offline or in a trusted password manager. The client derives a 256-bit package key using Argon2id with a random 16-byte salt:

```text
memory       19 MiB
iterations   2
parallelism  1
output       32 bytes
```

The package key encrypts the random 256-bit User Master Key with XChaCha20-Poly1305 and a random 24-byte nonce. AAD binds the package version, KDF parameters, opaque user ID, and salt.

The versioned package format is:

```text
magic              4 bytes  "HBXR"
protocol_version   2 bytes  unsigned big-endian, value 1
argon_memory_kib   4 bytes  unsigned big-endian
argon_iterations   4 bytes  unsigned big-endian
argon_parallelism  1 byte
salt              16 bytes
nonce             24 bytes
ciphertext_length  4 bytes  unsigned big-endian, value 32
ciphertext         32 bytes  encrypted User Master Key
mac                16 bytes  Poly1305 tag
```

Decoders reject parameters below the protocol minimum and cap memory, iterations, and parallelism to prevent malicious packages from causing unbounded resource use.

## Recovery flow

1. Restore the ciphertext-only server backup or connect to the existing server.
2. Authenticate the account normally.
3. Import the encrypted recovery package.
4. Enter the Recovery Secret locally.
5. Derive and authenticate the package key locally.
6. Recover the User Master Key and unwrap vault keys locally.
7. Verify decryption and plaintext checksums on the client.

## Consequences

- A server database, blob backup, and server identity key cannot decrypt files.
- Losing every trusted device and the Recovery Secret makes plaintext recovery intentionally impossible.
- Support and server administrators have no master backdoor key.
- Wrong secrets, modified packages, and packages moved to another account fail authentication.
- Temporary secret and key buffers are overwritten after use when the runtime permits it.
