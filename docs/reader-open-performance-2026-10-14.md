# Reader opening and mounted-file responsiveness — 2026-10-14

## Report and diagnosis

Mac chapters on local storage or Finder-mounted NAS could appear stuck between selection and the reader. Codebase Memory located LibraryUIModel.open/mediaURL, LocalMedia.url and the native page viewport. Coverage was checked; partial LibraryUIModel/SMBMedia ranges were read directly before editing.

Reader entry already created its context without scanning a whole chapter. Single-entity lookup also called visibleEntities over the entire library, repeatedly traversing unrelated records and their NSFW references before returning one chapter. This can approach quadratic work as the library grows. The remaining native viewport synchronously constructed NSImage/PDFDocument from file URLs on the main actor. Bookmark resolution for read paths also ran on the main actor. The aspect-ratio task reopened the current file/PDF, and PDF overview thumbnails performed synchronous work in SwiftUI tasks.

## Change

- Single-entity lookup first finds its target, then checks only that entity’s inherited visibility. Deleted and NSFW-inherited entities remain hidden. It no longer constructs a full filtered library for each chapter/page lookup.
- NativeReadingPage presents loading/error/retry in SwiftUI and prepares its image/PDF in a detached file task. AppKit/UIKit view adapters receive decoded memory objects and perform no file opening. Cancelled or superseded requests cannot publish stale content.
- ImageIO applies orientation and eagerly decodes on the worker. A 24-million-pixel display budget bounds oversized bitmap memory by pixel count, preserving aspect ratio and avoiding a fixed long-edge limit for strips. Normal images retain dimensions; unusually large scans are downsampled for display and can have less detail at extreme zoom. Original files/export bytes are unchanged.
- PDFs prepare only the selected page. The worker serializes that page into a standalone in-memory PDF before handing it to PDFKit, preventing displayed pages from retaining lazy NAS-backed streams. PDF overview thumbnails render off the main actor as well.
- Description placement uses geometry from the prepared page, removing the separate aspect-ratio file read. A prefetched page publishes its ratio when it becomes current.
- Read-path bookmark resolution is asynchronous and shared across concurrent requests for a root. Resolution neither prompts nor mounts a missing volume. Rebinding, release and account replacement invalidate pending roots and balance security-scoped access. Explicit management paths retain their existing validation.

## Verification

Run after building the Mac target:

```sh
python3 scripts/verify-reader-loading.py .build/xcode-swiftui-mac
python3 scripts/verify-mac-auth-ui.py .build/xcode-swiftui-mac
```

The harness compares old/full-filter and direct lookup on 2,002 synthetic records, checks repeated lookup on 20,002 records, and verifies inherited NSFW, explicit visibility and deleted chapters. This run measured 898.17 ms for the old full filter versus an average 0.83 ms per direct lookup (100 lookups). These are local synthetic CPU lookup timings, not chapter-opening or NAS-transfer timings.

The new isolated native harness verifies that a deliberately blocked file worker leaves the main actor responsive; another page displays before the old read finishes; a cancelled result cannot overwrite it; and the decoded viewport still fills/resizes with its window. Actual file tests cover normal PNG dimensions, a generated 30MP image and the decoded-pixel limit, PDF page selection/rendering after source-document release, corrupt-image/missing-page failures, and concurrent bookmark resolution/reopening after scope release.

Native preview inspection used synthetic media and a separate preview account/API transport. An image chapter resumed at original page 3 while Chinese was selected, then advanced to page 4. A six-page PDF displayed page 1 and advanced to page 2 with matching text/counter. Screenshots/logs remain ignored under .build. The original pager check now presents its window and awaits asynchronous decoding before asserting layout, rather than requiring file access during hidden-window construction.

No user comics, production accounts/API records or real NAS volumes were used. These checks establish responsiveness and rendering correctness, not a measured speedup for the user's NAS. An unavailable volume or slow file transfer can still delay content, while the reader remains responsive. Filesystem calls already in progress may finish after cancellation; their results are discarded.
