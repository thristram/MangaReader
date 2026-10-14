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
