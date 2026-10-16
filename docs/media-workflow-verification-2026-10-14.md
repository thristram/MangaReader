# Landscape layout, move and comic deletion verification

Updated 2026-10-14.

## Result

- Import preview has a fixed 260 × 350 viewport. Images fit completely without stretching; unused space is transparent.
- The shared thumbnail renderer gets its dimensions from the container rather than the image. Comic, chapter, tag, author and saved-page collections keep consistent cover bounds, preserve image proportions, and center/crop excess image area.
- Moves support different filesystem volumes. A cross-volume move copies into a temporary destination, verifies the file inventory and SHA-256 contents, publishes the copy without overwriting, then updates library metadata. Originals are removed only after metadata commits and the source still matches the verified inventory. Shared sources are retained. Large file work runs outside the main UI thread.
- Failed import retries reuse the chapter created by that import session. Pending Organization can complete metadata/source cleanup after an interrupted move.
- Delete Comic is available from a tile’s context menu and the comic/chapter detail trash button, with confirmation. Work deletion includes its chapters, including hidden chapters, before deleting the parent record.
- As confirmed by the user, add-only imports remove their library records and keep original files. Files archived through the organized library path move to `Recycle/<operation UUID>/<original relative path>` under their verified library folder. Files still referenced by another comic stay in place. Offline copies are retained.
- A rejected metadata deletion restores original paths. If the server commits but its response fails, a fresh sync confirms the result before restoration. Unconfirmed outcomes retain files in Recycle for review. Interrupted operations can restore files or finish deletion in Pending Organization. Restores never overwrite another file.
- Deleting an open detail route returns to its parent collection. Account changes cancel pending actions and prevent cleanup in another account’s cache.

## Checks

- 21 MangaCore tests passed. Cases include copied-move verification, source changes, idempotent completion, shared originals, symlink/traversal rejection, Recycle/rollback/resume, identity mismatches and existing OAuth/API regression tests.
- The actual cross-volume test used a separate temporary APFS disk image, with no forced copy option. It confirmed original preservation before commit and removal after commit, with exact destination bytes.
- Native integration checks passed with the same temporary volume: import → manual destination → cross-volume copy → simulated API metadata commit → source cleanup → Delete Comic → Recycle with identical bytes.
- Native checks also passed for unarchived work deletion without deleting source files, child-before-parent deletion, shared archive files, API rejection/rollback, a failed reply after the server committed, account reset, download queue/retry and the existing reader layout.
- macOS and iPhone simulator builds succeeded. Xcode source/signing/scheme preservation and embedded framework checks passed.
- Native UI inspected with landscape and portrait fixtures: fixed collection cards, complete import preview with transparent space, detail delete action and confirmation text. The destructive confirmation was cancelled; deletion integration used isolated test data and an in-memory API.

These checks make no production API writes and do not delete the user’s comics. Real NAS/SMB hardware was not used; filesystem moves and Recycle require the library folder to be connected locally or through a mounted share. The temporary test volume is unmounted and its disk image removed after verification. Existing working changes, the user’s Xcode scheme and seven unpushed commits are preserved.
