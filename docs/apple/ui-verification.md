# SwiftUI UI review — 2026-10-13/14

Mac and iPhone screens were rebuilt against the saved mock and the Apple Music references. The original editable mock remains under docs/mock; native captures are in [the screenshot gallery](../mock/native/index.html). These screenshots use generated covers/pages, a generated six-page PDF and an intentionally partial Chinese media version, with a separate preview identity/cache. They contain no personal comics or credentials.

## Presentation coverage

| Screens | Implementation and checks |
| --- | --- |
| Welcome | Full-window SwiftUI identity/Sign In, progress and retryable error; no private navigation before verified identity. Root/account reset is covered by the isolated harness. |
| Mac navigation | Native NavigationSplitView/sidebar, aligned SF Symbols + text, section headings, settings submenus/account footer and one unified toolbar. Window-scoped native swipe events retain back/forward history. A public AppKit appearance adapter keeps the neutral selected row visible. |
| iPhone navigation | Native NavigationStack/TabView, large titles and a system pull-down search drawer; floating system tabs/minimization and continue-reading bottom accessory. Actual portrait simulator capture plus native iPhone-on-Mac navigation inspection. Mac compatibility mode uses the system's iPad-style tab position; this is not the iPhone tab position. |
| All Comics / Search / Continue / Favorites / Starred / Series / History | Shared cover grid, filtering/sorting and actual metadata/state. Download overlays the cover; Mac pencil aligns with title top/cover right. No language controls on cards. |
| Authors / author detail | Avatar/name on the left, work previews on the right; author collection contains series, ungrouped works and standalone chapters. Download All walks visible chapters. |
| Comic / series detail | Simple child collection, metadata/links, reading/download/personal-state controls and Mac edit. Title/description translation goes directly to preferred language without another popup. |
| Tags / tag results | Search/select/create/edit on Mac; browse/filter on iPhone. Token chips can be removed and the dropdown offers creation. NSFW hides inherited content throughout browsing/reading/download lists. |
| Saved Pages | Actual image/PDF page previews and jump to canonical page. Personal marks use existing API state. |
| Downloads | Shared completed-download cards, foreground activity, cancel/retry, remove-local-copy context action. No source-file management on iPhone. |
| Statistics | Native Charts and saved reading time/completion data. Full historical session/page analytics remain release work. |
| Reader | Default height filling, native image zoom and interactive paging (NSPageController on Mac; page-style TabView on iPhone), language menu, optional thumbnails/all-page grid and adaptive description position based on page ratio/available width. Chrome stays separate from the full-height canvas. |
| PDF | PDFKit displays a single copied page per native paging viewport, preventing internal PDF navigation from drifting from the shared page counter. Source remains a PDF chapter. |
| Video | AVKit playback and system thumbnails, explicit unsupported-codec state, completion on playback end. Codec coverage and persisted playback seek position need release acceptance. |
| Edit / create | Native SwiftUI sheets with original/localized text, direct translation, searchable author/comic/series fields, tags, multiple source links and page order. Concurrent metadata revisions are refused rather than silently overwritten. New items without authors use other author. |
| Page order / translation alignment | Drag source-page order on Mac; save canonical mappings without renaming files. Other language mappings follow the reordered canonical positions. Import mapping compares original/imported thumbnails and lets each page use a match or original fallback. Extra imported pages remain preserved in source. Saved page positions currently follow the new reading order. |
| Import & Identify | Whole-page drop plus visible drop/select box, recursive naturally sorted candidates, thumbnail-first sequential review and searchable metadata. Primary Add to Library & Move Files opens destination selection, then an exact commit review. One picker handles both source and destination modes. |
| Pending Organization / recovery | Actual account journals, source/destination/status and a recovery sheet. Reconciliation requires a completed move and matching revision. The full bulk planner/conflict alternatives are not yet implemented. |
| Settings | Mac sidebar subpages: General, Reading & Language, Ollama, Connections, Sync & Account, Files & Backup. iPhone grouped settings omit metadata/file/Ollama administration. API/auth endpoint remains project configuration. |

## Verification boundaries

Native builds, embedding/signatures, generator stability and the UI/model checks are listed in [verification](../verification.md). Synthetic preview identity is confined to separate generated targets; real app targets always use the existing verified ASWeb login. API token closures now capture owner/auth generation, and asynchronous UI work checks its initiating owner.

The visual workflow exercises navigation, collections, edit/create/tag-search sheets, import selection/sequential review and readers. No preview action is evidence of a production API write, a real NAS move/download, or local Ollama model output. Hardware swipe/pinch behavior, VoiceOver/Dynamic Type/Reduce Motion, real NAS interoperability and live integration acceptance still need device testing. [Implementation status](../implementation-status.md) separates remaining P0 service/storage work from available screens.

## Repeat the review

```sh
python3 scripts/preview-native-ui.py mac
python3 scripts/preview-native-ui.py phone --destination 'platform=iOS Simulator,id=<local-simulator-id>'
# Or open .build/native-ui-preview/apps/apple/MangaReader.xcodeproj and run its iPhone scheme.
python3 scripts/verify-apple-project.py
python3 scripts/verify-mac-auth-ui.py .build/xcode-swiftui-mac
```

The preview script excludes Local.xcconfig/user workspace state, gives both targets a distinct bundle identifier, generates media privately and uses an invalid OAuth configuration. It never restores production credentials or schedules sync. Only its generated delegates include the fixture entrypoint; none is part of the real project. Build Mac/phone previews sequentially because they share the isolated source copy. Regenerate screenshots after visual changes rather than editing the approved historical mock in place.
