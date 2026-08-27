# ADR-010: E2EE File Chunk Framing

Status: accepted for protocol version 1

## Decision

HomeBox clients encrypt file content with XChaCha20-Poly1305 from the maintained Dart `cryptography` package. A new random 256-bit File DEK and a random 128-bit nonce prefix are generated for every file version. The server never receives either plaintext key material or plaintext content.

The versioned file header is:

```text
magic             4 bytes  "HBXF"
protocol_version  2 bytes  unsigned big-endian, value 1
nonce_prefix     16 bytes  random per file version
```

Each plaintext chunk is at most 4 MiB. Its 24-byte nonce is:

```text
nonce_prefix     16 bytes
chunk_number      8 bytes  unsigned big-endian
```

The authenticated data is:

```text
magic             4 bytes  "HBXC"
protocol_version  2 bytes  unsigned big-endian
file_version_id  16 bytes  opaque UUID bytes
chunk_number      8 bytes  unsigned big-endian
total_chunks      8 bytes  unsigned big-endian
```

The transmitted chunk frame contains ciphertext followed by the 16-byte Poly1305 tag. The nonce is reconstructed from the encrypted file header and chunk index and is not repeated in every frame.

## Consequences

- Chunks can be independently uploaded, resumed, authenticated, and decrypted.
- Reordering, omitting, or changing the declared chunk count invalidates authentication.
- A File DEK and nonce prefix must never be reused for a second file version.
- Authentication failure must stop plaintext materialization before an atomic local replace.
- Binary test vectors are part of the compatibility contract for every client platform.
