# Mac All Pages batch editing

## Usage

Open an image chapter in Preview, choose **All Pages → Edit**, then select the
media language to edit. Click, Command-click, Shift-click or drag a selection
rectangle to select images. Selected thumbnails have a blue border and a blue
circle with a white check, matching the supplied reference. **Select All** and
**Deselect All** operate on the version's current reading order.

**Set as Translation** splits the selected images into a new language version
of this same chapter. Selected images keep their existing reading order, regardless
of selection order or filename sorting. Unselected images remain in their version.
The first window selects the new media language and aligns the selected images
against the remaining original pages. **Use original** leaves an explicit fallback.
Confirm Alignment opens the Commit review with source references, target language
folders and the chosen archive destination. Commit then organizes all versions
using the existing author/series/comic/chapter/language path policy. Cancel at
either step leaves source files and chapter metadata unchanged. A sole version
cannot become its own translation with no original pages remaining; whole-version
language corrections remain in Edit Chapter.

**Delete** opens a Commit review directly. Selected files are copied and verified
into `Recycle/PageEdits/<operation-id>/` in the selected archive before chapter
metadata changes. After confirmation, exclusively referenced source files are
removed; shared files stay in place. These are retained Recycle copies, not a
permanent purge. Deleting every image in a version removes that media entry.
Deleting the chapter's final version keeps its title/description/links with an
empty media list and closes Preview. Physical copies can be recovered from Recycle;
this does not add an automatic metadata-undo action.

This mode is Mac-only and edits image files. The existing Page Order editor and
iPhone/PDF/video reading controls remain available. Native selection works one
media version at a time, making partial language fallback unambiguous.

## Implementation

`MacPageSelectionGrid` uses AppKit's multi-select `NSCollectionView`; SwiftUI hosts
only its reusable thumbnail cells and checkmark presentation. AppKit owns range
selection, modifiers and selection rectangles. `PageBatchPlan` maps physical page
indices through current reading order, removes the selected paths, adjusts remaining
media alignment and builds an unsaved translation version. Text localizations remain
independent; removing original media does not change the original text locale.

Translation commits reuse `organizeChapterFiles` with the staged metadata override.
Deletion uses the same existing `FileOrganization` prepare/stage/metadata/finish
journal, with Recycle destinations instead of language folders. No files are renamed
or removed before Commit. Work uses owner checks, manage scope, revision checks,
destination identity, safe-path validation, shared-source detection and conflict
refusal. Failures retain originals and journaled verified copies; Pending Organization
can resume the exact metadata/file plan. Unfinished work blocks a duplicate move.

When sync changes the chapter during selection, selection clears and asks the user
to review the new pages. A stale open Commit is rejected. After a successful edit,
Preview refreshes the current media and clamps the current page; an empty chapter
closes it. Existing saved marks remain page-position records under the v1 contract;
this feature adds no independent per-image mark identity or state migration.

No server endpoints, OAuth scopes, environment variables or database migration
are added. See [ADR 0013](../adr/0013-mac-page-batch-edit.md).

## Verification

- MangaCore tests cover reading-order preservation, source-index renumbering,
  other-language alignment, partial translation fallback, complete-version deletion,
  preserved original text locale and invalid selection/language/alignment inputs.
- The native Mac harness covers reusable multi-select mapping, prepare/cancel,
  verified translation copies and language folders, shared-image Recycle, deleting
  the final version, stale revision rejection and metadata-failure recovery.
- Native UI inspection selected two images by dragging a rectangle, checked blue
  checkmarks, Select All/Deselect All, Alignment → Commit, and the updated reader
  count. The synthetic original went from six to four pages; the selected two
  appeared byte-for-byte in the new language folder. Delete review and cancellation
  were also inspected; the source file remained in place.

```sh
cd packages/MangaCore && swift test
# From repository root, after the Mac production build:
python3 scripts/verify-mac-auth-ui.py
python3 scripts/verify-apple-project.py
```

All file-operation checks use synthetic local fixtures, not the real library.

## Adding images and deleting whole versions

All Pages now includes **Add Images…**, also available from the chapter editor's
Page Order sheet. Chapter Content can delete entire image/PDF/video versions,
including the final version. File commits and whole-chapter deletion clean up empty
media/chapter directories. See [chapter media editing](chapter-media-editing-2026-10-17.md)
for folder safety, adding content back and recovery behavior.
