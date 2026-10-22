# ADR 0014: Journal media-folder cleanup and image additions

Status: Accepted · 2026-10-17

## Context

Recycling page files left empty language/chapter directories. Mac users also need to remove the final media version and later add content without recreating chapter metadata. Multiple-file image selection must survive a failed commit after its picker is closed.

## Decision

Reuse the existing revision-checked chapter API and verified organization/Recycle journals. Add optional bounded `cleanupFolders` to both journals, and optional account-local `sourceBookmarks` to organization journals for externally selected images. Finish performs atomic nonrecursive empty-directory removal after metadata is confirmed. Recovery acquires persisted file grants and repeats the same work; rollback restores originals and parent directories. No broad recursive folder deletion is introduced.

Whole-version removal includes all physical paths, independent of reading alignment and media kind. Empty chapter metadata remains valid. Image additions copy originals, append reading order, maintain other-language fallback and organize new language folders in a single file/metadata operation. Existing filename collisions are resolved without overwriting.

## Consequences

Shared or unrelated folder contents prevent directory deletion. Storage roots and author/comic containers are retained. Optional fields preserve compatibility with old journals; no database migration or new service API is needed. Bookmarks stay local and may require selecting sources again if the underlying volume or permissions change. Existing saved marks remain page-position records.
