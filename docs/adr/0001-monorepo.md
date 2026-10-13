# ADR 0001 — Monorepo with independent applications

Status: Accepted · 2026-10-13

## Context

Mac and iPhone share models/security/reading policies, and the metadata server must evolve with their contract. The auth service already supports other clients and should remain independently managed.

## Decision

Keep `apps/apple`, `apps/server`, `packages/MangaCore`, `packages/api-contract` and shared/component docs in one MangaReader repository. The Node service deploys independently to Vercel; Apple builds/signing/distribution are separate Xcode targets. thristram-auth stays in its own repository.

## Consequences

Schema/UI/server changes can be reviewed together. OpenAPI defines the language-neutral boundary; Swift does not depend on server implementation code. Root npm workspace coordinates server tooling. Apple sample config and server env are separate because their runtime/config/secret models differ.
