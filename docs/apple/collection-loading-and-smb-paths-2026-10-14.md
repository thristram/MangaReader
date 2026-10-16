# Collection loading and direct SMB paths

## Report and findings

iPhone collections stuttered during cover loading. Some chapters had missing covers and `STATUS_OBJECT_PATH_NOT_FOUND`, while Mac could open the same files.

The tile path repeatedly scanned the whole catalog and walked inherited NSFW references. Even asking for a single chapter's download status first filtered every chapter. Each cover/cache completion could publish another whole-library update. Quick Look requested up to 1,000 × 1,400 pixel thumbnails without bounded thumbnail concurrency. Scrolled-away cover tasks could leave media requests downloading. File promotion, manifest writes and sync snapshot encoding also ran on the UI actor.

The reported chapter's Mac snapshot contains decomposed Japanese characters. Finder's SMB converter uses composed names when sending filenames and decomposed names when returning them ([Apple source](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/netsmb/smb_converter.c)). The direct SMB client sent snapshot paths verbatim. This explains a compatible failure mode; these tests have not accessed the user's authenticated NAS.

## Implemented behavior

- `LibraryCatalog` builds ID, kind, chapter-parent and inherited NSFW indexes once per metadata change. Cycles preserve visibility semantics. `AppSession` invalidates catalog/state indexes on assignments and in-place edits. Chapter lists preserve all matching records and snapshot order.
- Cover fetches have two permits; page transfers three; thumbnail decodes two; offline manifest checks four. Waiters suspend with cancellation-aware continuations instead of polling. Reading pages retain a transfer slot while both cover fetches are busy.
- Shared requests track consumers. Cancelling a cover removes its consumer; the last cancellation stops the underlying task. A concurrent reader keeps its request alive.
- ImageIO creates orientation-aware thumbnails off the main actor, at most 768 pixels along the longest edge. Quick Look handles PDF/video/unsupported-image fallback. NSCache limits are 128 items/48 MiB (best-effort eviction). Background file-attribute checks invalidate replaced covers.
- Download state updates are batched over 120 ms. An uncached/partial result does not cause a redundant refresh. File promotion, serial manifest merge/write and sync snapshot serialization run outside the UI actor. Manifest merging preserves simultaneous page completions.
- SMB reads first try the stored path. Only `ENOENT` triggers a directory-by-directory lookup under the configured base folder. Raw UTF-8 names win; otherwise exactly one canonically equivalent Unicode name is accepted. Listings use server-returned `nameKey` values. Ambiguous/missing names produce an actionable error. Permission and other network errors propagate.
- Lookup does not modify metadata/NAS files, strip the base folder, recursively search or guess similar titles. Existing component/traversal rules remain. Listing cache is scoped to owner/root/connection, with 64-directory and 30-second limits.

## Validation

`swift test --package-path packages/MangaCore` covers 2,000 chapters, inherited/cyclic NSFW/deletion, exact UTF-8 precedence, Japanese composition differences, ambiguous/missing names, base-folder isolation, permission errors, traversal and permit cancellation.

`python3 scripts/verify-reader-loading.py` and `python3 scripts/verify-phone-reader.py` compile production shared services into isolated native harnesses. They check 10,000 indexed tile queries, UI actor responsiveness while both decode workers are blocked, cancellation of 60 queued covers, cached/replaced images, 768-pixel downsampling, three concurrent downloads surviving a fresh manifest read and batching 100 availability notifications. Existing reader fit/paging/zoom/async-decode checks remain.

Harnesses use synthetic metadata/files/offline downloads, with no real credentials or production API/NAS requests. Simulator tests do not certify physical-device frame rate or every NAS filesystem. Rebuild the iPhone app and retry the affected chapter; a Unicode-only mismatch needs no reimport. If a path remains missing, check the device's share/base folder and whether Mac has pending file organization changes.

## Setup and migration

No server deployment, API contract, environment variable, MongoDB migration or schema change is required. Snapshots/offline manifests remain v1 compatible. NAS credentials stay device-local.
