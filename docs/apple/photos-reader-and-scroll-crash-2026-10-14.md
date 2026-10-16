# Photos-style reader, scroll crash and first Mac drop

## Reader controls

iPhone preview has a circular back at top-left, centered chapter title/comic-or-author subtitle capsule, circular description button at top-right, media language at bottom-left, previous/page-count/next in the bottom center and a circular page star at bottom-right. The title opens All Pages in the selected media language. Description uses a compact popover. Mac controls remain unchanged.

Language uses a native inline Picker so every row reserves the checkmark column. Page stars use existing account-scoped personal state and `manga:state:write`. Observable pending state provides immediate feedback and rapid toggles; API sync restores saved stars. Page marks do not change chapter marks. Long-pressing the star retains Favorite Page. This adds no iPhone source-file management.

## Confirmed crash

The connected iPhone's crash report records `EXC_BAD_ACCESS/SIGSEGV` on the SMB queue in `free_smb2fh → close_cb → smb2_destroy_context → SMB2Client.deinit`. The report remains in ignored build output, outside Git/docs.

The vendored wrapper freed file/directory handles during disconnect before pending callbacks finished. A queued CLOSE could release an already freed handle. Disconnect now retains handles until context teardown drains callbacks. Both async wait helpers destroy failed/timed-out contexts before stack-backed callback storage leaves scope. Explicit file close/deinit share an idempotent async-close path, avoiding the C synchronous close waiter's independent timeout lifetime. SMB3 encryption, signing and authentication rules are unchanged.

`scripts/verify-smb-handle-lifecycle.py` uses real libsmb2 clients and socketpairs: five pending CLOSE/disconnect timeouts, five explicit CLOSE timeouts, exactly-once callbacks and repeated close/deinit. No NAS or credentials are used. Existing transport/error/logoff checks remain in `scripts/verify-smb-diagnostics.py`.

Thumbnail presentation state explicitly releases bitmaps on disappearance. Generation checks reject late completions after release. PDF previews also release rendered images; iOS memory warnings purge the shared bitmap cache, and worker decodes use an autorelease pool. These memory improvements are separate from the confirmed SMB crash.

## First Mac drop

The import screen uses an AppKit drop destination and consumes `NSDraggingInfo.draggingPasteboard` inside `performDragOperation`. Security-scoped leases/bookmarks are captured in that callback before scanning or deferred work. The global-drag-pasteboard/SwiftUI-provider fallback is removed. The whole page remains a target and the file picker remains available; opening a picker first is unnecessary.

## Verification and limits

Native Mac checks cover a first pasteboard import without opening a picker, parent leases, disabled drops and existing multi-folder commit/retry behavior. iPhone checks cover immediate/rapid page starring, API snapshot restoration, chapter/page separation and existing fit/paging/large-collection loading checks. Collection tests cover bitmap release, late-result rejection and cache purging. Simulator inspection confirms positions, description popover, star feedback and language-menu alignment.

Synthetic pasteboards do not reproduce every Finder/File Provider sandbox grant. Updated signed apps still need actual first-drop and sustained NAS-scroll acceptance. Harnesses do not modify production files or credentials.

No API, MongoDB, environment or stored-data migration is required. Rebuild both apps to include the UI and embedded AMSMB2 fixes.
