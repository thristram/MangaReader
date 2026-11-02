# Apple implementation specification

Mac All Pages has an AppKit-backed selection mode for image media versions.
`PageBatchPlan` preserves source reading order while updating remaining alignment;
translation and deletion are staged until the separate Commit screen. Both reuse
existing file-organization journals, and Delete retains Recycle copies. No API or
database migration is required. See [batch page editing](all-pages-batch-edit-2026-10-17.md).

Mac Pending Organization derives compact comic/standalone chapter rows from
persisted source-only media roots. Move Files explicitly commits every pending
chapter to the selected archive using the shared import file-organization executor.
Copy/verify, revision-checked metadata and journaled cleanup remain the same;
unfinished work blocks a duplicate move. See [source-only organization](pending-source-organization-2026-10-16.md).

Mac Import & Identify keeps the native whole-page AppKit drop host in both empty and review states. Empty content is a full-size selectable drop surface below the title with 28-point margins. Review uses a fixed 174-point right queue, an independently scrolling adaptive preview/form, and bottom actions outside both scroll views. Narrow widths rearrange the same controls into two action rows; the form remains a single instance. A drag-target binding shows a noninteractive translucent full-area overlay. Page previews use a lazy horizontal thumbnail strip and local selected-URL state, reset per candidate; clicks never modify import page order or the metadata draft. See [layout verification](import-workspace-layout-2026-10-15.md).

iPhone navigation has five native tabs: Library, Reading, Offline, Saved, Authors. Reading and Offline use concise tab labels so the system floating bar gives all five tabs equal widths; the full Continue Reading and Downloads page titles stay intact. No global tab appearance or private view layout overrides are applied. Saved owns a local segmented collection selection, initially Saved Pages, and uses the existing separate entity-level stars and page-level favorite/star records. The circular collection filter presents a native compact-adapted popover with an equal-width icon-over-title collection switch above a divider and compact 44-point filter rows below. Search/sort/unread/tag state remains shared with other collections. Saved-page results deduplicate naturally by personal-state record, filter through visible chapter metadata and inherited tags, and retain canonical page indices when opening the reader. This UI change requires no server contract or data migration.

Author deletion on Mac reassigns all related series/work/chapter metadata to `other author` before deleting the author with revision checks. Media paths and reading state survive; partial failure keeps the author and can resume. Import uses one adaptive form, lazy folder previews and limited indexed dropdown search; bookmark/marker/reference checks during commits run asynchronously off the UI actor. See [behavior and validation](author-removal-and-import-response-2026-10-14.md).

Collection metadata lookup uses `LibraryCatalog` and personal-state indexes invalidated by metadata/state mutations. Cover fetching and decoding use cancellation-aware concurrency limits; image downsampling, filesystem writes and snapshot encoding stay off the main actor. Download availability changes are batched. Direct SMB reads can resolve unique Unicode-equivalent server filenames under the configured base folder after an exact-path `ENOENT`, preserving metadata and NAS files. See [loading and path behavior](collection-loading-and-smb-paths-2026-10-14.md) and [ADR 0012](../adr/0012-background-media-loading.md).

`Shared/AppSession` owns ASWeb login, validated identity, serialized refresh, authenticated API access, account snapshot and periodic sync. `CredentialKeychain` stores OAuth credentials per app; `SMBMedia` stores NAS bindings per verified owner/root. Late login/refresh completion is checked against a session generation before credential writes.

Deployment configuration lives in `Config/Service.xcconfig` (API/resource/issuer) and `Base.xcconfig` / optional `Local.xcconfig` (public client IDs). Bundle configuration is authoritative; obsolete runtime preferences are ignored. `MacRootController` and `PhoneRootController` are thin hosting controllers for `MangaRootScreen`. The SwiftUI root observes verified identity and shows the full-window welcome until an account exists. `LibraryUIModel` resets navigation, readers, editors, transfers and local scope access when identity changes. Status/busy updates remain in the welcome screen. Settings expose device storage/reading/Ollama preferences, not deployment URLs.

`LocalMedia` maps logical storage roots to device bookmarks. File reads resolve safe relative paths under authorized roots. It balances retained security-scope accesses on release. Mac root bindings and snapshots live under the owner cache; they never define cloud ownership.

`MediaReferences` combines existing media-relative paths with device root bindings for read-only editor folder lists and reader Info. It resolves no media contents, respects the reader's actual translation fallback, uses file zero for PDF/video, and distinguishes source paths from offline copies. SMB source display strips credentials/query/fragment; unconfigured-root errors include the requested file and root name/ID. No server contract or migration changes. See [behavior and verification](media-references-2026-10-16.md).

`SMBMedia` uses dynamic AMSMB2 4.0.3. It requires encrypted share connection, validates share/base/relative paths, downloads to temporary `.partial` files, atomically renames completed files in a private media-ID directory and publishes a manifest only after all paths complete. Manifest fingerprint includes root/path order; stale metadata invalidates the completion manifest. No background transfer/resume/hash verification is claimed yet. Group download walks visible chapters by author/series/work and selects preferred media. Connection details are Keychain-only.

AMSMB2 is a pinned local source dependency with its original licenses and patches preserving error details before context destruction and after protocol callbacks close a socket. Closed connections report their stored NT-status mapping/reason, with `ENOTCONN` when no NT status exists; normal logoff exits without another socket read. `SMBNetworkAccess` uses a credential-free Network.framework TCP check before a host's first SMB connection, waits for local-network permission/connectivity, times out and supports cancellation. Readiness is cached per server/port in the media service; it does not claim successful SMB authentication. Connection saving reports stages and verifies the base directory before its library identity. iPhone has neither initialization UI nor permission to initialize through the shared service. Mac initialization additionally requires `manga:manage`. Disconnect cleanup failure cannot invalidate an already saved connection. No encryption downgrade is attempted.

Screens use SwiftUI NavigationSplitView/List/NavigationStack, adaptive LazyVGrid, grouped Form, native sheets/menus and Charts. iPhone TabView owns floating tabs, scroll minimization and the bottom accessory. A horizontally paged UIKit UICollectionView owns phone reader transitions, retaining only the current page and adjacent hosting controllers. Completed interactive transitions publish selection; cancelled transitions keep the page/progress. A small Mac representable delegates interactive paging to NSPageController. Each PDF viewport contains a single copied PDF page, so internal PDFKit navigation cannot drift from the shared reader page counter. Native representables embed NSScrollView/UIScrollView zoom and PDFView; Native Apple video rendering uses AVPlayerView on Mac and a UIView backed directly by AVPlayerLayer on iPhone, without independent native controls. Both share the reader-owned player and transport overlay. QuickLookThumbnailing supplies image/PDF/video covers. See ADRs 0009 and 0011.

On iPhone, image minimum zoom uses the smaller width/height fit ratio and centers unused space. PDFKit minimum scale is its whole-page fit scale. Layout updates do not reset user zoom unless viewport size or content changes. At image fit scale the inner pan recognizer yields to native page navigation; pinch/double-tap remain available. Zoomed pages retain native panning. PDFKit pan is enabled above its fit scale. Media hosting disables safe-area additions and scroll inset adjustment; the canvas extends under system bars while a separate safe-area measurement positions controls. Hidden controls also hide the status bar/system overlays. Video uses AVKit rendering with playback controls in the same overlay as reading controls.

MangaCore provides Codable Sendable contract models, field-level locale fallback, inherited NSFW predicate, natural recursive import discovery, root/path validation, same-volume commit journals and Ed25519 ID-token verification. It intentionally knows nothing about UIKit/AppKit UI or server database internals.

Cache JSON is schema v1. New schema versions require migration before decoding; current builds should not silently interpret a future schema as v1. Pending reading-state intentions now use an owner-local durable outbox; offline metadata editing, a local database and fully offline reauthentication remain release work. Inspect [status](../implementation-status.md) for implemented vs pending details, especially bulk reorganization, separate covers, Finder tags, offline writes and physical-device gesture acceptance.


Reading order and translation mapping use `MediaVersion.pageAlignment` as canonical-to-source indices. Explicit null or out-of-range entries use the original media; source filenames remain unchanged. Text localizations are independent. Edit sheets preserve their initial revision; text translation now queues a resumable job and saves its complete output to the preferred locale; the open editor merges that result when its source/target draft is unchanged. Page order updates only media mapping and informs the parent editor. Import supports manual original/translated page matching and stages language folders before metadata commit. A translation import's description is saved in `localizations[media.language].description`; it does not replace original text.

Import source access is captured before asynchronous work. Finder drops read `NSURL` objects through the native drag pasteboard. `ImportSourceAccess` owns the security scope and captured bookmark; the workspace, background worker and failed-job retry share its lifetime. Source root binding reuses that bookmark rather than minting another during commit. Descendant chapters use the selected ancestor root and relative paths. Normal name parsing uses `ImportName` to extract an ASCII numeric Pixiv prefix; scanner source URLs and filenames remain unchanged.

Standalone PDF/video imports bind the selected file resource. Their logical read directory is its parent, with the original filename as the media-relative path; this never creates or requests a parent-directory grant. Bindings compare their actual selected resource rather than their logical parent so sibling files cannot overwrite one another’s bookmarks. LocalMedia balances security scope on the actual file/directory resource. Directory-based sources and archive destinations retain their existing relative-path behavior and bookmark JSON shape. No API or MongoDB migration is required.

Import shared-source checks use a background-built metadata index cached by owner and metadata generation. Roots are checked lazily, open roots first, and disjoint canonical roots skip their page references. Within a relevant root, common directory prefixes are resolved once; filenames are matched in memory and directory listings with prefetched symlink attributes identify file aliases. File-only sandbox grants fall back to per-reference checks if parent listing is denied. Filesystem answers are not cached between checks. A negative answer is retried when metadata or bindings change; repeated concurrent changes retain originals conservatively. Shared-media protection and copy/journal verification remain intact. See [ADR 0016](../adr/0016-import-source-reference-index.md).

Existing media language corrections use `MediaLanguageChangePlan`. The editor opens a commit review without mutating its draft media. Multi-version plans change only the selected version's existing language-directory component; single-version plans keep paths unchanged. The Mac executor uses `FileOrganization` with the reviewed exact paths, original metadata snapshot, sidecar/empty-folder preservation and bounded cleanup. Exclusive same-volume files use links or journaled rename; shared/cross-volume files remain independent verified copies. Sources renamed before the API update are recovered from their recorded destination identity. Shared references keep originals. Media IDs, alignments, progress references and text locales remain unchanged. See [usage and verification](media-language-corrections-2026-10-14.md).

API clients capture the initiating owner and authentication generation. Their token closure checks both before and after refresh, so a late UI request cannot use a newly signed-in account’s token for the prior account’s draft. UI operations also capture their initiating owner before asynchronous work.

On Mac, a window-scoped local NSEvent swipe monitor provides back/forward navigation while native scroll views retain vertical scrolling. NavigationStack owns route transitions; selecting a new sidebar section clears forward history. Reader image swipes and zoom stay in the media viewport rather than the library navigation monitor.

Mac reader controls use icon-only circles, separate All Pages and bottom-right Full Screen. A window-scoped local key monitor handles right/down (next) and left/up (previous) without a focusable canvas; text, sheets and other/inactive windows are excluded. Mac video transport and reader controls share the same visibility state; Space toggles the shared AVPlayer without video focus. See [reader controls verification](reader-controls-2026-10-15.md).

iPhone reader cells exclusively own their hosted page and restore visible content during display/layout/settle, with deferred stale-callback-safe offscreen teardown. Shared image decodes use bounded permits/autorelease pools (iPhone: one worker, 12MP; Mac: two workers, 24MP). iPhone downward pans dismiss the reader at fit zoom, with spring-back for cancelled/short drags. Shared video transport coalesces seeks, suppresses stale playback ticks during scrubbing and restores play intent after the final exact seek. See [rapid navigation verification](rapid-paging-scroll-and-video-2026-10-15.md).

Video output mounts during asset loading. Item readiness, native first-frame readiness and requested/actual playback are distinct. Concurrent asset preparation validates the video track and primes its first nonempty timeline segment while paused; leading empty MP4 edits are skipped on open/replay without modifying the file. Playback cannot advance ahead of native output readiness. Local-volume downloaded files bypass streaming-buffer prediction; Finder NAS volumes retain buffering, with volume inspection off the main actor. Initial load, generation-checked item observation and first-frame callbacks use the same reader-owned transport as seeks and controls. See [video startup behavior](rapid-paging-scroll-and-video-2026-10-15.md#initial-video-frame-2026-10-20).

### Mac chapter media editing (2026-10-17)

Whole-version removal reuses `PageBatchPlan(removeEntireVersion: true)` and the verified Recycle organization flow. It includes physical files outside the version's current alignment. `PageAppendPlan` preserves existing image order and extends other-language fallbacks. The native image picker retains file grants through review/commit. Empty media lists remain valid chapters and can receive new content without an empty alignment hiding all pages.

File journals persist optional bounded directory cleanup and optional local source bookmarks. Cleanup runs after confirmed metadata, including recovery, using nonrecursive atomic empty-directory removal. See [chapter media editing](chapter-media-editing-2026-10-17.md).

### Page image translation service (2026-10-18)

Mac `MangaImageTranslationService` tests `<base>/openapi.json` and posts multipart `image`/JSON `config` to `/translate/with-form/image`. The upstream web catalog is static; defaults mirror it and persist locally. `MangaTranslationQueue` serializes requests, persists owner-scoped jobs/cache, skips existing target slots and resumes rendered page commits through FileOrganization. A translation placement augments image addition with a fixed target media ID/canonical slot and full-length partial alignment. Node/Vercel is unchanged. See [complete contract and recovery](manga-image-translation-2026-10-18.md).

Image-addition planning compares unchanged paths in memory before any filesystem checks. Only actual relocations resolve other library roots for shared-source detection; path checks run as one background batch. No original-folder cleanup is scheduled for a plain page append. Changed files retain verified copy/commit/cleanup behavior. Queue progress distinguishes destination checks, preparation, copy, metadata save and verification.

Image-addition journals retain optional original metadata for recovery. A newer revision with unchanged media and folder-defining fields can receive only the planned media changes, preserving newer descriptive metadata. Already-committed media requires no metadata rewrite. Old per-page translation journals may infer a baseline only from a unique owner-scoped job/cache-page match, the inverse single-page append, exact existing-file move mapping and verified source/cache digests. Additional append-only target pages are retained when all baseline canonical slots match and the pending slot remains free. Persist the recovered payload/baseline before its API update, retaining changed initial desired metadata as optional `priorMetadata`. Both queue actions read the latest journal; successful file recovery closes the sheet, removes the pending row and updates translation progress without submitting new images. Conflicting media/order/path/parent/original-title changes and unproven generic legacy journals still block recovery.

AppSession reconciles full snapshots with current entities/states by revision. A late polling response cannot replace a higher revision, lose a newly created entity, or resurrect an item deleted while the request was in flight. Persist the merged snapshot with a monotonic write sequence; ignore responses from a previous authentication epoch. Mutation responses also preserve any newer in-memory revision.

Chapter parent selection resolves unique exact titles or an explicit search result to entity IDs. Selecting a comic inherits its author/Series; selecting an incompatible author/Series clears the old child collection. Pending ambiguous searches disable Save with a visible message. Metadata-only reassignment preserves media paths. See [reassignment and organization](chapter-reassignment-and-organization-2026-10-22.md).

Organization plans compare unchanged references before disk access, batch changed paths and shared-source queries, and include original metadata snapshots. Exclusive same-device files use persisted file identities and links or explicitly authorized renames; shared/cross-device files keep SHA-verified copy behavior. New rename targets are checkpointed immediately. See [ADR 0017](../adr/0017-same-volume-organization.md).

Author attribution uses current visible metadata and inherits a missing chapter author from its comic/Series. Preview Info includes name, optional description and direct source links before the file location. Comic detail places source links beside the author; Authors rows expose independent links below the identity row. The shared `SourceLink.destinationURL(author:)` resolves profile/post routes; explicit HTTPS sources retain their full URL. Link rows scroll horizontally and keep 44-point touch heights on iPhone. See [author links](author-source-links-2026-10-22.md).

Reader chapter descriptions share a bounded vertical ScrollView with selectable, wrapping text and source links. Mac's optional bottom pane uses at most 35% of the canvas height (260 pt maximum); its right pane fills available height. iPhone uses an inline, full-width black panel at 85% opacity, extending through the bottom safe area. Its initial height is 40% of the screen, resizable up to 75% through the top grabber; a minimum readable height includes the home-area inset. The media viewport shrinks above it and retains native aspect-fit rendering, without a modal dimming layer. Reader/status controls and inline text-size buttons hide. Tapping media or dragging the panel below its minimum closes it and restores controls; dragging within description text scrolls that text. Long-press the title for smaller/larger text. Font size defaults to 16 pt, changes by 2 pt within 12–32 pt, and is stored device-locally in `ReaderDescriptionFontSize`; the displayed font also follows system body text scaling. This preference does not modify or synchronize chapter metadata. See [usage and verification](chapter-description-reading-2026-10-29.md).

## Collection sorting and editor actions

All Comics and the comic's chapter grid share Update Time, Title and Author sort keys with explicit Ascending/Descending choices on both platforms. Update time initially shows newest first; changing to title/author initially uses ascending order. Title comparison uses the displayed localization and natural numeric order; author sorting resolves inherited attribution. Equal keys use displayed title then entity ID to keep results stable. History/Reading retain their last-read ordering. Sort/filter state remains session-local and shared between collections; no API or database migration.

Mac Edit Comic/Chapter uses a fixed bottom action bar. Delete Comic/Delete Chapter sits at the left; Edit Chapter places Translate Manga immediately after Delete. Cancel/Save remain right-aligned. Delete confirms before invoking the existing revision/active-organization checks and Recycle workflow; canceling confirmation leaves the draft intact. New unsaved items have neither delete nor manga translation actions. Translate Manga uses the existing configuration/confirmation sheet and Translation Queue.

## Import modes, All Pages navigation and unified filters

Mac Import & Identify has a native segmented New Chapter / Translation / Additional Pages control. Fixed-width labels sit on the left of single-line controls; the textboxes share an aligned flexible column on the right. Multiline description and tag inputs retain a heading above. Additional Pages selects an existing chapter and media language and accepts single images or folder candidates. It opens the same `AddImagesScreen` commit review as All Pages, preserving original incoming images and appending in natural filename order. It never creates a new chapter or overwrites its metadata; PDF/video cannot be appended into an existing image version. A new image language can be chosen, with existing directory and alignment safeguards.

Mac chapter tiles now offer a compact icon-and-text Edit / All Pages action row below title/author; comic and Series tiles offer Edit. Download stays on the cover. All buttons are siblings of the open action. All Pages pushes a normal navigation destination, preserves Back/Forward and stays open after successful image additions or batch edits. Clicking a thumbnail opens the reader at that canonical page and selected media language; image, PDF and video media use the existing native preview pipeline. Reader and Edit Chapter may still use their existing modal All Pages/Page Order flows.

Collection filtering uses a circular system filter icon in a consistent location: Mac window toolbar immediately before the system Search your library field; iPhone collection navigation bar top-right, including comic detail, Authors and Downloads. Remove inline sort menus/tag chips from the collection header. Keep all/unread/tag/sort/direction actions and Saved's Starred/Saved Pages switch. All Pages retains canonical reading order and a media-language picker; management/settings pages do not gain irrelevant collection filters. No server API or database migration is required.


### Commit performance across editing flows

All organization entry points use the common path/shared-reference planning and
journal executor, including translations, Additional Pages and media-language
changes. Same-volume chapter/version/page deletion renames exclusive files into
Recycle with object guards; retained/shared files stay protected. Independent
copies verify source and copied bytes once each and reuse exact object guards
for later checks, falling back to SHA after identity changes. Deletion planning,
source canonicalization and pending-journal scanning run outside the UI actor;
unchanged completed journal bodies are not repeatedly parsed. Recovery/collision
checks remain mandatory. Details and compatibility: [ADR 0017](../adr/0017-same-volume-organization.md).


### iPhone Preview info and description controls

The top-right control contains direct `info.circle` and `text.alignleft` buttons
in a shared glass capsule when the displayed chapter description is nonblank.
Whitespace-only/absent descriptions leave a single circular Info button. Resolve
description availability through the same preferred-language/original fallback as
the displayed text. Info opens the existing author/file-location sheet; Description
opens the existing resizable inline panel and hides reader controls. Each button
retains a 44-point target and a separate accessibility label. Mac controls and
metadata/API/storage remain unchanged.


### Demand-driven synchronization

Follow [ADR 0018](../adr/0018-demand-driven-sync-and-small-mutations.md). Mac has no
fixed short polling loop: launch, successful catalog edits, manual refresh and a
single long-idle/return check request a lightweight owner manifest. No-change
responses do not rebuild collections. iPhone polls manifests only while active at
120-second intervals. Coalesce simultaneous requests and retry transient failures
with backoff. Five-second progress windows retain latest intention, immediate
exit/background flush and account-local disk recovery; 409 reloads only one state.
Persist a changed-field mask with each pending state and merge those fields into
the freshest state before every send, including restored outboxes without a 409.
Reading progress cannot overwrite remotely edited favorite/star flags, and an
explicit star toggle cannot overwrite a remotely edited favorite.
The chapter/translation editor uses small JSON PATCHes plus receipts; expand wire
path directories into the existing media model before storage/reading.


### Novel descriptions and text translation — 2026-11-02

[Long-text behavior](long-text-translation-2026-11-02.md) supersedes the prior
single-request structured-output translation. Read long descriptions with bounded
background segmentation/cache and lazy selectable blocks, preserving font controls.
Translate actions queue resumable jobs with chunk progress; default 1,500 source
characters / 16,384 context / 4,096 output tokens apply across model selections.
Jobs survive editor closure, save completed chunks locally and publish a complete
field without overwriting a changed source or manual translation.
