# Data migration and file recovery

## Translation recovery upgrade (2026-10-19)

No MongoDB migration or API change is required. New image-addition organization journals include optional `originalMetadata` in the existing account-local journal JSON. Existing journals decode without that field. Recovery preserves newer descriptive metadata when the baseline proves media and folder-defining fields unchanged; already-committed media can finish without any metadata write. For old translation jobs, Retry or file recovery can infer the baseline from a unique persisted job/cache page plus the exact journaled file moves and verified digests. Additional append-only target pages already committed are retained, provided baseline canonical mappings are unchanged and the pending slot is free. The rebased metadata/baseline is written atomically before its API update; optional `priorMetadata` keeps the initial desired payload for audit and also decodes as absent on older records. Other legacy revision conflicts still need review. Keep cached translated images, job records and journals; do not delete them or re-import the chapter to retry.

## Existing comic folders → MangaReader

Initial import does not assume existing folders already match the managed hierarchy. On Mac, select/drop a root and review discovered chapter candidates sequentially. Natural image filename ordering initializes reading order; author/work/series can be resolved manually. Unknown author becomes `other author`. PDF/video each remain a single chapter source file.

Start with Add without moving for an unfamiliar library, verify page order/count and metadata, then use a reviewed explicit organization commit once that workflow is complete. The first milestone only exposes import-time same-volume moves; later reorganization plans remain pending. Never treat the UI mock's pending-plan page as an implemented tool.

The primary import action explicitly commits an import move. It never happens merely because author/title/tag/description edits autosave. Text localizations do not duplicate original media or create language subfolders. Adding a second **media version** requires an alignment and both-version move plan in the completed product; that wizard is pending.

## MongoDB schema v1

Collections `entities`, `states`, `schema_migrations`. Migration v1 creates:

- entities: unique `(ownerId,id)` and `(ownerId,kind,deleted)` list index;
- states: unique `(ownerId,id)`;
- version record `schema_migrations._id = v1` after indexes succeed.

Sample values are not credentials. Configure a dedicated database before applying:

```sh
npm run db:migrate                 # dry run; no database access
npm run db:migrate -- --apply      # after backup
```

The script is idempotent for already-created v1 indexes. It does not import user files, change auth schema, or deploy anything. Creation uniqueness and revision CAS rely on these indexes. Fix any existing duplicate `(ownerId,id)` entries from pre-migration experiments before rerunning; never deduplicate across different owners.

## Backup / upgrade procedure

1. Stop management writes or otherwise obtain a consistent database backup with your MongoDB hosting tools. Back up original local/NAS files separately; MongoDB contains no comic bytes.
2. Export/copy metadata database plus account-local bookmarks, snapshots and commit journals. NAS passwords remain Keychain secrets; do not put them in a shared dump.
3. Run migration dry-run, inspect expected version and target database, then apply once.
4. Verify migration record and indexes, run health plus authenticated owner-scoped CRUD/snapshot checks, then resume clients.
5. For a future schema migration, test on a restored copy, preserve ownerId and media UUIDs and migrate native cache/outbox versions before decoding new fields. Backward-incompatible contracts require API versioning.

v1 is index-only; rollback normally means restore the prior metadata backup and prior service/client version. Do not remove the owner/entity unique indexes while a writer is running. There are no automatic destructive down migrations.

## Mac commit journals

Account directory: `Application Support/MangaReader/accounts/<ownerId>/commit-journals/`.

`<id>.json` records source, destination and phase. `<id>-metadata.json` records chapter entity ID, expected revision and the desired post-move metadata. **Both are written before the filesystem rename.**

| Phase | Recovery meaning |
| --- | --- |
| `prepared` | Move may not have occurred, or the process may have died after rename before phase update. Inspect both paths. |
| `filesMoved_metadataPending` | Files moved; metadata API update/acknowledgement is not yet recorded. |
| `complete` | Files and metadata update completed. Retain journal for audit/recovery policy. |

Recovery is manual in this milestone; do not repeatedly click import to create duplicate chapter records:

1. Sign in to the same verified account. Compare journal paths, actual source/destination existence, content and the chapter's current API revision.
2. If only source exists, metadata should continue pointing at source. Review the plan again before deciding to retry.
3. If only destination exists and contents are correct, load the recovery payload. If the chapter's revision is unchanged, replace its metadata with the payload using that revision. If revision changed, merge current metadata deliberately; preserve newer translations/tags/state.
4. If both/neither exist or contents differ, stop and reconcile from backup before any copy/delete. Never overwrite a conflicting destination.
5. Mark complete only after API snapshot references the correct existing files. Do not delete the source to “finish” an uncertain operation.

Same-volume rename only is implemented. Cross-volume moves, NAS-native operation journals, preflight collision alternatives, file hashing, mutation-id idempotency and a recovery UI are still required for the full management release.

## Native cache / downloads

Schema v1 snapshots are owner-specific. Logout hides the retained account cache and deletes OAuth credentials; a new account never imports another account's snapshot/bindings. The first milestone verifies account online on relaunch, so fully offline re-entry is pending.

SMB downloads are private copies keyed by media UUID and root/path-order fingerprint. Partial files never publish a completion manifest. Changing media paths/order invalidates a manifest; this initial version does not detect changed source bytes at an unchanged path. Future download manifests need size/mtime/hash validation and explicit storage cleanup/migration.

Downloads can be rebuilt from NAS; source files and metadata must be backed up independently. Mark large media directories excluded from platform backup before distribution. Public IDs/ownership never change just to reorganize filesystem paths.

## SwiftUI presentation update

No database or snapshot schema migration is required. Existing owner directories, root bookmarks, Keychain bindings, media IDs and revisions remain valid. Reader order/alignment uses the existing pageAlignment field; saving order does not rename files. Separate cover files and bulk filename/organization plans remain pending. Preserve account commit journals during upgrades; Pending Organization can reconcile a filesMoved_metadataPending record only when the source is absent, destination exists and metadata revision still matches.

## Mac image translation jobs

No database migration is required for the optional page translation feature. Jobs/rendered-page caches live under the current owner's local `image-translations` folder; per-page archive commits use compatible organization journals. Preserve both when moving an unfinished library to another device. Running jobs restored after an app restart require Retry; successful pages and cached results are reused. The external translator's models, provider keys and deployment are managed separately.

## Organization identity journals — 2026-10-22

No MongoDB or metadata-cache migration is required. Optional per-file identity/rename and destination-folder fields support same-volume organization; old journals retain SHA checks. New plans include original metadata. Complete pending new work before using an older app. After a failed metadata write, renamed files can already be at their recorded destination: use File Management Queue recovery, not a fresh import. See [ADR 0017](adr/0017-same-volume-organization.md) for identity mismatch and interrupted-SMB handling.

## Commit performance journal extension — 2026-10-31

No MongoDB/API migration or library reimport is required. Organization file entries
may include `copySourceIdentity` / `publishedCopyIdentity`; Recycle entries may
include `identity` / `publishedIdentity`. These are optional object guards, separate
from media metadata. Old SHA-only journals remain readable and recoverable. Keep
owner-specific journals and Recycle files during upgrades; finish pending new
operations before downgrading. The completed-journal index is disposable in-memory
state and requires no migration. See [ADR 0017](adr/0017-same-volume-organization.md).


## Demand-driven sync / small updates — 2026-11-01

No document conversion, OAuth registration or audience change is required. Apply
`npm run db:migrate -- --apply` against the intended database to add covered
owner/id/revision manifests and kind/work/author/state pagination indexes. Existing
owner uniqueness indexes and v1 migration identity remain; rerunning does not
rewrite the existing marker's timestamp. This migration is additive and leaves
comic metadata/files intact. Standard backup policy still applies to database work.

Deploy the server before both native clients. New clients keep a legacy endpoint
fallback during rolling upgrades; old clients remain compatible but keep their old
traffic pattern. Manifest transport is version 2; cached `snapshot.json` stays at
schemaVersion 1 and expands compact media paths on decode. All root IDs, media IDs,
relative paths, alignments, download fingerprints and file journals remain valid.

New owner-local `reading-outbox.json` holds latest unsent state intentions, with
progress-only merge semantics. Preserve it with the account cache during device
migration; do not copy it into a different account. Finish pending state writes
before downgrade, or retain the file for the next upgrade. Older builds ignore it.
The change is not a transaction-backed log or an offline metadata editor. See
[ADR 0018](adr/0018-demand-driven-sync-and-small-mutations.md).
