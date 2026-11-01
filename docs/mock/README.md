# UI mock — preserved design baseline

- Open [index.html](index.html) for the standalone interactive Mac/iPhone preview.
- Edit [manga-ui.fragment.html](manga-ui.fragment.html), the original design source preserved from the conversation on 2026-10-13.
- Regenerate the preview from repository root: `python3 scripts/export-mock.py`.
- The preview shell bundles its renderer/icon assets and runs the fragment in a sandboxed frame. It makes no auth, NAS, database or Ollama requests; interaction state is local mock state.

The original mock uses Chinese interface labels from the earlier design rounds. The latest product requirement is **English by default**, implemented in the native app and documented in the UI spec. We preserve the reference source rather than silently rewrite approved designs. Future design edits should update the fragment, regenerate `index.html`, and record changed requirements/status.

The mock depicts the full intended product, including unfinished screens. It is not embedded in either native app and is not an implementation readiness claim. iPhone management controls were removed in the later mock revisions; native iPhone remains a viewing/download companion.

Canonical interaction/page requirements: [Apple UI spec](../apple/ui-spec.md). Actual native coverage: [implementation status](../implementation-status.md).

## Native SwiftUI iteration

The historical HTML design remains unchanged. [Native screenshot gallery](native/index.html) contains real rendered Mac/iPhone fixture previews of the rewritten screens. [Page coverage and verification](../apple/ui-verification.md) describes checks and remaining acceptance. Synthetic covers are clearly labeled; no personal library screenshots or credentials are stored here.

## Image translation native preview (2026-10-18)

Build the isolated preview with `python3 scripts/preview-native-ui.py mac`. Quit that preview, run `python3 scripts/seed-translation-preview.py`, then reopen the generated preview app. Translation Queue shows synthetic completed/failed chapters, progress, descriptions, cached thumbnail grids and native page preview. The seed script only writes `.build/native-ui-preview/fixtures`, and its non-runnable example jobs use an `.invalid` endpoint. No comics are sent to a service. Settings/confirmation use the same real native forms; service connection errors disable enqueueing. See [setup and behavior](../apple/manga-image-translation-2026-10-18.md).

## Import / All Pages / collection controls (2026-10-31)

The real SwiftUI fixture preview is the current iteration surface for this change: `python3 scripts/preview-native-ui.py mac` (or `phone`). On Mac, inspect compact Edit/All Pages tile actions, open the navigation-based All Pages destination, or choose synthetic images in Import & Identify to see the three segmented modes and aligned textbox column to the right of fixed-width labels. Filters live before Mac toolbar search / top-right iPhone navigation. See [current behavior](../apple/spec.md#import-modes-all-pages-navigation-and-unified-filters). The older screenshots/HTML remain a historical reference; regenerate native captures before using them as current acceptance evidence.
