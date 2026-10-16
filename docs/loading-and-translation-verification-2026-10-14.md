# Loading and translation organization verification — 2026-10-14

## Behavior

- Covers resolve one file asynchronously, without scanning other chapter pages. A progress indicator is displayed during file resolution and thumbnail generation. Generated thumbnails are shared through a bounded 64 MiB / 96-item memory cache.
- Reader entry creates the reading context immediately. The current and neighboring pages resolve individually; iOS pages farther away do not request files. Mounted/local files are read directly. App-managed SMB connections download only requested files, with up to three page requests alongside the existing explicit offline-download queue.
- Successfully downloaded pages are recorded individually and reused by reading or a subsequent full download. Partial caches are distinguished from complete offline downloads. Cache manifests, media fingerprints and completed-download availability are memoized; filesystem checks run off the main actor for visible pages and offline availability.
- Destination selection and commit use one sheet. Selection defaults to the previous destination, the existing chapter's destination, or the first registered destination. Commit dismisses the sheet immediately and freezes the import's metadata in a separate worker owned by the background file queue. Leaving the import screen releases only that screen's scopes, not the worker's scopes.
- Adding a moved media translation organizes every version under `author/[series]/[comic]/chapter/language/filename`. Existing flat files are staged into the original language folder and new media into its own folder. All copies are verified before the chapter's final paths commit. Originals are cleaned up after the metadata commit; files referenced by other comics remain in place. Existing organized files with unchanged paths are preserved.
- Language organization writes a single recoverable plan with file digests and metadata revision. Pending Organization can resume copies and finish a metadata commit or verified source cleanup. Queue errors remain visible, with retry; successful recovery updates the failed queue item.
- `No text` is a distinct media-language option (`zxx`), displayed by name in the importer and reader. It does not add a new API field or require a backend migration.
- Chapter cards expose Delete Chapter in their context menu; the reader options menu also exposes it for managers. Confirmation deletes only that chapter. Unarchived originals remain; exclusively owned archived files go to Recycle. Parent comics, siblings and shared files remain.
- Each author has an expand/collapse control showing that author's comics in the existing collection grid.

## Verification

- macOS and iPhone simulator targets build successfully with code signing disabled.
- MangaCore suite: 23 tests executed, 22 passed, 1 optional actual-second-volume test skipped. This run did not mount a second volume; the prior media-workflow verification documents the actual cross-volume check.
- Core regressions cover staging both language folders before cleanup; interruption/resume; shared-source preservation; changed-source refusal; idempotent finalization; and No text labeling.
- Isolated native checks pass against an in-memory API transport and synthetic files: a cover still loads with an unrelated page missing; a single requested page is cached; a subsequent full download reuses that cached page after its original source is removed; reader entry does not gather whole-chapter URLs; background import completes after closing the import model; later UI edits cannot change queued metadata; adding a translation relocates both original and translated files into language folders with exact bytes; deleting a chapter preserves its parent and sibling.
- Previous native checks also pass for download failure/retry/progress, archived and unarchived deletion, Recycle/shared-file protection, API rejection rollback, account reset, tag editing, destination removal and pager resizing.
- Both app bundles pass embedded-framework packaging checks. Xcode project generation/source membership checks pass.
- Native preview visually confirms expanded author collections and the No text picker. UI automation disconnected while opening the merged commit sheet, preventing the final modal screenshot; its commit/queue behavior was verified by the native model checks.

## Limits

No production account, API records, user manga files, or secrets were used during verification. Real NAS latency and native SMB transfers were not measured in this run. File organization uses a locally connected destination or mounted SMB folder, as the existing import mover does. The runtime queue continues across closing the sheet or leaving the import page; quitting the application stops it. Started language organization remains recoverable from its journal, while not-yet-started queue items are currently held in memory.
