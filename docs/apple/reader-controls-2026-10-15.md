# Reader controls and keyboard — 2026-10-15

## Behavior

Mac Preview uses 44-point circular icon buttons. Top-left: Back, then Thumbnail Sidebar. Top-right: Media Language (globe), All Pages (grid), Reader Options (ellipsis). Language and options menus have no chevron or visible text; accessibility labels remain and the language menu exposes the selected language. Full Screen is a separate button at bottom-right. The page counter, previous/next and page favorite/star remain centered at the bottom.

The iPhone language button is also a circular globe with no text or chevron. Its native inline Picker retains the checkmark column, including the blank space on unselected rows.

Mac arrow keys work immediately in the reader window: right/down advance, left/up go back. These keys deliberately use that mapping even when swipe direction is RTL. Selection stays within the chapter. Modified shortcuts, editable text, attached sheets and other/inactive windows retain their normal keys. No focusable SwiftUI canvas is required; image, scroll and PDF surfaces do not draw a blue focus ring. The reader removes its local event monitors when leaving.

Mac video uses AVPlayerView for rendering with its independent native control bar disabled. A reader-owned AVPlayer supplies play/pause, position, elapsed/duration and mute controls immediately above the page bar. These controls share the reader's visibility toggle and do not require clicking the video first. Space toggles playback while viewing a video. Video playback stops and releases its current item when leaving or switching away. Completion still comes from AVPlayerItemDidPlayToEndTime for the active item; opening a one-page video does not count as completing it. iPhone video playback remains AVKit-managed. Codec support is unchanged.

## Verification

- Mac and iPhone Simulator builds; project source membership and stable generation check.
- `python3 scripts/verify-mac-auth-ui.py`: native reader key dispatch before canvas click, four directions and bounds, modified shortcuts/text/sheet/inactive/other-window isolation. The non-activating harness supplies key-window state with a test window subclass; the visible Mac preview separately checks real window activation and direction keys.
- The same harness generates a real H.264 MP4 locally using AVAssetWriter, verifies shared play/pause/seek/mute, native control-bar suppression, stale page teardown protection, release and recovery after unsupported media. No external encoder or user media is needed by this regression.
- `python3 scripts/verify-reader-loading.py`: background image/PDF loading, bounded covers, cancellation, resize and responsiveness regressions.
- `python3 scripts/verify-phone-reader.py`: whole-page fit, zoom, paging, bounded loading and Saved/tab regressions on an iPhone simulator.
- Visible isolated previews use synthetic comics/video and a fake API. No production account, library metadata or NAS media is changed.
