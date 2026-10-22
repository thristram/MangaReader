# 0013 — Native Mac page selection and staged batch edits

Accepted: 2026-10-17.

Mac All Pages needs familiar multi-selection, range selection and rubber-band
selection while retaining the SwiftUI screen and shared thumbnails. Use a small
AppKit `NSCollectionView` adapter for selection rather than implementing a second
gesture/geometry selection engine in SwiftUI. Reusable cells display the supplied
blue checkmark treatment. iPhone remains a reading/downloading client.

Represent each operation as an unsaved `PageBatchPlan` derived from one chapter
revision and media version. Selection order must not determine translation order;
the version's stored reading order does. Splitting media leaves text locales alone.
Alignment confirmation precedes a separate file-commit review.

Reuse the existing `FileOrganization` journal for verified copies, revision-checked
metadata and source cleanup. Translation uses language directories; Delete uses
retained Recycle copies. No generic deletion journal or server transaction endpoint
is needed because a batch changes one chapter's metadata. Failed/uncertain commits
use the existing Pending Organization reconciliation rather than restarting file
moves. Existing page-position personal-state semantics remain unchanged.

See [behavior and verification](../apple/all-pages-batch-edit-2026-10-17.md).
