# ADR-005: Global Monotonic Sync Revision

Status: accepted for protocol version 1

## Decision

`sync_changes.revision` is a single, server-wide, monotonically increasing `AUTOINCREMENT` counter (SQLite `INTEGER PRIMARY KEY`). Every accepted mutation — a node create/rename/move/delete/restore, or a completed file upload — inserts exactly one row and thereby claims the next revision. Clients track `last_sync_revision` and request only changes strictly after it via `GET /api/v1/sync/changes?after=<revision>&pageSize=<n>`.

## Context

§19.2 requires a total order clients can resume from after being offline for an arbitrary period, without missing or double-applying a change, and without the server needing to reconstruct order from wall-clock timestamps (§19.6, §31 — conflict resolution must not depend solely on client clocks).

## Implementation

`internal/uploads.Service.Complete` and every mutating method on `internal/nodes.Service` insert into `sync_changes` and read the revision back via `last_insert_rowid()` inside the same transaction that commits the corresponding blob/file-version/node update (§9.7, §11 — "все metadata mutation и соответствующий sync_change должны коммититься в одной транзакции"), then stamp that same revision onto the affected `nodes` row so a client's `expectedRevision` on its next mutation is checked against exactly the value optimistic concurrency needs. Because SQLite's `AUTOINCREMENT` counter only ever advances, a revision number is never reused even if earlier rows are later deleted by maintenance/GC. `internal/sync.Service.Changes` reads the feed back out, filtered by `user_scope_id` and paged.

## Consequences

- A client can safely persist `last_sync_revision` only after durably applying every change up to and including it (§19.4) — advancing the cursor earlier risks silently skipping a change on crash.
- Because the counter is global (not per-user or per-node), `/api/v1/sync/changes` serves a single ordered feed filtered by `user_scope_id` per row, rather than merging multiple per-scope streams. Widening that filter to cover sharing (multiple users authorized for one change) is a later milestone (§28).
- Client-side cursor persistence and the conflict reconciliation loop (§19.4, §21) remain a later milestone (§43 P0, "incremental sync/outbox/idempotency") — this ADR and its implementation only cover the server's side of the feed.
