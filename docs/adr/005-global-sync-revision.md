# ADR-005: Global Monotonic Sync Revision

Status: accepted for protocol version 1

## Decision

`sync_changes.revision` is a single, server-wide, monotonically increasing `AUTOINCREMENT` counter (SQLite `INTEGER PRIMARY KEY`). Every accepted mutation — today, a completed file upload — inserts exactly one row and thereby claims the next revision. Clients track `last_sync_revision` and request only changes strictly after it.

## Context

§19.2 requires a total order clients can resume from after being offline for an arbitrary period, without missing or double-applying a change, and without the server needing to reconstruct order from wall-clock timestamps (§19.6, §31 — conflict resolution must not depend solely on client clocks).

## Implementation

`internal/uploads.Service.Complete` inserts into `sync_changes` and reads the revision back via `last_insert_rowid()` inside the same transaction that commits the blob/file-version/node update (§9.7, §11 — "все metadata mutation и соответствующий sync_change должны коммититься в одной транзакции"). Because SQLite's `AUTOINCREMENT` counter only ever advances, a revision number is never reused even if earlier rows are later deleted by maintenance/GC.

## Consequences

- A client can safely persist `last_sync_revision` only after durably applying every change up to and including it (§19.4) — advancing the cursor earlier risks silently skipping a change on crash.
- Because the counter is global (not per-user or per-node), a future `/api/v1/sync/changes` reader can serve a single ordered feed and filter by ACL/authorization per row, rather than merging multiple per-scope streams.
- This ADR only formalizes the revision counter itself; the HTTP-level changes feed, cursor persistence, and conflict reconciliation loop remain a later milestone (§43 P0, "incremental sync/outbox/idempotency").
