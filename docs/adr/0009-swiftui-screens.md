# ADR 0009 — SwiftUI screens on Mac and iPhone

Status: Accepted, 2026-10-14. Updates the presentation decision in ADR 0006; requested by the user after reviewing the incomplete native UI.

Reader paging refinement: [ADR 0011](0011-iphone-native-reader.md) embeds UIKit's scroll-style page controller inside the shared SwiftUI reader. Library/navigation screens remain SwiftUI.

Both targets render their welcome, library, detail, settings and reader screens in SwiftUI. macOS uses NavigationSplitView and a native sidebar List with SF Symbols and text, grouped headings, settings submenus and an account footer. One unified toolbar contains navigation and actions. iPhone uses NavigationStack and native TabView with large titles, search, floating Liquid Glass tabs and the system continue-reading bottom accessory. No storyboard is used.

AppKit/UIKit remain responsible for application/window/scene lifecycle and host SwiftUI through NSHostingController/UIHostingController. The existing manual NSApplication bootstrap is retained because this target has no main nib. Hosting sizing is explicit so content does not shrink the initial Mac window. Public AppKit sidebar appearance/native swipe adapters, NSPageController on Mac, PDFKit, AVKit, QuickLookThumbnailing and native zoom scroll views remain system components embedded in SwiftUI; ASWebAuthenticationSession and Keychain are unchanged.

LibraryUIModel provides presentation/navigation, owner-scoped local/SMB media access, downloads and serialized personal-state writes. It does not replace AppSession authentication, API ownership or the MongoDB contract. Account changes dismiss editors/readers, cancel transfers and release local root scopes. NSFW filtering applies before collections and reader access. Editors retain their starting revision and refuse silent overwrites of newer metadata.

The approved historical mock is preserved. An isolated preview target is generated under ignored .build with synthetic media, a separate bundle ID/cache and an invalid OAuth client configuration. Preview fixtures never enter production targets. Native screenshots and page coverage live in docs/mock/native and docs/apple/ui-verification.md. Visual preview is not evidence of authenticated API writes, NAS interoperability or device gesture acceptance.

Consequences: shared screen components keep the card/detail/editor design consistent across platforms, while iPhone omits management controls. Native navigation owns back transitions/tab minimization and accessibility. OS 26 remains the baseline; the iOS 26.1 accessory API is guarded with a 26.0 fallback. File reorganization, background jobs and offline write durability remain separate release work.
