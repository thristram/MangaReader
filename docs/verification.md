# Verification — 2026-10-13

This records checks actually performed for the first development milestone. It does not claim a completed P0 release or a live production deployment.

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
