# ADR 0002 — Separate metadata and media storage

Status: Accepted · 2026-10-13

## Context

Comic files already exist locally/on private SMB NAS. A Vercel service cannot be assumed to reach a private SMB share or the user's local Ollama host.

## Decision

Node/Mongo stores account-scoped metadata, personal state and eventual operation plans. Apple apps access comic bytes directly, bind logical roots locally and execute file operations on Mac. iPhone creates only private download copies. Mac calls local Ollama; P1 image translation runs a local worker. Tailscale changes device reachability, not storage ownership.

## Consequences

No cloud comic-upload/download proxy, SMB passwords or private physical roots in the metadata API. Native storage bindings may differ across devices while media IDs and relative paths remain stable. NAS authorization is separate from account-scoped app authorization. Offline cache/outbox design must handle metadata and media availability independently.
