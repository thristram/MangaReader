# ADR 0007 — Explicit, journaled filesystem changes

Status: Accepted · 2026-10-13

## Context

The user requires metadata autosave while filesystem moves happen only after commit. Imports also have a default explicit Add to Library & Move Files action. Network/API failure can occur after physical movement.

## Decision

Separate metadata intent from file execution. Review exact changes and conflict policy before explicit commit. Never overwrite, escape authorized roots or assume metadata updates atomically cover NAS operations. Persist owner-local prepared journal and desired metadata before filesystem change; mark moved/pending metadata, then complete only after the API update succeeds.

The initial mover implements a single same-volume atomic rename. Cross-volume/NAS workflows require verified copy/delete, idempotency and recovery UI before release.

## Consequences

Editing title/author/text/tags alone does not move files. Failed imports must reconcile journal/current files/current revisions before retry. Cover renaming, new media-language directories, Finder tags and bulk reorganization remain staged file operations. The initial API does not execute arbitrary physical paths.

## Application: media language corrections, 2026-10-14

Changing an existing version's language in the chapter editor requires a commit
review. The client reuses `FileCommit` with verified copy-before-commit, saving the
desired language/path metadata in the existing recovery payload. Only after the
revision-checked API update succeeds is the old language folder removed; shared
sources remain available to other chapters. Existing Pending Organization
reconciliation completes interrupted corrections. Text locale changes remain
independent. A single-version chapter keeps its language-free folder.
