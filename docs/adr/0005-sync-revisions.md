# ADR 0005 — MongoDB canonical metadata and revisioned synchronization

Status: Accepted · 2026-10-13

## Context

Descriptions/tags/favorites/stars/progress must automatically synchronize across devices without one device silently overwriting another. Vercel instances are stateless.

## Decision

Use MongoDB with compound owner/entity indexes, tombstones and optimistic per-document revisions. The first milestone uses a bounded complete account snapshot and online writes, polling every 30 seconds. A complete P0 sync implementation adds durable client outboxes, idempotent mutation receipts, conflict handling and a transaction-backed per-account change sequence. Do not use an in-process global counter/cursor.

## Consequences

409 requires deliberate reload/merge; progress may move backwards during rereads and cannot always use maximum page. Initial snapshot reads are eventually consistent across collections and unsuitable for unbounded libraries. Offline queued edits, robust retry and atomic multi-document reference changes remain explicit work rather than being inferred from periodic polling.
