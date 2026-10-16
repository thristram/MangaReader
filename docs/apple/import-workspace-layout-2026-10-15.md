# Mac import workspace layout

With no candidates, the clickable drop surface fills the remaining space beneath
Import & Identify. Its 28-point margins align with the title. Status messages
appear inside the surface so it does not shrink after a completed/failed import.

With candidates, the persistent drop box is hidden. A single vertical queue on
the right selects folders/chapters; its plus button opens the system file picker.
The review area scrolls independently, while Skip/Add/Move remain at the bottom.
Narrow windows arrange actions in two rows and stack preview above metadata.
One form instance survives layout changes. Clicking the selected queue item does
not clear the current draft.

The thumbnail strip shows all image files using lazy horizontal scrolling.
Clicking a thumbnail changes the large fit-to-frame preview and selected border.
It does not reorder files, change the imported cover or discard edited metadata.
Selecting another candidate resets the preview to its first page. A PDF/video
candidate retains its single file thumbnail.

Dragging folders/files anywhere onto the page shows a translucent full-area
overlay, including during review. It does not intercept input or replace the
existing native drag callback that captures source grants. Drag exit/completion
clears the overlay. File authorization, background queue, commit/retry and
translation behavior retain their existing contracts; no API/data migration.

## Validation

`python3 scripts/verify-mac-auth-ui.py` checks empty native drop-host bounds,
right-side queue geometry, fixed footer space during review scrolling, horizontal
thumbnail scrolling and full-page drop bounds while drag feedback is active.
It also runs the existing 30-folder real commit, 2,000-comic search and
focus/scroll responsiveness checks, resizing the isolated form to 486, 760 and
1,050 points without duplicating fields. Other import/grant/retry regressions pass.

The isolated native Mac preview was reviewed in empty and populated states.
Horizontal scrolling exposes later thumbnails; selecting pages 2 and 6 updates
the large preview. The right queue and fixed actions were visually checked in
the live window/full-screen layout. The drag overlay is exercised through the
native host's target callback; this is not a physical Finder drag acceptance test.
Synthetic media and a fake API are used; no user media or production records
are modified. Mac build and project source-membership checks pass.
