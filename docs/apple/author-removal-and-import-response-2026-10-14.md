# Author removal and import responsiveness

## Delete an author on Mac

Authors rows offer a trash button and a Delete Author context action; author details also have a delete button. A confirmation explains that works are preserved and reassigned to `other author`. iPhone retains its read-focused interface.

The client refreshes metadata, creates/reuses the fallback author when needed, and updates series, works and chapters in parent-first order using the existing revision-checked API. It includes hidden items. It preserves IDs, hierarchy, descriptions/localizations, sources, media versions/paths, page order and personal state. Author NSFW flags and tags are copied onto affected items so removing their inherited author does not reveal hidden comics. Original author profile links are removed with that author record.

The author record is deleted only after all known references are reassigned; the server also refuses deletion if a concurrent import introduced another reference. This is a resumable sequence of existing API writes, not a database transaction. On failure the author remains, completed changes are retained, and retry refreshes current metadata/revisions before continuing. A referenced `other author` cannot delete itself. An empty author can be deleted without creating a fallback. Management requires `manga:manage`; active imports for the author block deletion.

No media moves, renames or recycling happen during author deletion. Stored paths remain authoritative until an explicit file organization commit. Existing accounts/API endpoints and MongoDB schema need no deployment or migration.

## Import responsiveness

The import page previously used ViewThatFits to construct two full forms, each with its own text fields, dropdown/focus state and previews. It now chooses an AnyLayout from the container width and keeps a single form. The folder strip is a LazyHStack instead of eagerly creating every preview. Dropdown searches stop after seven visible matches, and selected labels use ID lookup. Deleted selections are cleared. Root metadata change detection uses a generation counter instead of constructing an ID/revision string array on each UI update.

Import and media-language commits now resolve bookmarks with the asynchronous, no-mount/no-UI reader path. Destination marker checks, source-sharing checks, canonical path resolution and whole-library reference path comparisons execute off the main actor. Commit confirmation obtains its destination label asynchronously; rendering a text label does not open a bookmark. Copy/verification/journal checks remain in place, including protection for files referenced by another comic.

A short sample of the user's running app was mostly idle, so it did not capture the reported active stall. The fixes address source-verified main-thread I/O and redundant layout work; native tests exercise the affected flow with synthetic data rather than claiming a measured speedup on the user's NAS.

## Verification

Core tests cover parent-first author reassignment, NSFW/tag preservation, unchanged media/localizations and bounded catalog search. Native Mac tests use synthetic API responses with hierarchy checks, injected child-update failure/retry, fallback protection, management scopes and preserved file bytes/page marks.

The native import regression performs a real journaled file commit from a 30-folder batch, leaves the next chapter in the form, adds 2,000 comic choices, checks that only one Comic field exists at narrow/wide widths, and exercises repeated focus/scroll cycles. Existing shared-file, translation, multi-folder, recovery and reader regressions remain applicable. No real NAS files or credentials are used by the harness.
