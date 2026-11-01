# Verification — 2026-10-13

This records checks actually performed for the first development milestone. It does not claim a completed P0 release or a live production deployment.

## iPhone inline description panel — 2026-10-30

Mac and iPhone builds and project/whitespace checks passed. Native iPhone preview
checks verified opening from Reader Options, a full-width bottom panel extending
to the screen edge, no persistent reader/font/status buttons, upward aspect-fit
media repositioning with no modal dimming, 40% → 63% resizing, title text-size menu,
tap-image dismissal and downward-grabber dismissal with restored controls.
Scroll geometry is bounded/enabled with content taller than its viewport;
continuous finger scrolling remains a device check because the UI tool emitted
only a single moved touch and no pan-changed events. Temporary geometry/touch probes
were generated-preview-only and removed afterward. No user library or media was
used. See [behavior and verification scope](apple/chapter-description-reading-2026-10-29.md).

## Ollama text translation — 2026-10-30

The initial instance returned an empty model list and an explicit missing-model
404 for `galtransl:7b`. After the user restarted the intended instance, discovery
found that model. Live production-adapter requests for a synthetic Japanese title
and multiline description both returned usable Chinese `LocalizedText` results.
The diagnostic used isolated preferences and did not update library metadata or
submit private comic text. The earlier authorized local model-registration process
had completed before re-verification; no additional import was started afterward.

Mac/iPhone builds, project consistency and isolated mocked Ollama checks passed.
Regression coverage includes missing-model and provider error details, exact model
names, native API suffix/proxy normalization, empty text/model refusal without
inference, custom prompt plus JSON contract, invalid output rejection, title-only /
description-only results and Unicode/newlines. Settings distinguish an empty host
from an unavailable selected model and clear stale model lists on URL changes.
See [setup, diagnostics and test scope](apple/ollama-text-translation-2026-10-30.md).

## Chapter description scrolling and text size — 2026-10-29

Mac and iPhone Simulator builds, Xcode project membership and whitespace checks
passed. Actual isolated native previews with 40 bilingual paragraphs verified the
bounded Mac bottom pane and iPhone popover reach the last paragraph/source link.
Text-size controls changed 16 → 20 → 18 pt without hiding the fixed header; reopening
the iPhone popover retained 18 pt. The iPhone check used a real touch drag in the
simulator. This UI-only change adds a device-local preference and no database/API
migration. See [usage and reproducible visual preview](apple/chapter-description-reading-2026-10-29.md).

## Manga translation white placeholders — 2026-10-25

Inspected the user's local manga-image-translator checkout (`c888fdf`) and read the
running localhost service's OpenAPI schema. Both standard and web-optimized image
stream routes are advertised. The shared worker resets `_is_streaming_mode` in its
streaming handler but not its non-streaming handler; a previous web request can
therefore cause the legacy image API to return a 1×1 white PNG while retaining the
full result on the service. No provider request or production media was submitted.

Mac build, focused native translation integration and project consistency checks
passed. Synthetic responses verify standard-stream preference with a white legacy
response, Custom OpenAI multipart selection, byte-for-byte full PNG preservation,
progressive six-page commits/retry through streaming, big-endian framing, truncated
and malformed streams, provider errors, legacy raw-PNG compatibility and no extra
POST fallback after failures. Placeholders are refused before cache/metadata changes;
an older persisted uncommitted placeholder also fails safely on Retry, retains its
cache and sends no new translation request. Existing cache/journal recovery,
descriptive metadata preservation, PDF rasterization and account cancellation
regressions pass. Existing committed white pages are deliberately not overwritten;
see [recovery limits and service-result import](apple/manga-image-translation-2026-10-18.md).

## Author source links — 2026-10-22

Mac and iPhone Simulator builds passed. MangaCore executed 69 tests with zero
failures and one existing second-volume skip. Native synthetic regressions passed,
including attribution to the same author from comics and chapters and profile URL
routing. Xcode project consistency and whitespace checks passed.

Computer-use checks exercised all three locations on both platforms: comic-detail
Pixiv, Preview Info FANBOX, and a different Authors row's Patreon link. The isolated
preview captured each expected URL locally instead of contacting external sites.
Info showed the author name and description while retaining file-location details;
source taps on Authors kept that page open. iPhone visual review prompted a vertical
alignment correction beside the comic author. Provider availability, real account
login and production author records were not used for these checks. See [usage and
preview capture](apple/author-source-links-2026-10-22.md).

## Chapter reassignment and file organization — 2026-10-22

Both final app builds and the full native synthetic regression passed. MangaCore
executed 67 tests with zero failures and one second-volume skip. Actual isolated
Mac UI verified exact-name and dropdown-based chapter reassignment across different
author/Series parents, including collection refresh and ambiguous-query Save blocking.

A generated 12-file/24-MiB NAS organization completed in 1.324 s with byte equality
and completed journals; local copy/SHA versus same-volume execution measured
0.127 s versus 0.023 s. The legacy copy baseline failed on the tested share, so no
NAS speedup ratio is claimed. Tests touched only disposable generated files, not
existing manga or production API records. See [details and recovery limits](apple/chapter-reassignment-and-organization-2026-10-22.md)
and [ADR 0017](adr/0017-same-volume-organization.md).

## iPhone video presentation rendering — 2026-10-20

The user reported the same black-screen symptom after the startup fix and found
that a small cancelled dismissal immediately revealed the video. The previous
readiness-only checks did not establish that pixels were visible through the actual
presentation/layout hierarchy. Replace iPhone's nested AVPlayerViewController with
a UIKit view whose backing layer is AVPlayerLayer; UIKit now owns output geometry
directly. Observe that layer's readiness and size the canvas flexibly. Mac retains
AVPlayerView and the existing shared transport.

The final iPhone simulator suite passed, including three consecutive actual
fullScreenCover presentations. Each checks window attachment, backing/presentation
layer bounds and videoRect/readiness before any dismissal or resize gesture.
Existing cancelled-load recovery, paused first frame, empty MP4 edits, decoded-frame
backward seek, transport/completion, close/reopen, paging and collection stress pass.
The Mac target also builds; project membership and whitespace checks pass.

With Device Hub already open, the final test app was relaunched with a fresh
synthetic offline MP4 containing four color blocks. Computer-use inspection showed
those blocks at 0:00, before any tap/drag/resize interaction with preview. Pressing
Play changed the overlay to Pause and advanced the position without moving the
preview. Only the simulator/fixture account was used; this does not certify the
user's physical iPhone or original MP4 files. There is no migration or media rewrite.

## Video preview startup — 2026-10-20

The reported case is primarily downloaded MP4s on iPhone. Previously `ready` was
set from asset playability/duration before checking item status or AVKit's first
displayed frame; the native output was mounted only afterward. The shared transport
now attaches its item/output early, loads properties concurrently, primes the first
nonempty video segment while paused, and separates requested playback from actual
item/output readiness and `timeControlStatus`. Local-volume files skip streaming
buffer prediction; Finder-mounted NAS volumes retain it. A reader-owned preparation
task prevents a cancelled/recreated SwiftUI waiter from orphaning a pending item.

The final full iPhone simulator reader suite passed with real synthetic H.264 MP4s:
paused first-frame output, no clock advance before output, a two-second empty
leading MP4 edit, repeated cancelled/recreated load waiters, reset isolation,
coalesced forward/backward seeking and decoded-frame timestamps, completion through
the production reader's shared transport, unsupported-file recovery, and close/reopen.
The leading-edit fixture initially failed when using only `track.timeRange.start`;
using the first nonempty segment's target start resolves that case. Existing paging,
collection stress, tabs and full-screen fit checks also passed. These tests do not
identify the encoding/timeline structure of the user's original files.

The production Mac build passed; shared video tests also exercise paused native
first-frame readiness and the playback gate. `MANGA_READER_CONTROLS_ONLY=1 python3
scripts/verify-mac-auth-ui.py .build/xcode-swiftui-mac` runs the focused native check.
No video files are rewritten, re-encoded or re-downloaded by this fix. No database
or API migration is required. Tests use a separate fixture account/cache and no
production media or service records.

## Import shared-source checks — 2026-10-20

`Checking shared source files…` now uses the owner/metadata-generation-scoped
SourceReferenceIndex rather than resolving every other media file. Root bindings
are checked lazily, cached roots first, with early exit on a shared reference.
Disjoint canonical roots skip their entire page list. Relevant roots reuse resolved
directory prefixes and inspect directory entries for differently named symlinks;
parent-listing denial keeps the per-reference fallback for standalone-file grants.
Filesystem results are not persisted or reused across checks. Concurrent metadata
or binding changes cannot authorize a move from a stale negative answer.

Core suite: **54 tests, zero failures, one second-volume test skipped**. The new
20,000-reference fixture required **21 directory resolutions, 20 directory
listings and zero individual file resolutions**. A disjoint root required zero
directory/file probes. These are deterministic operation counts, not an
end-to-end NAS timing claim. Tests cover nested roots, directory/root/file symlinks,
externally changed symlink targets, path escapes, media exclusion, Unicode and
PDF/video references.

Mac and iPhone Simulator builds passed. The full native suite passed, including a
new actual import/commit that retains an original referenced through a differently
named symlink, plus metadata-index invalidation and root rebinding. Existing
nested/standalone imports, sharing, failed metadata recovery and translation
regressions passed. Project membership/generation and whitespace checks passed.
All new media/API fixtures are synthetic; no production files or API records were
changed. Cold bookmark resolution and network directory access can still wait on
the NAS. No schema or data migration is needed. See [ADR 0016](adr/0016-import-source-reference-index.md).

Codebase Memory discovery used the existing graph with source fallback for stale
coverage. A final full refresh was attempted but its worker could not verify active
daemon coordination; the existing graph remains readable. New/changed symbols were
verified directly from source and the builds/tests above, not from a refreshed graph.

## Organization preparation audit — 2026-10-19

Ordinary exclusive same-volume imports already use FileCommit's rename path. Chapter/language reorganization uses FileOrganization's per-file copy/digest/API/cleanup transaction. A plain translated-page append previously resolved every existing page's filesystem path, opened unrelated storage bindings for global sharing checks, and attempted empty-directory cleanup even though those files had not moved.

Image addition now skips unchanged root/path references before filesystem access, resolves the global sharing set only for actual relocations, batches changed-path checks on the background worker and omits source-directory cleanup for a one-page append. Queue progress distinguishes destination/preparation/copy/metadata/verification. Native tests verify the five subsequent commits of a six-page translation each contain one file and no unchanged-directory cleanup, alongside existing shared-file and failed-metadata recovery regressions. Mac build, full native suite, project verification and diff checks passed.

A read-only microbenchmark against 20 unchanged references on the user's currently mounted, warm-cache NAS measured **2.97 ms** for the previous path checks and **0.01 ms** for an in-memory unchanged-reference skip. No comic contents were read or files modified. This is not an end-to-end organization benchmark and does not establish that path checks dominate the reported stall; global binding resolution, verified content transfer and metadata/API work are separate. Same-share whole-directory rename for the FileOrganization transaction is not implemented by this change.

## Translation recovery — 2026-10-19

The repeat failure was diagnosed against the three actual pending records (read-only, no comic titles or credentials recorded here). Their desired media omitted the preceding committed page: pending pages 10/16/6 were based on only 8/14/4 target files, while the current chapters already had 9/15/5. The updated inference proved all three safe to rebase, preserving every current path and canonical mapping and adding only the cached page. The earlier exact-baseline test did not cover this stale-plan shape.

After rebuilding/running the real Mac app and the user completing its existing sign-in flow, all three **Resume & Finish** actions were executed successfully. Each sheet closed on success and its translation organization row disappeared. Translation Queue visibly showed **10/17, 16/28 and 6/20** with “File commit recovered. Retry to continue the remaining pages.” and the old errors cleared. A fresh service sync was triggered. These actions finished only already-rendered cached-page commits; they did not submit new comic images or start the remaining model jobs. Other unrelated old import-recovery records were left untouched.

Read-back verification confirmed all three journals were `complete`, the fresh synchronized target metadata matched their recovered payloads, all prior target paths were preserved, queue errors were empty and each published PNG matched its journal SHA-256 digest. The original desired payloads remain available as `priorMetadata`.

AppSession now merges polling snapshots by revision and writes the merged cache in sequence. A mock stale snapshot taken before a page commit is applied after that commit; both memory and snapshot.json retain the committed media. The legacy partial-translation test now removes a previously committed page from its old plan, then verifies Retry retains it, adds the cached page, saves the rebased baseline plus `priorMetadata`, and completes all missing slots without extra image submissions. A core regression stages/rebases/reloads the plan, verifies an interrupted rebase remains recoverable, and rejects a stale attempt to replace the journal. Core suite: **49 tests, zero failures, one second-volume test skipped**. Mac/iPhone builds and the full native suite passed.

Reproduced a failed translated-page metadata commit followed by a newer description/text-localization edit before Retry. Recovery retains the edit, reuses the cached PNG and finishes all six pages with six image submissions total. Also replayed an older journal without a baseline after the server already held its desired media: finishing preserves the newer description and revision, with no metadata rewrite. Core checks cover conflicting roots, paths/order, alignments, media language, original title and parents; these remain blocked, as does an unproven generic legacy revision conflict. Mac/iPhone builds, the isolated native integration suite and project verification passed. Core suite: 48 tests, zero failures, one cross-volume test skipped because no isolated second volume was provided. No real comic files or translation-provider requests were used.

The follow-up missing-snapshot regression removes `originalMetadata` from an unfinished translation journal, edits the chapter description/text localization, restarts the queue and recovers through the File Management Queue action before Retry. It proves all source moves, retains newer text and completes six pages with six image submissions total. A second case starts with three existing target slots, fails the first new page commit, removes its snapshot, edits the description and retries directly from Translation Queue. It preserves the three existing pages and needs only three image submissions for the missing slots. Unit tests cover first-language folder relocation, existing identity/sparse alignments, unexplained operations, competing canonical slots and modified shared-source bytes. These tests use disposable synthetic files and mock APIs only.

## Initial milestone

| Check | Result |
| --- | --- |
| Node dependencies / lockfile | npm installation succeeded; audit reported zero known vulnerabilities at installation |
| Server typecheck/build | Passed with Node 22.16.0 and TypeScript 5.9.3 |
| Server security/integration tests | 9 passed, including real signed-JWT verification and real MongoDB persistence/CAS/unique account indexes |
| MongoDB migration | Dry-run performed; v1 applied twice to an isolated test DB; unique owner index and single migration marker verified; test DB removed |
| Shared Swift tests | 7 passed: namespace/form encoding, ID-token signature/nonce/audience, text fallback/NSFW, optional folder hierarchy, numeric sort, overwrite/journal, traversal/symlink containment |
| Mac native target | Unsigned arm64 Debug build succeeded with Xcode 27.0 / Swift 6.4 |
| iPhone native target | Unsigned iOS Simulator Debug build succeeded; UIKit scene application installed/launched on iPhone 18 Pro / iOS 27 simulator |
| Mac runtime (initial check) | Built application process launched; no startup diagnostic in its captured output. Window visibility was not verified; see correction below. |
| Editable mock export | Project-local export succeeded; standalone preview traversed 32 Mac page options without JavaScript errors |

The temporary Mongo server used a task-local `.build/mongo-test` data directory and dedicated localhost port. Existing user/auth/production databases were not touched. Auth unit tests use generated test keys/JWKS, never production tokens. Native build products, logs and screenshots are ignored under `.build`.

Native visual/accessibility inspection could not be completed: the available native UI inspection service timed out when selecting the Mac app. Process startup/compile results above are therefore not a claim of visual/gesture acceptance. The saved mock's browser runtime was checked independently.

Configuration-dependent checks remain: production thristram-auth discovery/registration/consent/refresh/revocation, real Mongo hosting/Vercel deployment, signed sandbox behavior, real SMB/NAS encryption/permissions/codecs, local Ollama responses and actual iPhone/Mac gesture/layout/accessibility testing. Sample endpoint/client values are placeholders.

Reproduction commands are in the root [README](../README.md), [server docs](server/README.md) and [Apple docs](apple/README.md). See [implementation status](implementation-status.md) for pending features and acceptance order.

## Follow-up — Mac launch creates no window

The user reported that the Mac target built and ran from Xcode without showing UI. The original app process had no onscreen main window. SDK inspection confirmed that `NSApplicationDelegate.main()` calls `NSApplicationMain`; our programmatic app supplied neither a main nib/storyboard nor an explicit delegate installation. Therefore the window-creation callback never ran.

The Mac entrypoint now explicitly creates and installs `MacAppDelegate`, retaining it throughout `NSApplication.run()`. The window keeps the intended initial content size; library/sidebar headings respect safe areas below the unified toolbar, and the duplicate window title is hidden.

The arm64 Debug target rebuilt successfully with Xcode 27.0. `scripts/verify-mac-window.swift` failed against the original Xcode-built app (no main window within 15 seconds) and passed against the fixed build with an actual **1200 × 800** onscreen main window. It closed only its own test instances. Native accessibility inspection and screenshots confirmed the library, sidebar, search and sign-in toolbar exist; headings no longer overlap the toolbar. The final layout inspection used an ignored copy with a separate bundle identifier and synthetic public auth configuration to avoid interfering with the user's open settings window. This replaces the initial process-only check for startup; live login, reading, NAS access and full visual/gesture acceptance remain separate checks.

## Follow-up — project endpoint and full-window sign-in

Both targets now use project deployment configuration (API/resource `https://manga-api.thenoirclub.com`, auth issuer `https://auth.thenoirclub.com/api/auth`) and the supplied public client registration. API/auth runtime editors are removed, and old UserDefaults URL/resource values are ignored. Signed-out/restoring states mount native welcome screens only; verified identity mounts the library, and identity change/sign-out disposes of the prior UI. ASWeb authentication and verified `/v1/me` remain mandatory.

Checks: Mac arm64 and iPhone Simulator builds passed; 7 shared Swift tests passed. The actual-controller Mac harness passed endpoint/audience precedence, Sign In action wiring, busy/error retry, toolbar gating, account replacement and closing readers on identity change/sign-out. Synthetic identities are only in the isolated harness. Mac accessibility/screenshot inspection confirmed no library/sidebar/toolbar while signed out; iPhone 18 Pro / iOS 27 simulator screenshot confirmed a full-screen welcome page with native Sign In and no nav/tab bar. Generator checks in an isolated project confirmed existing signing/build settings and shared schemes are preserved and repeated output is stable.

The live Sign In attempt was rejected by the hosted service for requested access permissions. Read-only inspection of the supplied **Manga Manager** public registration confirmed both exact callbacks and all Manga scopes are present, but **offline_access is unchecked** while the app requests it for refresh/session persistence. No hosted client changes were made during these checks. This hosted scope mismatch must be resolved before a successful live login can be claimed; compilation/UI-state checks do not certify authenticated production API access.

After explicit user confirmation, `offline_access` was enabled and saved for this public client. The hosted admin UI confirmed successful save and displayed the added scope; client ID, callbacks and other scopes were unchanged. A repeat login still failed, and read-only inspection of the registration form showed the hosted service currently offers only `https://mosaic.thenoirclub.com` as an API resource, not the Manga resource. Registering/assigning the Manga audience remains external configuration work. Production `https://manga-api.thenoirclub.com/health` now returns HTTP 200 with the expected liveness JSON; authenticated API/database access is not established by that check.

## Follow-up — production Manga audience registered

With explicit user approval, `thristram-auth` commit `d4cbea3` added admin editing of existing client resource grants and documented setup/operations. Typecheck, lint, production build and 14 tests passed, including resource authorization before/after linking, client isolation, admin/origin validation and partial-save handling. Vercel production deployment `dpl_6SdUmqiYGDUidGZgHz2Gp233xfHP` reached **READY** and serves `auth.thenoirclub.com`.

Production `OAUTH_API_RESOURCES` now adds `https://manga-api.thenoirclub.com` with `manga:read`, `manga:state:write`, and `manga:manage`. The existing legacy resource configuration was preserved. The existing **Manga Manager** public client was linked to this resource through the new admin editor; after a fresh reload the table confirmed the persisted association and `offline_access`. Its ID, callbacks, public authentication method and other scopes were preserved. No credentials were retrieved or rotated.

The admin page temporarily returned a server error during verification. Deployment logs identified MongoDB TLS/server-selection timeouts; a full reload recovered and confirmed the saved resource association. This is an observed availability issue, not evidence of a schema or grant-save failure.

Public discovery returned HTTP 200 with the expected issuer, authorization endpoint and Manga scopes. A browser authorization request with the actual Mac client/callback, PKCE and Manga resource reached **Allow Manga Manager?**, displaying all requested scopes; the earlier scope/resource rejection no longer occurred. No consent was submitted. The isolated native Mac app initiated ASWeb sign-in, but the inspection tool did not expose its system authentication window; therefore this check does not certify native login completion, token exchange/refresh, `/v1/me`, or authenticated production library/database access. Test browser/native windows were closed after verification. Screenshots and build logs remain ignored under `.build`.

## Follow-up — AMSMB2 fails to load on iPhone app launch

The user reported a dyld failure from the iPhone app running through the Mac's iOS-app wrapper: `AMSMB2.framework` was missing inside the app, and the fallback framework in Xcode's `PackageFrameworks` directory was unsigned. The package manifest for pinned AMSMB2 4.0.3 explicitly declares a dynamic library. Both targets linked it without an embedding phase; the earlier simulator could resolve the framework from the build directory, so simulator launch alone did not detect the packaging defect.

Both committed app targets and the project generator now add **Embed Frameworks** with **CodeSignOnCopy** and **RemoveHeadersOnCopy** for AMSMB2 only; MangaCore remains statically linked. Existing signing/team settings, callbacks and schemes are preserved. `scripts/verify-apple-frameworks.py` verifies the completed bundle, its framework references (including Debug dylibs), binary architectures and nested code signatures. It failed against the previous iPhone build because the embedded AMSMB2 executable was missing.

Validation after the fix: signed iPhone Debug build for **My Mac (Designed for iPad/iPhone)** passed using the existing development identity; build logs show the framework copied and signed inside the app, and bundle/nested-signature verification passed. The signed arm64 iPhone Simulator build also passed bundle/signature verification; install/launch on iPhone 18 Pro / iOS 27 succeeded and a screenshot confirmed the welcome page. Mac arm64 Debug build passed and its unsigned bundle passed packaging verification. An isolated generator fixture retained both embedding phases and all original build settings/schemes; repeated regeneration was stable.

The raw iPhone build could not be opened directly through the UI tool (incompatible executable), so verification used the user's existing Xcode project, **MangaReaderiPhone** scheme and **My Mac (Designed for iPad)** destination. After stopping the old run and choosing Run, Xcode reported **Running MangaReaderiPhone**. Native inspection of the newly installed wrapper confirmed an actual MangaReader window with the welcome text and **Sign In** button; its screenshot was saved. This exercises the same wrapper-launch path as the reported crash. No account sign-in was initiated. Physical iPhone launch and SMB/NAS access remain separate checks. Logs, screenshots and build products remain ignored under `.build`.

## Follow-up — identity token omitted by the resource scope policy

The user reported **The identity token could not be verified** after native sign-in. Public discovery/JWKS confirmed the expected EdDSA/Ed25519 configuration. An isolated real Better Auth 1.7.7 authorization-code/PKCE exchange reproduced HTTP 200 with access/refresh tokens but no `id_token`: the Manga resource's API-only allowlist filtered out `openid` before ID-token issuance. Including identity scopes restored the ID token; a standalone check using the actual Swift validator verified its signature, issuer, client audience, nonce and shared subject. No production token or user credentials were inspected.

Auth commit `45b95b6` normalizes identity scopes into new Manga resource policies and adds a same-origin administrator repair for existing seeded policies. The repair only adds missing `openid`, `profile`, `email`, `offline_access` scopes through the provider's server-only resource API. Client registrations/grants, legacy resources, signing configuration, disabled state, custom claims and token lifetimes are preserved. Typecheck, lint, production build and **16 tests** passed, including actual SDK signing/claims, refresh rotation for both Apple callbacks, idempotence and unauthorized-request rejection.

Vercel production deployment `dpl_5MJNKXh81Bun5ZHtNNc1jXBgN2U5` reached **READY** and serves `auth.thenoirclub.com`. The deployed admin UI confirmed the existing Manga row had only three API scopes; applying the repair displayed all seven scopes and **Ready / Native sign-in scopes saved**. This updates the stored policy; an environment change alone would not repair an existing row. The Apple app now reports a missing ID token accurately and still requires all existing token/account checks. Both native targets rebuilt successfully.

After the production repair, Sign In was retried in the actual iPhone app running through Xcode's Mac iOS wrapper. Native inspection confirmed **Library / Continue Reading / Downloads**, with Continue Reading selected and the empty-library message. This is a live user sign-in result, not a synthetic account injected by the test harness. Entering this UI requires ID-token signature/issuer/audience/nonce validation and an authenticated production `/v1/me` result matching the same subject, issuer and owner ID. No production token, callback code, password or cookie was inspected or printed. The app was left signed in for the user. This check does not establish physical-iPhone operation, NAS access, production refresh rotation or a metadata-write/DB persistence round trip.

## Follow-up — native SwiftUI screens (2026-10-14)

Both app targets now host SwiftUI screens through their existing AppKit/UIKit lifecycles. No storyboard is used. The production ASWeb account gate and fixed project endpoint remain mandatory. The previous imperative library/editor/reader/settings controllers were replaced with shared collections and platform navigation; public AppKit/UIKit/PDFKit/AVKit adapters handle gestures, zoom, PDF and video.

Both Mac arm64 Debug and signed iPhone Simulator builds passed. Eight MangaCore tests passed. The isolated native UI/model harness passed account replacement/sign-out, endpoint policy, retryable sign-in failure, NSFW visibility, collections/history/filtering, author search and back/forward history. A new regression check mounts the native Mac pager in an actual window and verifies first-page height and resize behavior; this caught an initial hosting-size defect during visual review. Project regeneration checks passed source membership, repeated-output stability and preservation of signing settings/shared schemes. Both built bundles passed AMSMB2 embedding/architecture checks; the simulator also passed app/nested signatures.

Native inspection exercised the Mac sidebar/unified toolbar, every library/activity/settings page family, comic detail, edit/create/tag-search/page-order sheets, recursive import selection and sequential review. The final active sidebar has neutral selection with pink text. The image reader resumed canonical page 3 while the selected Chinese media lacked that page, correctly displaying original page 3; advancing displayed original page 4 with the matching counter. A six-page PDF opened at page 1 in the same full-height native pager. iPhone portrait simulator capture confirms the expanded native large title, two-column cards and native floating tabs/reading accessory; search uses the system pull-down drawer; iPhone-on-Mac inspection exercised navigation, detail, browse/settings and reader/overview in Apple's iPad compatibility layout.

All review data/media are synthetic in separate preview targets and account caches. The previews contain invalid OAuth configuration, never restore production credentials and schedule no server sync. Page progress/actions may report the expected local identity error when attempting a write; those attempts are not evidence of production persistence. No real NAS move/download, live Ollama response or new production auth/API/database acceptance is claimed here. Physical-device swipe/pinch, accessibility and the pending storage/sync features are tracked separately in [UI review](apple/ui-verification.md) and [implementation status](implementation-status.md). Final captures are saved in [the native gallery](mock/native/index.html); the original editable mock is preserved.

## 2026-10-18: Mac manga image translation

The native Mac harness covers the upstream multipart/config/locale contract through synthetic HTTP responses; offline enqueue refusal; progressive media slots and original fallback; persisted cache/retry; recovery after metadata failure without translating the cached page again; existing partial translations; malformed PNG refusal; PDF rasterization; and in-flight cancellation/account restore. Native inspection covers the four organization sidebar children, settings fields/Test Connection, unavailable-service confirmation with disabled Translate Manga, chapter-group progress/error/retry, thumbnail collection and zoomable output preview. The locally running `http://localhost:8000` API passed route compatibility through the actual settings Test Connection and its OpenAPI schema. Actual GPU/provider translation quality has not been benchmarked by these fixture tests. Real comic data was not submitted.

## Collection sorting and Mac editor actions — 2026-10-31

- Mac and iPhone Simulator Debug builds passed (`.build/collection-actions-{mac,phone}-build.log`). Apple project generation/membership checks and whitespace checks passed.
- `MANGA_COLLECTION_CHECKS_ONLY=1 python3 scripts/verify-mac-auth-ui.py .build/xcode-swiftui-mac` passed against production shared sorting code and isolated synthetic metadata. Both All Comics and comic children were checked for all six update/title/author + ascending/descending combinations, localized numeric titles, inherited author attribution and deterministic equal-key reversal. The same fixture checks also run in the existing full Mac/iPhone regression harnesses; the full suites were not rerun for this change.
- Native Mac synthetic preview: All Comics exposes sort key/order; comic detail exposes Sort chapters. Edit Comic shows Delete left and Cancel/Save right; Edit Chapter shows Delete Chapter then Translate Manga left, Cancel/Save right, all visible at the normal 660-point width. Delete opens a confirmation; Cancel preserves the editor and draft. Translate Manga opens the existing source/options/service-check confirmation sheet. No deletion or paid translation was submitted during visual verification.
- Native iPhone synthetic preview: All Comics filter offers Update Time/Title/Author and both directions. Choosing Title updates results; the chapter grid uses the same menu, marks the selected key/direction, and switching to Descending visibly reverses Chapter 1/Chapter 2. No real library or source files were modified.

## Import modes, All Pages and unified collection controls — 2026-10-31

- MangaCore tests: 70 tests, 0 failures, 1 existing second-volume skip. The new standalone-image scanner test verifies that selecting a file never scans its siblings.
- `MANGA_IMPORT_PAGES_CHECKS_ONLY=1 python3 scripts/verify-mac-auth-ui.py .build/xcode-swiftui-mac` passed. Synthetic Additional Pages requests preserve filename order, require a target, leave metadata unchanged before Commit, append to the existing chapter, preserve its text/collection, keep incoming originals and remove only the completed import candidate. Single-image ingress captures its own grant and archives the image inside a chapter folder without moving a sibling. Existing append collision/recreation/recovery, batch editing and Recycle checks also passed.
- Native import layout checks passed: aligned Chapter Name/Author/Comic field edges, full-page drop destination, fixed footer, single right queue, horizontally scrolling thumbnails and a single form at narrow/wide widths. After a real synthetic file commit, 30 pending folders and 2,000 comic choices remained responsive (15 focus/scroll cycles about 286 ms in this local fixture; not a NAS throughput measurement).
- Mac fixture UI: compact labeled tile actions; All Pages appears in the normal navigation stack with sidebar/Back; choosing a thumbnail opens the matching reader page. Import's three segments and then-current left-input/right-label layout were inspected (superseded by the label-left correction recorded below). Choosing Additional Pages hides normal metadata fields and opens the shared Add Images commit review without a translation alignment sheet; a synthetic one-page commit completed and cleared the candidate. No real library data was changed.
- Mac and iPhone Simulator Debug builds passed. The final circular filter uses one shared compact panel; the Mac fixture showed a separate circular toolbar control to the left of system search with Import/Sync at the leading edge. iPhone fixture inspection confirmed the circular top-right filter on All Comics and comic detail, working shared all/unread/tag/sort/direction content, and the Saved Starred/Saved Pages icon switch with its selected state.


## All commit paths and import label correction — 2026-10-31

- Both final Mac and iPhone Simulator Debug builds passed. MangaCore: **75 tests,
  zero failures, one existing second-volume skip**. Apple project membership and
  whitespace checks passed.
- The **full** native Mac regression suite passed, including actual synthetic
  translation organization, Additional Pages, media-language correction, chapter/
  version/page deletion, shared-source protection, stale revisions, metadata
  failure recovery and legacy translation recovery. No production API writes.
- New checks cover source/copy identity guards and modified-byte rejection;
  same-volume Recycle identities and genuine legacy SHA-only recovery; mutation
  symlink/traversal refusal; batched candidate canonicalization with fresh symlink
  resolution; completed-journal scan reuse and replaced/pending record refresh.
  A NAS timestamp simulation requires a second matching byte inventory and rejects
  changed content. Import checks after a synthetic commit, with 30 folders and
  2,000 comic choices, completed 15 focus/scroll cycles in **263 ms** locally.
- Native Mac preview inspection confirmed **label on the left, textbox on the
  right**, with aligned Chapter Name/Author/Comic and source-ID textboxes. This
  replaces the earlier input-left arrangement. No real comic was imported.
- `scripts/check-commit-performance.swift` compares current independent-copy and
  Recycle execution with **legacy SHA-only journal replay in the same engine**;
  this is not an old-binary benchmark. Eight synthetic 2-MiB files, with fixture
  generation and final byte checks excluded: local copy **0.078 → 0.047 s (1.65×)**;
  local Recycle **0.022 → 0.006 s (4.02×)**. Every output byte and original-source
  presence/absence was verified outside the timer. These are single-run fixture
  measurements, not real-library throughput guarantees.
- The same synthetic fixture on the existing Finder-mounted NAS confirmed that
  reading freshly written files can advance mtime; the compatibility path now
  handles matching bytes. Both legacy and optimized independent-copy attempts
  then failed in Foundation copy with **Cocoa 513 / POSIX EACCES**, so no NAS copy
  speedup is claimed. Both Recycle paths passed byte checks: legacy **0.399 s**,
  identity path **0.893 s**. For these small cached files, additional identity and
  immediate NAS checkpoint work costs more than the avoided byte reads. NAS rename
  commits still perform metadata/journal operations; zero media-byte reads does
  not mean constant time or a universal speedup. No credentials/permissions were
  changed, and only uniquely named disposable fixture folders were used.

Reproduce the optional benchmark after a Mac build:

```sh
xcrun swiftc -module-cache-path .build/commit-module-cache -parse-as-library \
  -I .build/xcode-swiftui-mac/Build/Products/Debug \
  scripts/check-commit-performance.swift \
  .build/xcode-swiftui-mac/Build/Products/Debug/MangaCore.o \
  -o .build/check-commit-performance
.build/check-commit-performance
# Optional: supply a mounted test parent with write permission.
# .build/check-commit-performance /Volumes/YourShare
```

The benchmark creates/removes only its own unique synthetic directory and temporary
journals. Failures are reported independently so an unsupported copy does not hide
Recycle results; incomplete pairs have no ratio and return a failing exit status.


## iPhone Preview direct info/description icons — 2026-10-31

The iPhone Simulator Debug build and Apple project/whitespace checks passed.
An isolated native preview on iPhone 18 Pro / iOS 27 verified two direct icons in
one top-right capsule for a long description, direct Info opening the author/file
location sheet, and Description opening the existing resizable inline panel with
reader controls hidden. Tapping the media restored the controls. A second generated
fixture with a whitespace-only description showed only circular Info and expanded
the title into the available space. The empty-description override existed only
inside the ignored generated preview; production fixtures/data were not changed.
No server, media movement or database migration is involved.

## Demand-driven synchronization and small mutations — 2026-11-01

- Server: 17 tests, 16 passed and one optional Mongo integration test skipped;
  TypeScript build/typecheck and formatting passed. Regression coverage includes
  owner-separated manifest ETags/304, compact selective records, 3-MB deferrals,
  paginated/projected reads, sparse Mongo CAS updates, invalid patches, inherited
  NSFW visibility through a deep hierarchy, and gzip responses.
- MangaCore: 78 tests, zero failures, one existing second-volume skip. A synthetic
  1,000-page title edit sends a PATCH below 100 bytes; appending one path/count/
  alignment stays below 350 bytes. Both preserve unchanged paths and reconstruct
  the complete local chapter from the small receipt. These are fixture payloads,
  not a measured percentage reduction of production usage.
- Final Mac and iPhone Simulator Debug builds passed. Native regression checks
  use an isolated URLProtocol service and synthetic library/files, with no
  production API writes. They verify single-flight/304, selective chapter/state
  fetches, no unchanged UI invalidation, five-second progress coalescing, targeted
  state conflicts, field-specific intent preservation, durable outbox recovery,
  Retry-After, tombstones/absence, atomic deferred batches, Mac idle refresh,
  concurrent local receipt preservation and sign-out isolation. The existing
  full Mac suite also exercises import, translation publication, file-organization
  recovery and editing through the PATCH fixture endpoint.
- The additive performance-index migration was applied successfully to the
  configured Mongo database. Existing unique indexes and metadata/files remain;
  no document-format conversion occurred. Read-only execution plans for manifest
  projections examined **zero documents**, returning 1,709 entity stamps and 497
  state stamps from covering indexes. The measured manifest was **160,721 JSON
  bytes / 50,138 gzip-level-1 bytes**. The earlier full collection measurement
  (about 3.34 MB) was BSON storage size, not the old HTTP response's wire size.
- The published Vercel Express builder packaged the local server successfully:
  packaged health 200, unauthenticated API 401, no environment files included.
  Production dependency audit reported zero vulnerabilities. Public checks of
  the currently hosted API health and auth discovery returned 200; `/v1/me`
  without credentials correctly returned 401. These checks do not establish
  that the account's quota pause is fully lifted.
- New server/client code has **not been deployed** by this verification. Deploy
  the server first and update both native clients to realize the traffic change;
  old clients remain compatible but retain old polling. Historical usage cannot
  be erased by this change. Production CPU/transfer reduction is unmeasured
  until rollout; no billing plan/account setting was changed.

### Transfer estimate from the current library — 2026-11-01

A subsequent read-only measurement reconstructed the legacy response with the
same current 1,709 entities and 497 states (749 live chapters): **3,041,338 JSON
bytes**, or **499,310 bytes at gzip level 6**. The compact full-record representation
was 1,673,872 JSON bytes / 478,681 gzip-level-1 bytes; the manifest remained 50,138
gzip-level-1 bytes. This compares serialization, not a production billing trace.

At one full request per 30 seconds, two hours/day over 30 days would transfer
3.60 GB of compressed response bodies; eight hours/day would transfer 14.38 GB.
With an existing cache, one fresh process launch and one unchanged idle check/day
would instead use about 1.6 MB/month for manifests plus an assumed 1-KB overhead
per check. A fresh process does not retain the previous ETag, so its first manifest
still has a body. These figures exclude initial bootstrap, changed records, writes,
auth and other endpoints; actual headers and platform compression can differ.
One hundred independent local catalog changes/day, each causing a manifest check,
would add about 150 MB/month of manifest bodies before trigger coalescing.

A synthetic 1,000-page chapter produced title-update requests of **38,079 → 53
bytes** and page/count/alignment append requests of **38,115 → 224 bytes** using
the actual MangaCore encoders (99.86% and 99.41% reductions). These are request
bodies; transport headers and response receipts are additional.
