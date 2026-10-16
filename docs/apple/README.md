# Apple apps — setup and usage

Mac supports [deleting authors while preserving their works](author-removal-and-import-response-2026-10-14.md). The same note documents the single-form import layout, bounded Comic search and background commit checks.

The iPhone reader now uses Photos-style corner controls and a centered title/page counter. See [reader UI, SMB scrolling crash and native Mac first-drop fixes](photos-reader-and-scroll-crash-2026-10-14.md) for behavior, verification and migration notes.

The two app targets are native: both `MangaReaderMac` and `MangaReaderiPhone` use SwiftUI, hosted by AppKit/UIKit lifecycle controllers. They share Swift models/network/security/storage policies through `packages/MangaCore` and shared app services. iPhone has no metadata/source-file management UI.

Cover loading and large chapter collections use indexed metadata and bounded background work. Direct SMB reads handle unique canonically equivalent Unicode filenames without changing NAS files. See [behavior, tests and migration](collection-loading-and-smb-paths-2026-10-14.md).

## Xcode setup

1. Install Xcode with iOS/macOS 26+ SDKs (validated with Xcode 27.0 / Swift 6.4).
2. Deployment URLs/resource live in `apps/apple/Config/Service.xcconfig`; the default API is `https://manga-api.thenoirclub.com` and issuer is `https://auth.thenoirclub.com/api/auth`. The supplied public client ID is already in `Base.xcconfig` for both targets. If using different registrations, copy `Local.xcconfig.example` to `Local.xcconfig` and replace both placeholder IDs. Do not leave sample placeholders in an included local file. `$()` between URL slashes avoids xcconfig comment parsing.
3. Open `apps/apple/MangaReader.xcodeproj`. Shared schemes are checked in. Swift Package Manager resolves MangaCore and dynamic AMSMB2 **4.0.3** locally. The vendored AMSMB2 source preserves error details across context destruction and protocol-triggered socket closure; its upstream commit and licenses are recorded in [patch provenance](../../packages/AMSMB2/MANGAREADER-PATCHES.md). Both app targets link AMSMB2 and use an **Embed Frameworks** copy phase with **Code Sign on Copy**. Keep this phase: linking the dynamic package alone does not package it for distribution/device launch.
4. Select Mac or iPhone scheme and destination. Set your Development Team for signed/device builds. Mac sandbox entitlements permit selected read/write files, persistent bookmarks and network client access. iPhone requests local-network access for NAS connections.
5. Register the matching exact callback in thristram-auth; [auth guide](../server/auth-integration.md).

No `.env` is read by an Apple application. `Service.xcconfig` and client IDs are public build configuration; tokens/NAS passwords use Keychain. The deployment file is included after local configuration, so stale local URL values cannot override it. API/issuer/resource/client values are read from the built bundle, never from old UserDefaults entries. Rebuild after changing them; existing saved credentials are restored only when issuer/client/resource still match. Connections settings now configure storage only.

## Mac usage

- Sign In opens hosted Thristram login in ASWebAuthenticationSession. Until identity is verified, a full-window welcome is the only screen. Sync & Account contains Sign Out; changing accounts dismisses old readers/editors and releases storage access.
- The native sidebar uses SF Symbols + text, grouped Library/Activity/Manage sections and Settings submenus. One unified toolbar contains back, import, sync and search. All Comics, Continue Reading, Favorites, Starred, Series, History and Downloads share cover cards. Download is at the cover's upper-right; the pencil aligns with the title's top and the cover's right edge.
- Authors are horizontal rows with an avatar/name on the left and several work covers on the right. Author/series/comic/tag detail opens a simple child collection. Comic title/description can be translated directly to the preferred content language without another dialog.
- Import & Identify accepts folders dropped anywhere on the page or selected through the dashed drop box. Images are naturally sorted; each PDF/MP4/WebM is a chapter. Multiple candidates are reviewed one at a time. Fill author/comic/description/tags/source IDs; searchable dropdowns offer existing entries and a create popup. A comic can select/create its series.
- Standalone PDF/MP4/WebM drops and file selections retain permission to the selected file itself, without requiring access to its parent folder. Different files in one folder keep independent bindings. See [single-file import verification](single-file-import-2026-10-15.md).
- The empty import drop box fills the page below its title. Once files are selected, a vertical queue sits on the right and actions stay pinned below the independently scrolling form. Drag anywhere to add more; translucent feedback appears over the whole area. Scroll the page thumbnails sideways and click one to change the large preview. See [layout and verification](import-workspace-layout-2026-10-15.md).
- **Add to Library & Move Files** is the primary action. Choose the managed root and review exact source/destination before **Commit & Add to Library**. Clean folders/files move on the same volume only, with no overwrite. Add without Moving keeps source files in place. Mixed folders are add-only.
- Adding an imported chapter as a media translation opens a side-by-side page-matching sheet. Missing translated pages fall back to original media. This import currently keeps existing multilingual source files in place; automatic multi-version relocation remains pending.
- Edit sheets expose original/localized title/description, removable searchable tag chips, NSFW, source IDs and chapter page order. Translate saves immediately. Other edits use Save; a newer revision requires reopening the editor. Page-order drag/drop changes canonical media mapping without renaming original files; other language mappings follow the new order. Saved page marks currently follow their canonical positions. Separate cover files and filename renumber plans remain release work.
- Reader images fill the window height; Mac uses NSPageController and iPhone uses native page-style TabView. Native image zoom, PDFKit and AVKit are retained. Use keyboard/page controls, language menu, thumbnails, all-page overview, optional description and page heart/star controls. Video completes when playback ends, rather than when its single chapter page opens.
- Connections can bind a root to a local/Finder-mounted SMB folder or direct encrypted SMB connection. Downloads support visible author/series/work groups. Completed chapter copies appear under Downloads and can be removed locally.
- Statistics use saved active reading time and completion state. History/Saved Pages respect NSFW hiding. Finder color preferences are visible; automatic Finder tag projection is still pending.

## iPhone usage

- SwiftUI renders native large-title navigation/search, push/back transitions, floating system TabView, scroll minimization and continue-reading accessory. Five equal-width tabs appear in order: Library, Reading, Offline, Saved, Authors. Short Reading and Offline labels keep the native floating tab items equally sized without overriding system layout or animations; Offline opens the Downloads page. More contains series/tag/favorites/history/statistics/settings browsing.
- Saved combines Starred comics/chapters and Saved Pages. It opens on Saved Pages; its circular filter button opens a native popover with a Starred / Saved Pages switch with icons above its labels, divider, unread/tag filters and sorting. Filter rows have no extra inter-row spacing and retain 44-point touch targets. Other comic collections use the same circular filter button. Saved Pages includes both favorite and starred page marks without duplicates; switching collections never changes the marks. Search, inherited tags, unread and inherited NSFW filtering apply to saved pages.
- There are no import, metadata edit, rename, source-file move, reorganization, commit or Ollama administration controls. Personal favorites/stars/reading progress and local download removal remain available.
- Sign In uses the same hosted ASWeb flow; verified identity reveals tabs, and Sign Out returns to the full-screen welcome.
- Settings → Connections binds an existing root to `smb://host`, share and optional base folder. NAS credentials stay per-account/root in Keychain, and SMB3 encryption is required. If a Mac root is `/Volumes/share/Comics`, choose the same share with `Comics` as base folder.
- Save Connection first checks network access with Network.framework, allowing the system's local-network authorization flow to complete. Permit access when iOS asks. iPhone verifies an existing Mac-initialized library and never offers destination initialization. Errors identify the network, SMB session, folder, library validation or Keychain stage. See [SMB troubleshooting](smb-connection-diagnostics-2026-10-14.md).
- Reading/downloading stages preferred chapter media into private storage before opening; author/series/work Download All walks visible chapters. This is a foreground sequential transfer, without background resume or streaming.
- Reader hides tabs and uses native page-style TabView transitions for images/PDF, UIScrollView image pinch/double-tap zoom, PDFView, and AVKit VideoPlayer. The top-right language menu preserves canonical alignment; missing media and missing text have independent fallbacks. Codec failures are explicit.
- First-open/login requires online account verification. An already verified session can read completed downloads without the NAS. Completely offline relaunch and a durable offline state outbox remain pending.

## Cache and recovery

Application Support: `MangaReader/accounts/<verified-ownerId>/` contains snapshot, root bindings, downloads and Mac commit journals. Sign-out clears OAuth tokens/in-memory metadata and hides the retained account directory; it never shows the previous account's library to a new account. NAS credentials remain under account/root keys, and physical offline files remain local for later authorized access.

Before a file move, `commit-journals/<id>.json` records paths/phase and `<id>-metadata.json` records entity/revision/new metadata. See [recovery guide](../data-migration.md). No filesystem changes happen during ordinary metadata editing.

## Build and tests

Root README lists exact unsigned build commands. `swift test --package-path packages/MangaCore` validates path/folder policy and OIDC behavior. Signed NAS/auth/device flows need actual user configuration; compiling does not certify live sign-in, hardware gestures or NAS compatibility.

Check the built application itself, including the Debug dylib's framework references, architectures and nested signatures:

```sh
python3 scripts/verify-apple-frameworks.py /path/to/MangaReaderiPhone.app
# For an intentionally unsigned build, check packaging only:
python3 scripts/verify-apple-frameworks.py .build/xcode-mac/Build/Products/Debug/MangaReaderMac.app --allow-unsigned
```

`AMSMB2.framework` belongs in `Frameworks/` on iPhone and `Contents/Frameworks/` on Mac. Xcode signs the embedded copy with the app's configured identity. Do not disable library validation or manually sign a `PackageFrameworks` build-cache copy to fix a launch failure; that copy is outside the installed app. Apple's [framework embedding guidance](https://developer.apple.com/library/archive/technotes/tn2435/_index.html) describes the required embedding and Code Sign on Copy settings.

If upgrading from a build that failed with `Library not loaded: @rpath/AMSMB2.framework/AMSMB2`, stop the old run, select **Product → Clean Build Folder**, and build/run again. Keep the existing Development Team selected for device or **My Mac (Designed for iPad)** runs. `CODE_SIGNING_ALLOWED=NO` is only for compilation/packaging checks, not a device-run configuration. The verification script reads a completed build; it neither signs nor modifies the app, and packaging checks alone do not certify SMB access.

Mac startup is entirely programmatic. `MangaReaderMacApp.main()` creates `NSApplication`, attaches a `MacAppDelegate` and retains it while the event loop runs. There is no main nib/storyboard to instantiate the delegate. Do not replace this entrypoint with only `@main` on the delegate: the default AppKit entrypoint would run without installing our delegate, so no library window would be created.

After building the Mac target, verify a real visible main window from repository root:

```sh
swift scripts/verify-mac-window.swift
# Or pass another built MangaReaderMac.app path as the first argument.
```

This opens a separate app instance, checks for an onscreen window of at least the app's minimum size, and closes only that instance. Existing Xcode/user instances remain untouched. A successful build or a running process alone does not establish that the UI appeared. This check does not initiate interactive sign-in or change configuration; any saved session follows the app's normal startup restoration behavior. It does not verify reading/NAS/sync behavior. Library/sidebar headings use the window safe area to stay below the unified toolbar; the initial content size is 1200 × 800. See Apple's [NSApplication startup documentation](https://developer.apple.com/documentation/appkit/nsapplication) and [default delegate entrypoint](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/main()).

`python3 scripts/verify-mac-auth-ui.py` checks the SwiftUI root/model in an isolated test bundle: old endpoint/audience preferences are ignored, unconfigured sign-in remains retryable, account changes/sign-out dismiss old reader/editor/navigation state, and collection/search/NSFW filtering uses real fixture metadata. Synthetic identities are used only in this test harness; this is not proof of hosted login/API authentication.

If code exchange succeeds but the service omits `id_token`, the app reports that the sign-in service did not return an identity token. The Manga resource policy in thristram-auth must retain `openid`, `profile`, `email` and `offline_access` alongside the Manga scopes. Provider 1.7 filters these against the resource policy too. Existing seeded policies require the auth admin's **Native sign-in resource policies → Complete native sign-in scopes** repair action; a deployment/environment change alone does not update the database row. Retry Sign In with a fresh authorization after repairing the policy. Signature, issuer, audience, nonce and API-account verification remain required.

After source file additions/removals, run `python3 scripts/generate-xcode-project.py`. It regenerates the project/plists, creates missing shared schemes, preserves existing schemes and Xcode-managed signing settings, and leaves `Local.xcconfig` untouched. App source currently uses Swift 5 language mode for Apple framework compatibility; shared core uses Swift 6 with Sendable models. The compiler is Swift 6.4.

See [UI spec](ui-spec.md), [Apple requirements](requirements.md), [Apple spec](spec.md), [implementation status](../implementation-status.md) and [mock](../mock/README.md).

## Native visual preview

[UI verification](ui-verification.md) documents page coverage, screenshots and limits. `python3 scripts/preview-native-ui.py mac` or `phone` builds an isolated preview under `.build/native-ui-preview`. It copies public build configuration, excludes local overrides, uses a separate bundle/cache and synthetic media, and does not restore a real account. Open the generated Mac app, or run the generated Xcode project with the iPhone scheme. Use a locally available simulator destination; `--destination` can override the default. Never copy preview fixture entrypoints into real targets.

On iPhone, pull down at the top of a collection to reveal the native search drawer. System large-title collapse and tab minimization follow scrolling.

Reader loading diagnostics and the isolated slow-I/O regression command are documented in [reader opening performance](../reader-open-performance-2026-10-14.md).

iPhone whole-page fit, UIKit paging and full-screen layout checks are documented in [iPhone reader verification](iphone-reader-fit-and-paging-2026-10-14.md). Run `python3 scripts/verify-phone-reader.py` with a booted iPhone simulator to build and leave open the isolated synthetic reader for gesture review.

The same simulator checks assert the five native tab labels/order and equal visible item hit-area widths and Saved Pages membership, search, inherited tags, unread and inherited NSFW filtering. The Saved default, segmented collection switching, circular filter popover and fifth-tab author navigation were also reviewed in the native simulator using synthetic media. These checks do not certify physical-device performance or NAS connectivity.

[Collection activation and nested imports](card-and-batch-import-fixes-2026-10-14.md) documents full-card click behavior, selected-directory source bindings, and batch import regression coverage.

[Import access and translation](import-access-and-translation-2026-10-14.md) documents retained Finder/picker grants, failed-job retry, the translation-only form and Pixiv filename suggestions. `python3 scripts/preview-native-ui.py mac --sandbox` builds a separately signed preview with the real sandbox entitlements and synthetic data in its own container.

[Correct an imported media language](media-language-corrections-2026-10-14.md) explains each version's Chapter Content dropdown, reviewed folder rename, conflict checks and recovery. The update uses existing API fields and requires no database migration.

Mac/iPhone reader control updates, keyboard mapping and unified Mac video transport: [behavior and verification](reader-controls-2026-10-15.md).
