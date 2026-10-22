# Rapid paging, collection scrolling, dismissal and video seeking

## Reader black pages

The iPhone UIKit pager used cached hosting controllers across reusable cells. A
late end-display callback could detach a hosting view already moved to a newer
cell, or clear a prepared cell that UIKit later displays without asking its data
source again. Returning to that page then left an empty cell while its cached
hosting controller still existed.

Cells now transfer exclusive ownership of a host, tag each attachment, ignore
stale-index callbacks and defer offscreen teardown until UIKit finishes updating
visibility. Will-display, layout and settled-page handling also restore any
visible cell's missing content. Distant hosts are pruned during cell creation,
with displayed transition cells protected. A synthetic rapid-swipe regression
reproduced a persistent detached-host black page during implementation and now
passes, including revisiting pages whose first decode was cancelled.

Shared image decoding now limits concurrent decodes (one on iPhone, two on Mac)
and wraps temporary ImageIO/PDF work in an autorelease pool. iPhone caps decoded
pages at 12 million pixels; Mac retains 24 million. Aspect ratio and original
files remain unchanged. This bounds transient bitmap pressure during rapid
navigation rather than launching an unbounded set of large decodes.

## Fast collection scrolling / shared SMB safety

The user confirmed the crash happens while loading online SMB covers. With
explicit permission, three MangaReader crash reports from October 15–16 were
read from the connected iPhone. All three terminate in Foundation's
`Data.init(repeating:count:)`, called by `SMB2FileHandle.read(length:)` from the
SMB contents stream. The buffer-size argument is `-1`: a disconnected context's
missing negotiated read size reached a memory allocation. These reports establish
this failure path; they do not establish an out-of-memory termination.

The shared SMB dependency now validates context, socket, negotiated read size and
requested length before allocation, under the same context lock as the read.
Disconnected reads throw instead of trapping; read chunks are capped at 1 MiB.
Both `read` and `pread` are protected, covering Mac and iPhone. Stream cancellation
now stops its queued producer, and a disconnected stream finishes with an error.
Cover destination-marker validation waits for a bounded read to finish before
teardown, including when a scrolling tile cancels its task.

Two additional concrete transport hazards were fixed in vendored AMSMB2:

- Callback state previously passed C a temporary Swift stack address from
  `withUnsafeMutablePointer`, beyond that closure's guaranteed lifetime. Both
  wait wrappers now retain a stable heap callback object until completion or
  failed-wait teardown drains the context.
- Darwin SMB writes now set `SO_NOSIGPIPE` on the individual socket. A closed
  peer caused the synthetic process to terminate with SIGPIPE before the fix;
  it now returns a normal socket error. The process-wide signal disposition,
  authentication, encryption and signing are unchanged.

The native iPhone collection stress test traverses 700 synthetic tiles with 100
large offset reversals while thumbnail tasks start/cancel and simulated memory
warnings purge caches. Transport tests cover 10,000 retained callback round
trips, 20 read-after-disconnect sequences with invalid-length cases for both read
methods, disconnected-stream termination, closed-peer writes with the default
SIGPIPE handler, pending CLOSE, timeouts, protocol errors and successful callbacks.
The SIGPIPE and callback-lifetime fixes address separately reproduced hazards;
the three physical-device reports identify the negative buffer allocation.
Raw crash reports stay in ignored local build output and are not included in
documentation or uploaded. A new physical-device run against the user's NAS is
still needed to confirm behavior under the original workload after installing
the updated app.

## Swipe down to exit on iPhone

A native vertical pan follows the finger, moving/scaling the reader. Release
after 100 points, or after 35 points with downward velocity above 900 points/s,
closes Preview using its existing presentation dismissal. A short/cancelled drag
springs back. Horizontal or upward drags do not dismiss. Zoomed images/PDFs keep
their native panning; an active paging transition prevents dismissal. The
horizontal paging recognizer waits for the downward recognizer to reject a
horizontal drag, so the two do not race at minimum zoom. Video, PDF and image
chapters share the gesture. No progress change is emitted for a cancelled drag.

## Shared video seeking

Both platforms now coalesce rapid seek changes. At most one seek is in flight;
its completion chases the newest target and ignores obsolete media generations.
During scrubbing playback pauses and stale periodic timestamps cannot pull the
slider back. Preview seeks allow a small frame tolerance; releasing the slider
requests the exact final position and restores the prior play/pause intent only
after reaching it. Closing/switching media invalidates pending completions.

### Initial video frame (2026-10-20)

The native video output now mounts before asset preparation completes, and its
`isReadyForDisplay` observation is separate from `AVPlayerItem.readyToPlay`.
Asset properties load concurrently with item/renderer preparation. Validate that
a video track is decodable, then use the existing serialized seek path to prepare
the first frame while paused. MP4 edit lists can contain empty leading segments;
the initial seek and replay-after-end target the first nonempty video segment,
instead of waiting through a black interval at time zero. Source files are unchanged.
One reader-owned preparation task survives cancelled/recreated SwiftUI page waiters;
reset or switching the source cancels it and invalidates late results.

Play intent is separate from actual `timeControlStatus`. A Play request before
the native output is ready remains queued without advancing the clock; it can be
cancelled. The loading indicator remains until output readiness. Local-volume
files (including downloaded MP4s) skip streaming-buffer prediction. Volume checks
run off the main actor; Finder-mounted NAS file URLs keep normal buffering.
Codec/item failures keep the explicit unsupported-video state. Switching/resetting
invalidates item observers and old item callbacks cannot change the active output.

Native regressions verify a real local H.264 MP4 displays while paused, no playback
before an output mounts, a real MP4 with a two-second empty leading edit starts at
its video segment, backward seeking reaches the decoded frame, and the production
reader preserves completion and release/reopen. The full reader accepts an optional
playback instance so this regression exercises its actual transport rather than
bypassing it with direct AVPlayer commands.

### iPhone output layout correction (2026-10-20)

The user still observed black video after the startup changes; a small cancelled
downward dismissal immediately revealed it. Readiness checks alone had not verified
visible output in that presentation hierarchy. iPhone now uses a UIView with
AVPlayerLayer as its backing layer, replacing the nested AVPlayerViewController.
UIKit sizes the video layer with the view from its initial zero bounds through
the first full-screen layout. Observe readiness on that actual layer and keep the
canvas flexible in both dimensions. Mac retains AVPlayerView. Both use the same
transport, aspect fit and overlay buttons.

The native regression opens the production fullScreenCover route three times,
checking mounted/presentation-layer geometry and video readiness before sending
any dismissal or resize gesture. It also verifies the view's backing layer is the
video output, preserves controls/seek/completion/reopen, and uses a fresh offline
fixture containing visible color blocks for on-screen confirmation.

## Verification

- `python3 scripts/verify-phone-reader.py`: actual UIKit cell ownership/reuse,
  100 rapid page changes, cancelled-page revisit, bounded hosts, native collection
  stress, dismissal thresholds/cancel/zoom isolation, alternating backward/forward
  seeks and decoded-frame timestamps against a real generated H.264 MP4, existing fit/paging/marks/tabs checks.
- `python3 scripts/verify-reader-loading.py`: shared async decode/cancellation,
  large-page cap, PDF/render/resize and bounded cover workload.
- `python3 scripts/verify-mac-auth-ui.py`: existing Mac controls/playback/import
  workflows after the shared changes.
- `python3 scripts/verify-smb-handle-lifecycle.py` and
  `python3 scripts/verify-smb-diagnostics.py`: synthetic transport safety only.

Fixtures use an isolated test account/cache and synthetic files. No production
library metadata, credentials, NAS files or device contents are changed.

On October 16, both production targets built successfully and the native Mac,
iPhone and SMB regression suites passed. The unlocked simulator was reviewed
onscreen with synthetic image/video chapters and unified controls. The current
Device Hub automation could activate controls but did not produce either
horizontal or vertical touch drags, so that inspection does not certify the
interactive swipe animation. Dismissal thresholds, cancellation and zoom isolation
are covered by native simulator tests; finger-driven gesture feel remains a
manual device check.
