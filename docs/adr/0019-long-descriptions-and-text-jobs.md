# ADR 0019 — Long descriptions, lazy text and local translation jobs

Status: Accepted · 2026-11-02.

The 30,000-character description limit rejected novel source text, eager SwiftUI
text layout delayed chapter opening, and one structured-output inference could
exceed a small model's context/output budget.

Allow 500,000 UTF-16 code units per original/localized description, retaining an
explicit 2.8-MB total metadata / 4-MB HTTP body bound. Preserve the existing Mongo
document/localization model and selective-sync contract. This is deliberately
bounded novel metadata, not an unlimited document/object-store API.

Read from existing owner-local snapshots, cache bounded verbatim display blocks
off the main actor, and lay out blocks lazily. Collections initially show excerpts.
Do not introduce description HTTP fetches or media-path changes on reader open.

Run title/description translation in an owner-local durable queue. Snapshot
global per-model-independent chunk/context/output settings; prefer chapter-marker,
paragraph and full-sentence boundaries. Reject unfit sentences/prompt/output
budgets explicitly. No raw mid-sentence truncation, accumulating chat history,
automatic inference retry or structured-output requirement.

Checkpoint completed chunks before continuing. Publish only a complete ordered
translation through a small revision-checked field update; targeted conflict
recovery preserves source, manual translations and unrelated metadata. Queue
callbacks are account/epoch guarded. Keep jobs independent of editor presentation
and expose progress/retry/cancel in native views. Mac image translation/file
organization queues remain separate.

These jobs require the app to run; OS suspension/termination does not guarantee
background inference. Restart recovers stored work. Exact tokenization, live
translation quality, model-specific context support and unlimited novels are
outside the guarantee. [Behavior and migration](../apple/long-text-translation-2026-11-02.md).
