# Data migration and file recovery

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
