# ADR 0018 — Demand-driven synchronization and small mutations

Status: Accepted · 2026-11-01. Supersedes ADR 0005's 30-second full-snapshot
polling. Per-document owner/revision/CAS, tombstones and explicit file commits remain.

## Context

The native apps repeatedly fetched every description, media path/alignment and
personal state even without changes. A state conflict repeated the whole snapshot.
Progressive translation sent an entire chapter for every completed page. Stateless
functions decoded, validated and serialized redundant metadata; a client left open
could exhaust Vercel's transfer allowance without transferring any comic bytes.

## Decision

1. Read an owner-scoped **manifest**, projecting only entity id/revision/deleted and
   state id/revision. Its ETag is a hash of owner plus canonically ordered stamps.
   An equal conditional ETag returns 304 with no body. Use fresh database queries,
   never an instance-local global cursor or public/shared CDN cache.
2. Compare stamps with the account's cached records, then fetch only missing/newer
   IDs. Each request contains at most 100 entity IDs and 100 state IDs. Responses
   budget 3 MB of JSON and return deferred IDs; consume these before proceeding.
   First use with no cache still needs a bounded batched bootstrap. Manifest v2 is
   a latest-state reconciliation protocol, **not** a transaction-backed change log.
3. Publish a multi-batch sync only after every batch succeeds. Merge by revision,
   preserve writes/removals completed while requests were in flight, recognize
   tombstones and manifest absence, and discard responses after account changes.
   Concurrent refresh triggers share one task. Unchanged responses invalidate no
   catalog/UI or snapshot file. Legacy bootstrap is only a rolling-upgrade fallback.
4. Transport changed records with media `pathDirectory` + `pathFiles`, removing
   repeated folder prefixes. Expand to the existing paths on decode and retain
   schema-v1 cache files, storage references, journal plans and download fingerprints.
5. Replace native full entity PUTs with bounded RFC 6902 PATCHes. Use
   `fast-json-patch` server-side; accept add/remove/replace/test only on editable
   metadata fields, forbid identity/kind/prototype mutation, validate the resulting
   full schema/references, and keep If-Match CAS. Return a small receipt. Normalize
   title in that receipt. Common appends use guarded Mongo `$push`/`$set`; overlapping
   operations or array removals fall back to safe replacement semantics. File
   publication and recovery journals still bracket the revision-checked metadata
   operation. An unchanged local field never needs transmitting again.
6. Detail/state lookups select the account and requested ID. Paginated list queries
   filter in Mongo; fetch only their hierarchy/tag dependencies for visibility.
   Deletion checks reference existence without loading all media. Add optional
   covering manifest/list indexes. Old unique owner indexes remain mandatory.
7. Mac refreshes on launch, coalesced catalog mutations, manual refresh, once after
   ten minutes idle and on return from long inactivity. An idle period does not
   cause recurring polls. Input signals contain no keys/coordinates/content.
   iPhone refreshes on foreground and every 120 seconds while active; stop when
   inactive. Failures back off exponentially; respect Retry-After. Explicit manual
   refresh may retry, while automatic triggers cannot hammer a paused service.
8. Coalesce progress for five seconds, send explicit favorite/star actions promptly,
   flush on reader exit/background, and persist latest pending state intentions in
   the owner's `reading-outbox.json`. Persist before Mac termination/background
   suspension. Retain unsent work on transient errors with bounded retry delay;
   terminal validation/auth/payment failures stop automatic retries. A conflict
   reloads **one state**. Each pending entry records exactly which fields changed;
   merge those fields with the latest state before every send, including restored
   outboxes without a conflict. Progress preserves remote favorite/star values,
   and a star action preserves remote favorite/progress values. Do not infer
   progress from maximum page; deliberate rereads can go back.
9. Compress JSON responses larger than 4 KB at gzip level 1. Reduce work/data first;
   compression is supplementary. Bearer credentials and metadata stay private;
   NAS/media/Ollama/image-translation bytes never enter this service.

## Compatibility, limitations and rollout

Mongo documents and API audience/client registration do not change. Deploy the
server first, then update both native apps: old clients remain compatible but still
have their old traffic behavior. Apply the idempotent performance-index migration
locally against the intended database; no data conversion is needed. Keep cached
account snapshots, pending outboxes and file journals. Older apps ignore the new
outbox, so finish pending writes before downgrade or preserve it for an upgrade.

The bounded manifest currently supports 10,000 entities and 10,000 states. A future
transaction-backed change stream is appropriate beyond that scale. Cross-document
reference/delete races, durable metadata edit outboxes and idempotent write receipts
remain separate work. A server write whose response is lost can be reconciled by
revision; the PATCH receipt is not an idempotency key. Fully offline reauthentication
and OS-scheduled background execution are not promised.

These changes do not erase existing Vercel usage or unpause an exhausted account.
Vercel's [paused-account guidance](https://community.vercel.com/t/what-to-do-when-your-team-is-paused-or-blocked/45069)
offers a one-time Hobby boost through support. Other options are waiting for
rolling usage to drop, using an authorized paid plan, or deploying the same API
to a different host you control. No account/limit-bypass mechanism is implemented.
