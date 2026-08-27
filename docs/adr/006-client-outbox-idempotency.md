# ADR-006: Client-Generated Operation IDs and Idempotent Mutation

Status: accepted for protocol version 1

## Decision

Every client-initiated mutation carries a client-generated `operation_id` (UUID). The server records the outcome of each `operation_id` it has ever completed (`processed_operations`, §12.9) and replays the stored result instead of re-executing the mutation if the same ID arrives again.

## Context

A client on an unreliable home network cannot tell a lost response from a lost request: after a timeout it must retry, but a retry that re-executes a completed upload/commit would either duplicate a `FileVersion` or corrupt the revision sequence (§19.5, §36.1 — "retry mutation не должен дублировать действие"). The ID must be client-generated (not server-assigned) because the client may create it while offline, before any server round-trip exists (§14).

## Implementation

`internal/uploads.Service.Complete` checks `processed_operations` for the given `operation_id` twice — once before acquiring the write lock (fast path) and once again inside the transaction (race-safe path) — and returns the previously stored `(blob_id, file_version_id, revision)` unchanged if found, without touching storage or `sync_changes` again. A brand-new completion writes its result into the same row within the same transaction that creates the blob/file-version/node update, so the recorded result and the actual mutation can never disagree.

## Consequences

- Retrying a `Complete` call after a network blip is always safe and returns byte-identical output to the original call.
- This pattern is the template the roadmap's node CRUD and sync-mutation endpoints must follow: any future mutating endpoint needs the same client-supplied `operation_id` and the same check-then-transactional-recheck shape, not a bespoke idempotency mechanism per endpoint.
- `processed_operations` rows expire (`expires_at`) and are swept by maintenance/GC (§33) — a client must not assume idempotent replay works for a retry arriving after that window; by then the client's own outbox/retry policy should already have surfaced the failure.
