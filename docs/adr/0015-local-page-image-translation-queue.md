# ADR 0015: Mac page image translation queue

Status: Accepted · 2026-10-18

## Context

Users run manga-image-translator separately and need its rendered results to appear progressively as a chapter's media translation, with resumable failures, account isolation and safe archive moves. The metadata service cannot access local/SMB media and must not proxy GPU work or provider credentials.

## Decision

Use a Mac-only HTTP client for the upstream multipart image endpoint. Match upstream's static web option catalog; test compatibility through OpenAPI before enqueueing. Keep preferences device-local and capture immutable options/URL per job. Serialize page requests and persist job state/cache in the current verified account's Application Support folder.

Attach each validated PNG to its canonical page slot in a stable target media ID. Preserve existing target pages and missing-page fallback. Reuse FileOrganization's verified copy/revision-checked metadata/finish journal, and reconcile an interrupted per-page commit before retry. Keep generated cache separate from archive paths so preview and retry survive moves. App sign-out cancels client tasks; interrupted running jobs require Retry on restore.

Split Pending Organization into source-only organization, file queue/recovery, translation queue and commit history, with observed queue state in sidebar indicators. Read history away from the main actor.

### Recovery refinement (2026-10-19)

A full-input equality check incorrectly treats unrelated text/tag edits as file conflicts. Image-addition journals now optionally retain their original metadata. On a changed revision, merge only planned media when baseline media and folder-defining fields remain unchanged; preserve all newer descriptions/localizations/tags/NSFW/source links and use the current revision for the write. If desired media is already committed, verify and finish files without rewriting metadata. Genuine media/order/path/parent/title conflicts remain blocked. Legacy journals remain readable. No server/API change is needed.

For old translation jobs only, infer a missing baseline when exactly one owner/chapter/destination/job/cache-page match exists. Removing that single appended slot must leave the current media after applying the journal's exact file moves, allowing only additional append-only target pages already committed in the archive. All baseline canonical mappings must remain unchanged; the requested slot must be empty. Keep the newer target suffix and append the cached page after it. Require unchanged media identity/language/order, no unexplained operations and matching source/cache digests (including shared originals). Use that proof with the normal metadata merge and revision check; never simply assign the current revision to an old plan. Both queue and file recovery actions use it. Without this proof, general legacy revision conflicts remain blocked.

Persist the recovered desired metadata and baseline atomically before staging/API commit, re-reading the journal to reject concurrent changes. If desired metadata changes, retain the initial payload as optional `priorMetadata` for audit. Read the newest journal for each recovery action; completed records are no-ops. A successful recovery closes the sheet and refreshes the queue; errors are prominent and selectable.

The reproduced trigger was an older polling snapshot arriving after a successful per-page metadata update. AppSession now reconciles snapshot entities/states by revision, preserves local creations and deletions completed during the request, and writes the merged snapshot with an ordered cache-write sequence. API update responses also cannot replace a newer local revision. This prevents the next page's organization plan from omitting a just-committed page.

### Incremental organization preparation

An already-organized chapter's next page does not change any existing media paths. Compare those root/path references in memory first, without resolving their filesystem ancestors. Only actual old-file relocations need whole-library sharing detection; only removed originals need old-folder cleanup. Keep the existing verified copy/journal/revision/finish transaction for changed files and report its preparation/copy/save/verification stages separately. This reduces redundant NAS work without introducing a different directory-rename/recovery protocol. It does not claim that multi-version reorganization is now an atomic whole-folder rename, or that the measured warm-cache path-check microbenchmark predicts total NAS transfer time.

## Consequences

There is no new backend worker, database migration, provider SDK or auth scope. iPhone consumes synchronized media metadata and reads finished files normally. The Mac must remain running for translation to progress. Existing translated pages are never silently replaced; source/alignment conflicts stop safely. Model/provider readiness remains the user's external-service responsibility. Source images/PDF pages are normalized using native Apple media APIs; video translation is outside this feature.
