# Mac chapter media editing

## User flows

- **Edit Chapter → Chapter Content** shows a trash icon beside every media language, including the last remaining version. It opens **Commit File Changes**; Cancel leaves files and metadata untouched. Commit verifies Recycle copies before removing exclusive originals and the media entry. This also works for a whole PDF or video version, including images excluded from its page alignment.
- Deleting the final version preserves the chapter's title, text translations, links and tags, with no media entries. Its empty physical chapter folder is removed. Add content through **Edit Chapter → All Pages… → Add Images…**, or import a folder as a media translation of that chapter.
- Deleting a chapter recycles its exclusive files and removes its empty language and chapter folders after metadata deletion succeeds.
- **All Pages → Add Images…** opens the native multiple-file image picker. The commit sheet chooses a media language and archive destination. Images append in natural filename order; selected external originals are copied, not moved. Duplicate names receive numeric suffixes, and no existing file is overwritten. Adding another language organizes all versions using the normal author/series/comic/chapter/language path rule. A single version normally omits the language folder.
- The same Add Images entry is available in the chapter's Page Order sheet, including for an empty chapter. PDF/video versions cannot receive image pages in the same language; choose a new media language.

## Storage and recovery

Control-plane changes use the existing chapter update/delete API. The app stages verified copies, commits metadata with its revision, and only then removes exclusive source files and empty directories. Shared originals and folders containing other files are preserved. Cleanup never removes the storage root, author, series or comic containers, never follows a directory symlink and never recursively deletes a nonempty directory. Source-only roots selected directly as an import folder remain storage roots and are retained.

Both organization and Recycle journals carry optional `cleanupFolders` entries. Each entry is a bounded root plus relative directory. `rmdir` atomically refuses a nonempty directory, including one populated concurrently. Cleanup runs deepest first and is idempotent. Pending Organization repeats the same cleanup when completing a recovered operation; rollback restores files and parent directories instead.

Image-add journals also retain account-local security-scoped source bookmarks, so an interrupted copy can be resumed after closing the picker or restarting the app. These bookmarks remain in the local account cache, not the server or metadata synchronization. Existing versions retain media IDs, reading order and text localizations. Appended canonical positions receive explicit fallback holes in other versions; new short translations fall back to original pages.

## Setup and migration

No dependencies, environment variables, API endpoints, OAuth scopes or MongoDB migrations are added. Optional journal fields allow existing journal files to decode unchanged. Old completed journals are not retroactively used to remove directories.

## Verification

Synthetic-file tests cover whole image/PDF/video removal, unaligned files, appending with custom reading order, fallback extension, recreating an empty chapter, duplicate filenames, external-original retention, creating language directories, whole-version directory removal, whole-chapter directory removal, shared-file preservation, stale revision rejection and metadata-failure journals. Storage tests cover bounded cleanup, nonempty folders, symlink/root rejection, journal reload and rollback.

Mac and iPhone build checks cover shared journal compatibility. Native Mac inspection checks Chapter Content trash buttons, deletion commit/cancel and Add Images availability. Tests do not alter the real library or NAS.
