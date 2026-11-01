# Chapter description reading

On Mac, open **Reader Options (…) → Chapter Description** for the optional pane
below or beside the page. On iPhone, tap the **Chapter Description** text-lines
icon beside **Info** at the top right. The two direct buttons share one glass
capsule; a chapter without a nonblank description in the displayed language
(including its existing original-text fallback) shows only a circular Info button.
The description opens a full-width black translucent panel below the image,
reaching the bottom of the screen.

Scroll the description vertically to read the full text. The title stays visible
above it. The text wraps without truncation and
supports selection/copy. Source links are at the end of the scrolling content.
Mac's bottom pane is bounded so long descriptions leave space for the comic.

On Mac, use the two text-size icons; on iPhone, touch and hold the description title
for **Smaller Text / Larger Text**. Adjust the description by 2 points, from 12 to 32
points (16 by default). The corresponding button disables at either limit. The
choice is remembered on this device across chapters and app launches, and follows
system body text scaling. It does not change descriptions or their translations.

On iPhone, drag the bar at the panel's top to resize it. It starts at 40% of screen
height and can grow to 75%, always leaving a media viewport above. The image fits
that viewport without changing its aspect ratio or brightness. No modal dimming
layer is shown. Reader buttons, status controls and inline font buttons hide while
the panel is open. Tap the image or drag the panel down past its minimum height to
close it and restore reader controls. Height remains adjustable through VoiceOver;
its Escape action closes the panel. Body scrolling does not resize the panel.

The shared SwiftUI `ReaderChapterDescription` owns its vertical ScrollView; hosts
provide a finite height. iPhone now uses an inline split layout rather than a
popover or system sheet. The `ReaderDescriptionFontSize` preference is optional and requires
no account, storage, API or MongoDB migration.

For isolated visual inspection with synthetic bilingual text:

```sh
python3 scripts/preview-native-ui.py mac --long-description
python3 scripts/preview-native-ui.py phone --long-description
```

These previews use separate app identities and generated sample media, never the
user's library or credentials. The long-description flag opens a sample chapter
directly and enables Mac's description pane. On iPhone, open its description. Scroll to
“End of chapter description.”, then check larger/smaller sizes and reopen it.
On iPhone, also drag the grabber, verify no buttons cover the image, and tap the
image to return to ordinary reading.

## Verification

On 2026-10-30 the inline iPhone panel replaced the popover. Both application builds
and project/whitespace checks passed. An actual isolated iPhone preview verified
full-width bottom placement, hidden reader/status/font buttons, aspect-preserving
media repositioning without a dimming layer, dragging from 40% to 63%, tapping media
to close, dragging the grabber down to close, restored reading controls and the
title's text-size context menu. Native inspection confirmed a bounded, enabled
description ScrollView with content taller than its viewport. The computer-use
tool emitted only one moved event (pan began, then ended without changed events),
so continuous finger-scrolling was not established by that tool in this run.
The existing native text scroller remains in use. Temporary event/geometry probes
were confined to the generated preview and removed from its final build.

The original 2026-10-29 Mac and iPhone Simulator builds and Xcode project checks passed. Actual native
preview inspection used 40 synthetic bilingual paragraphs. Mac's bounded bottom
pane scrolled to the end with its header fixed; 16 → 20 → 18 pt adjustments changed
wrapping and retained access to the end. iPhone's real description popover accepted
an upward touch drag through the full text to the final paragraph/source link;
larger and smaller text controls worked, and reopening the popover preserved 18 pt.
No user media, metadata or production credentials were used.
