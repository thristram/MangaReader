# Apple apps — setup and usage

The two app targets are native: `MangaReaderMac` uses AppKit, `MangaReaderiPhone` uses UIKit. They share Swift models/network/security/storage policies through `packages/MangaCore` and shared app services. iPhone has no metadata/source-file management UI.

## Xcode setup

1. Install Xcode with iOS/macOS 26+ SDKs (validated with Xcode 27.0 / Swift 6.4).
2. Copy `apps/apple/Config/Local.xcconfig.example` to `Local.xcconfig`; enter HTTPS API, issuer, permanent resource and two public OAuth client IDs. The sample uses `$()` between URL slashes to avoid xcconfig comment parsing.
3. Open `apps/apple/MangaReader.xcodeproj`. Shared schemes are checked in. Swift Package Manager resolves MangaCore locally and dynamic AMSMB2 **4.0.3** remotely; resolved versions are checked in.
4. Select Mac or iPhone scheme and destination. Set your Development Team for signed/device builds. Mac sandbox entitlements permit selected read/write files, persistent bookmarks and network client access. iPhone requests local-network access for NAS connections.
5. Register the matching exact callback in thristram-auth; [auth guide](../server/auth-integration.md).

No `.env` is read by an Apple application. `Local.xcconfig` contains public values, not secrets; tokens/NAS passwords use Keychain. Connections settings can override public values at runtime; changing account connection settings signs out.

## Mac usage

- Sign in through the toolbar account icon. The unified toolbar stays in one row; library navigation is in the sidebar.
- Import opens a native sheet. Drop folders anywhere on it or choose files. Candidates use natural filename sort. Review a prominent cover preview and fill chapter, author, comic, description, tags and source IDs.
- Author/comic fields search existing entries; New Author opens a popup; Create Comic can select/create a series. Tags support existing-name completion and Add/Create. Full removable token-chip editing and alignment popup remain pending.
- Default primary action explicitly adds metadata and moves the clean chapter folder/file into a chosen managed root. Initial mover only supports one-volume atomic moves and refuses mixed folders/overwrite. Add without moving creates metadata only.
- Click a comic to get a chapter grid. The title-adjacent pencil opens the metadata sheet. Save keeps media paths unchanged. Translate calls configured local Ollama and stores preferred-locale text immediately, with no new popup.
- Open a chapter to read using AppKit paging, PDFKit or AVKit. Images fill viewport height; pinch zoom/arrow controls and page favorite/star are present. Reader language control addresses actual media versions.
- Connect an existing storage root to a local/Finder-mounted SMB folder in Connections. Finder-mounted NAS access is delegated to macOS; this initial Mac UI does not configure a direct SMB connection.

## iPhone usage

- UIKit large-title navigation and search, system back gestures, floating tab bar and continue-reading accessory follow Apple Music's structure. Tabs: Library, Continue Reading, Downloads.
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

After source file additions/removals, run `python3 scripts/generate-xcode-project.py`. It regenerates shared schemes/project/plists but leaves `Local.xcconfig` untouched. App source currently uses Swift 5 language mode for Apple framework compatibility; shared core uses Swift 6 with Sendable models. The compiler is Swift 6.4.

See [UI spec](ui-spec.md), [Apple requirements](requirements.md), [Apple spec](spec.md), [implementation status](../implementation-status.md) and [mock](../mock/README.md).
