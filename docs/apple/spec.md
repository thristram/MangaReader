# Apple implementation specification

`Shared/AppSession` owns ASWeb login, validated identity, serialized refresh, authenticated API access, account snapshot and periodic sync. `CredentialKeychain` stores OAuth credentials per app; `SMBMedia` stores NAS bindings per verified owner/root. Late login/refresh completion is checked against a session generation before credential writes.

`LocalMedia` maps logical storage roots to device bookmarks. File reads resolve safe relative paths under authorized roots. It balances retained security-scope accesses on release. Mac root bindings and snapshots live under the owner cache; they never define cloud ownership.

`SMBMedia` uses dynamic AMSMB2 4.0.3. It requires encrypted share connection, validates share/base/relative paths, downloads to temporary `.partial` files, atomically renames completed files in a private media-ID directory and publishes a manifest only after all paths complete. Manifest fingerprint includes root/path order; stale metadata invalidates the completion manifest. No background transfer/resume/hash verification is claimed yet. Group download walks visible chapters by author/series/work and selects preferred media. Connection details are Keychain-only.

Mac uses NSCollectionView, NSSplitViewController, NSToolbar, sheets, NSOpenPanel, QuickLookThumbnailing, NSPageController, PDFView and AVPlayerView. iPhone uses UIScene lifecycle, UINavigationController / UITabBarController, UITabAccessory, UICollectionView, UIPageViewController, UIScrollView zoom, PDFView and AVPlayerViewController. System bars own Liquid Glass and transition behavior.

MangaCore provides Codable Sendable contract models, field-level locale fallback, inherited NSFW predicate, natural recursive import discovery, root/path validation, same-volume commit journals and Ed25519 ID-token verification. It intentionally knows nothing about UIKit/AppKit UI or server database internals.

Cache JSON is schema v1. New schema versions require migration before decoding; current builds should not silently interpret a future schema as v1. The planned outbox/local database and account switching/offline policy are release work. Inspect [status](../implementation-status.md) for implemented vs pending details, especially alignment, Finder tags, rich thumbnails, author row layout and gesture polish.
