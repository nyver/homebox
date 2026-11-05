# ADR-022: Client-Side Sync Conflict Resolution

Status: accepted

## Decision

Conflicts (spec §21) are resolved entirely on the client, under one rule: **no sync step may destroy content the server does not have.** The server is unchanged; it keeps enforcing optimistic concurrency (`expectedRevision`) on every node mutation and upload, and it cannot take part in resolution because names and content hashes are end-to-end encrypted.

## Context

Before this decision the Windows sync folder could lose data in three ways: a pull overwrote a locally edited file with a newer server version, a pull deleted a locally edited file whose node was deleted elsewhere, and a local-change scan (which runs before the pull) uploaded an edit made on an older version over a newer one. In the outbox, a second offline change to the same item failed with a self-inflicted `REVISION_CONFLICT`, and any rejected rename/move/delete was dropped silently.

## Implementation

**Sync folder.** `materialized_files` now records the plaintext SHA-256 of the version last written to (or read from) each local copy. `localCopyMatchesRecord` proves a copy untouched by an unchanged size and timestamp, or by that hash. `SyncFolderMaterializer` replaces or removes a local file only when this holds; otherwise it renames the file to `<base> (conflict - <device> - <YYYY-MM-DD HH-mm-ss> UTC)<ext>` in the same folder (a short random suffix is added if that name exists). `LocalFolderUploader` refuses to upload a file not based on the node's current version and keeps it as a conflict copy the same way. A conflict copy is uploaded as a new node whose encrypted `conflictDetails` names the original file, the device and the reason. During a pass, a path already claimed by another node's record is never moved or deleted on behalf of the previous occupant (two files swapping names), and case-only renames are recognized on case-insensitive file systems.

**Outbox.** `SyncEngine` re-reads each operation before pushing it and, after a successful mutation, moves later operations queued on the same base revision onto the new one. A `REVISION_CONFLICT` on an update is passed to an `OutboxConflictResolver`. Update payloads therefore also carry the node's parent and encrypted metadata as the change saw them. `VaultOutboxConflictResolver` decrypts base, local and server metadata. It replays a rename when the remote side did not choose a different name, re-encrypting the server's current metadata so a concurrent content update's hash and size survive. It replays a move when the remote side did not move the item elsewhere. In every other case the server state wins. A rejected delete keeps the item (DELETE vs UPDATE/RENAME); a delete of an item already deleted elsewhere is settled. A replayed operation gets a fresh `operation_id` (ADR-006). An operation re-resolved more than three times in one pass is settled in favor of the server.

**Reporting.** Every resolution is recorded in the local `sync_conflicts` table, exposed through `SyncConflictLog`, listed on the Sync page and badged on its navigation icon. Dismissed rows are pruned to a bounded history.

## Consequences

- Concurrent edits produce visible duplicates rather than silent loss; the user merges them and uses **Mark conflict resolved** (or deletes the copy).
- Only the local trusted database stores conflict file names in plaintext, alongside the sync-folder paths it already held; the server sees conflict copies as ordinary opaque nodes.
- Outbox entries queued by older clients lack the base fields and are never replayed; their conflicts keep the server state and are reported.
- Android's write-only SAF mirror is not edited through HomeBox and keeps its previous replace/delete behavior.
