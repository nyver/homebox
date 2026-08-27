# ADR-004: Opaque Node Identity, Not Filename or Path

Status: accepted for protocol version 1

## Decision

A file or folder's identity on the server is its `node_id` (a random, client-generated UUID). The server never derives identity, uniqueness, or routing from a filename or path, because it never sees either in plaintext.

## Context

`nodes.metadata_ciphertext` (§12.5) holds the client-encrypted filename, MIME type, and other sensitive metadata (ADR-015). A server that cannot decrypt a name cannot enforce sibling-name uniqueness, case-insensitive comparison, or path-based lookups the way a conventional filesystem-backed service would.

## Implementation

- `nodes.id` is the only identifier used in every server-side relationship: `parent_id`, `current_version_id`, ACL rows (`shares`, `favorites`), and sync routing (`sync_changes.node_id`).
- `internal/uploads.Service` authorizes and mutates a file strictly by `target_node_id`; it has no filename parameter anywhere in its API.
- Two clients independently creating a same-named child under the same parent while offline is only detected after both sync and each client decrypts the sibling's name locally; conflict resolution then assigns a deterministic suffix (§21, §30) rather than the server rejecting the second create at write time.

## Consequences

- Portable-filename validation (reserved names, trailing dots/spaces, Unicode normalization) must be enforced identically by every client before encryption (§30), since the server cannot validate what it cannot read.
- Renames and moves are cheap, atomic metadata updates to the same `node_id` — never a delete-and-recreate — which keeps version history, shares, and favorites attached to the right object across a rename.
