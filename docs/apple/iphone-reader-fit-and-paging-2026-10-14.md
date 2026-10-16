# iPhone reader fit, paging and full-screen layout

## Report and behavior

The user confirmed SMB connection succeeded, then reported cropped wide pages
at minimum zoom, unsatisfactory horizontal transitions and a black strip above
full-screen media. The old viewport sized images/PDFs to the viewport height;
wide pages therefore overflowed horizontally even at minimum scale. The image
scroll view also retained automatic safe-area inset adjustment.

The media canvas now fills the screen. The smallest/default zoom contains the
complete image/PDF with preserved aspect ratio. Wide pages can have unused black
space above/below; long strips can have unused space beside them. These areas
are aspect-fit letterboxing, separate from a fixed safe-area band. Pinch or
double-tap an image to enlarge it; double-tap again to return to fit. Layout
updates keep zoom stable, while a new page or viewport resize refits it.

UIKit's horizontally paged collection view replaces the reader's SwiftUI page TabView.
It supplies the interactive horizontal animation and retains a bounded set of
page hosts. A completed swipe updates selection/progress; a cancelled swipe
keeps the original page. RTL reverses neighbouring-page order. Zoomed content
keeps pan gestures; at minimum scale, pan yields to page navigation. PDFKit
still renders one detached PDF page per canonical reader page.

Hosted cells begin loading as they appear/prefetch, including during fast swipes.
Loaded neighbouring pages reuse their URL, decoded content and viewport when
returning, rather than briefly replacing them with a loading indicator. Retry,
content/version changes and changed request identities still reload normally.

Media hosts do not add safe-area regions and scroll views do not automatically
adjust media insets. The screen measures safe areas separately for its top and
bottom controls. Tap hides controls, status bar and system overlays. AVKit video
playback is unchanged. No API, storage or database migration is required.

## Reproducible checks

Boot an iPhone simulator, then run:

```sh
python3 scripts/verify-phone-reader.py
# Select a particular booted simulator:
python3 scripts/verify-phone-reader.py --device SIMULATOR_UDID
python3 scripts/verify-apple-project.py
```

The checker builds an isolated app with a separate bundle/cache, synthetic media,
an invalid OAuth client and a synthetic API transport. It never uses the user's
NAS, production API or login. It verifies real UIKit image/PDF fit, zoom stability,
viewport resize, cancelled/completed page selection, RTL/chapter bounds, bounded
hosting controllers, consecutive bound page jumps, neighbouring viewport/zoom
reuse and the production full-screen reader frame. A screen-aspect
test image must start at screen coordinate zero, beneath the status bar.

The app stays open on its first page for gesture review after checking consecutive
page jumps and returning to a loaded neighbour. Its first page matches the screen aspect;
the next two are a wide page and a long strip, with distinct coloured edges to
make cropping visible. Launch it through Device Hub/Simulator to review swiping,
double-tap, control visibility and rotation. The test report is stored in its own
Documents directory, not in the user's library. Real NAS throughput and physical
iPhone frame pacing are not certified by the simulator checks.
