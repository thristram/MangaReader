# Verification — 2026-10-13

This records checks actually performed for the first development milestone. It does not claim a completed P0 release or a live production deployment.

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
