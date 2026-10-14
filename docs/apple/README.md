# Apple apps — setup and usage

The two app targets are native: `MangaReaderMac` uses AppKit, `MangaReaderiPhone` uses UIKit. They share Swift models/network/security/storage policies through `packages/MangaCore` and shared app services. iPhone has no metadata/source-file management UI.

## Xcode setup

1. Install Xcode with iOS/macOS 26+ SDKs (validated with Xcode 27.0 / Swift 6.4).
2. Deployment URLs/resource live in `apps/apple/Config/Service.xcconfig`; the default API is `https://manga-api.thenoirclub.com` and issuer is `https://auth.thenoirclub.com/api/auth`. The supplied public client ID is already in `Base.xcconfig` for both targets. If using different registrations, copy `Local.xcconfig.example` to `Local.xcconfig` and replace both placeholder IDs. Do not leave sample placeholders in an included local file. `$()` between URL slashes avoids xcconfig comment parsing.
3. Open `apps/apple/MangaReader.xcodeproj`. Shared schemes are checked in. Swift Package Manager resolves MangaCore locally and dynamic AMSMB2 **4.0.3** remotely; resolved versions are checked in. Both app targets link AMSMB2 and use an **Embed Frameworks** copy phase with **Code Sign on Copy**. Keep this phase: linking the dynamic package alone does not package it for distribution/device launch.
4. Select Mac or iPhone scheme and destination. Set your Development Team for signed/device builds. Mac sandbox entitlements permit selected read/write files, persistent bookmarks and network client access. iPhone requests local-network access for NAS connections.
5. Register the matching exact callback in thristram-auth; [auth guide](../server/auth-integration.md).

No `.env` is read by an Apple application. `Service.xcconfig` and client IDs are public build configuration; tokens/NAS passwords use Keychain. The deployment file is included after local configuration, so stale local URL values cannot override it. API/issuer/resource/client values are read from the built bundle, never from old UserDefaults entries. Rebuild after changing them; existing saved credentials are restored only when issuer/client/resource still match. Connections settings now configure storage only.

## Mac usage

- While signed out, the entire window shows MangaReader identity and **Sign In**, with no library/sidebar/toolbar. Sign In opens the hosted ASWeb login, not a native credential form. Restore/sign-in shows progress and prevents duplicate requests; cancellation leaves a retryable welcome screen. After identity verification, the unified toolbar and library sidebar appear; the account toolbar icon signs out and returns to the welcome screen, closing old readers/sheets.
- Import opens a native sheet. Drop folders anywhere on it or choose files. Candidates use natural filename sort. Review a prominent cover preview and fill chapter, author, comic, description, tags and source IDs.
- Author/comic fields search existing entries; New Author opens a popup; Create Comic can select/create a series. Tags support existing-name completion and Add/Create. Full removable token-chip editing and alignment popup remain pending.
- Default primary action explicitly adds metadata and moves the clean chapter folder/file into a chosen managed root. Initial mover only supports one-volume atomic moves and refuses mixed folders/overwrite. Add without moving creates metadata only.
- Click a comic to get a chapter grid. The title-adjacent pencil opens the metadata sheet. Save keeps media paths unchanged. Translate calls configured local Ollama and stores preferred-locale text immediately, with no new popup.
- Open a chapter to read using AppKit paging, PDFKit or AVKit. Images fill viewport height; pinch zoom/arrow controls and page favorite/star are present. Reader language control addresses actual media versions.
- Connect an existing storage root to a local/Finder-mounted SMB folder in Connections. Finder-mounted NAS access is delegated to macOS; this initial Mac UI does not configure a direct SMB connection.

## iPhone usage

- UIKit large-title navigation and search, system back gestures, floating tab bar and continue-reading accessory follow Apple Music's structure. Tabs: Library, Continue Reading, Downloads.
- Until identity verification completes, a full-screen UIKit welcome page shows **Sign In** and no navigation bar/tab bar. Successful sign-in reveals the native tabs; sign-out removes them and returns to welcome.
- More menu exposes Authors/Series/Tags/Favorites/Starred/History and Settings. No edit/import/rename/move/reorg/commit/Ollama administration controls.
- Sign in with the registered iPhone public client. Mac-imported metadata appears through automatic snapshot sync.
- In Settings → SMB Storage Roots, connect an existing library root with `smb://host`, share, optional base folder and NAS credentials. These remain account/root-specific in Keychain. The adapter requires SMB3 encryption.
- Root paths are relative to the selected base folder. If the Mac root is `/Volumes/share/Comics`, choose that SMB share and `Comics` as base folder on iPhone. Ensure both bindings describe the same relative hierarchy.
- Tapping a chapter stages its chosen media from SMB into the private download directory before opening; library download buttons support chapter/work/series/author selection. This milestone is a foreground sequential downloader, not a resumable/background streaming engine.
- Images/PDF use native `UIPageViewController` horizontal transitions. Pinch zoom images; language menu preserves numeric alignment. PDF uses one page per transition. Videos use AVPlayerViewController and system codec availability.
- First-open/login requires online account verification in this milestone. Already signed-in sessions can read completed local downloads when NAS is unavailable. Relaunching completely offline, queued state writes and robust revocation/offline policy remain pending.

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

`python3 scripts/verify-mac-auth-ui.py` checks actual Mac controllers in an isolated test bundle: old endpoint/audience preferences are ignored, signed-out content has no library toolbar, busy/error states remain retryable, and account changes/sign-out replace the prior UI and close readers. Synthetic identities are used only in this test harness; this is not proof of hosted login/API authentication.

If code exchange succeeds but the service omits `id_token`, the app reports that the sign-in service did not return an identity token. The Manga resource policy in thristram-auth must retain `openid`, `profile`, `email` and `offline_access` alongside the Manga scopes. Provider 1.7 filters these against the resource policy too. Existing seeded policies require the auth admin's **Native sign-in resource policies → Complete native sign-in scopes** repair action; a deployment/environment change alone does not update the database row. Retry Sign In with a fresh authorization after repairing the policy. Signature, issuer, audience, nonce and API-account verification remain required.

After source file additions/removals, run `python3 scripts/generate-xcode-project.py`. It regenerates the project/plists, creates missing shared schemes, preserves existing schemes and Xcode-managed signing settings, and leaves `Local.xcconfig` untouched. App source currently uses Swift 5 language mode for Apple framework compatibility; shared core uses Swift 6 with Sendable models. The compiler is Swift 6.4.

See [UI spec](ui-spec.md), [Apple requirements](requirements.md), [Apple spec](spec.md), [implementation status](../implementation-status.md) and [mock](../mock/README.md).
