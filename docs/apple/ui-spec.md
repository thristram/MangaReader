# Native UI specification

iPhone reader controls follow Photos: circular back and description controls in the top corners, centered chapter/comic-or-author title opening All Pages, an icon-only globe language button at bottom-left, page navigation/count at bottom-center and page star at bottom-right. The native language Picker reserves checkmark space for every row. See [current reader behavior and validation](photos-reader-and-scroll-crash-2026-10-14.md).

This is the intended full UI, including screens pending implementation. [Implementation status](../implementation-status.md) lists current coverage. Historical editable mock: [docs/mock](../mock/README.md).

## Shared visual rules

System appearance/type/accessibility; UI starts in English. Content titles/descriptions prefer the chosen manga language independently. Use SwiftUI system navigation, bars, menus, sheets, adaptive collections, native transitions and Liquid Glass on OS 26+. One Mac unified toolbar row; no second application navbar. iPhone large titles/search and floating system tabs. Use vertical scroll, back swipe, horizontal reader paging in their native contexts; respect VoiceOver, keyboard and Reduce Motion.

Common comic/chapter tile: cover, title, optional author/progress line. Download icon overlays upper-right cover. Mac uses compact icon-and-text Edit / All Pages buttons below title/author (All Pages for chapters only); the action row is separate from the tile open control. iPhone has no editing action. No language selector on thumbnails. NSFW covers never leak through hidden views.

Collection filters use the same compact popover content. On Mac the circular control sits to the left of system toolbar search; on iPhone it is at the collection navigation bar’s top-right. Keep all/unread/tag/sort/direction and Saved’s Starred/Saved Pages switch.

## Mac pages

| Page | Content and actions |
| --- | --- |
| Sign-in | Full-window app identity, Sign In and progress/error/retry. No sidebar/library toolbar or configuration form. Button opens hosted ASWeb login; cancellation remains on welcome. |
| Library / All Comics | Shared cover grid; search, sort/filter and unread/progress state; work opens detail, standalone chapter opens reader; download/edit on tiles. |
| Continue Reading | Chapter tiles with current page/progress, resume action and edit/download where applicable. |
| Favorites | Same collection grid; favorite entities, authors and pages as appropriate; toggle/remove favorite. |
| Starred | Same grid, distinct from favorites; starred entities/pages. |
| Saved Images | Image/page grid; click opens original chapter/page; stored marks do not copy source media. |
| Authors | One horizontal row per author; avatar/name left; several work covers right. Search; create/edit/download author. |
| Author Detail | Author metadata/site links and that author's series/works/standalone chapters; download all. |
| Series | Same cover grid as Library, with edit/download. |
| Series Detail | Work/chapter collections under selected series; editable localized text/tags/links; download group. |
| Comic Detail | Simple chapter collection, no complex hierarchy panel. Title/description translate button → preferred language immediately; tiles retain edit/download. |
| Reader | Edge-to-edge canvas, Photos-like page transitions, pinch zoom/fullscreen/fit controls; Mac defaults to height fit, iPhone defaults/minimizes to whole-page fit. Circular icon controls: top-left Back + Thumbnail Sidebar; top-right Language + All Pages + Options, without text/chevrons; Full Screen at bottom-right. Centered page navigation/marks, immediate arrow-key navigation (right/down next; left/up previous). Optional description. |
| PDF Reader | Same reading navigation, PDFKit pages; no invented page files; same progress/marks/language semantics. |
| Video Reader | AVKit rendering; play/pause/seek/time/mute shares the reader overlay visibility on both platforms, with no separate native hover/focus bar; Mac Space toggles playback. Chapter favorite/star/progress; explicit unsupported-codec state. |
| Page Overview | Mac chapter tiles open a normal All Pages navigation page; thumbnails open the reader at that page/language. Add Images accepts one or more images and opens an explicit destination/language commit review. Reader/edit sheets retain their existing overview/order flows. Mac Edit adds native click/range/rectangle multi-selection with blue circle checks and Select All, Deselect All, Set as Translation, Delete. Translation opens Alignment then Commit; Delete opens a Recycle commit review. Existing Page Order editing remains separate. |
| Tags | Account-wide searchable tag list; create/edit/merge/name/color and NSFW designation. |
| Tag Detail | Collection filtered by tag, respecting inherited tags and NSFW preference. |
| History | Library-style collection with last-read/current page and edit/download; history clearing does not erase media. |
| Statistics | Active time/pages/unique completed chapters; real data and NSFW-aware totals. |
| Downloads | Library-style collection plus download state/progress/pause/retry/remove-local-copy; edit where Mac supports it. |
| Storage Roots | Account roots, local/SMB binding and access status; never cloud-save raw credentials. |
| Import & Identify | Empty state: drop/select surface fills the space below the title with matching 28-point padding. Review state: single vertical folder queue on the right, independently scrolling preview/metadata area and fixed bottom actions; narrow windows use two action rows. The drop box hides during review; dragging anywhere shows a full-area translucent drop overlay. All page thumbnails scroll horizontally; selecting one updates the large preview without changing page order or the metadata draft. Searchable author/comic/tags, chapter description and source IDs remain. Pixiv-prefixed names pre-fill the ID and remove the prefix from the title. Native New Chapter / Translation / Additional Pages segments switch mode. Single-line labels sit on the left; textboxes share an aligned column on the right. Translation hides normal metadata fields; select the original chapter and edit only media language/description. Additional Pages selects an existing chapter and opens the same image append commit review as All Pages. Default Add to Library & Move Files. |
| Pending Organization | Source-only comics and standalone chapters appear as compact rows, with a shared Move to destination and per-row Move Files commit. Existing journal recovery, conflicts and rename reviews remain below. Metadata already autosaved. |
| Conflict Review | No-overwrite choices, collision/external-change detail, safe destination alternatives; preview before commit. |
| Commit Result | Per-operation success/failure/recovery status with retry only after journal reconciliation. |
| Settings → Connections | Local/mounted SMB root bindings only; API/auth deployment configuration is in the project. |
| Settings → Reading | UI language, preferred content language, fallback, reader fit/direction/description and NSFW display. |
| Settings → Ollama | Local host/model URL, model, editable system prompt and test connection. |
| Settings → Sync | Verified account/device, sync state/conflicts/outbox/cache and sign-out. |

## Mac popups

- **File references:** Edit Comic / Edit Chapter includes Referenced Folders, grouped by chapter/media version and distinct folder. Preview Options includes Info with selectable source/root-relative/on-device paths. iPhone Preview shows direct Info and Chapter Description icons in one top-right glass capsule; without a nonblank displayed description, only circular Info remains. See [file-reference behavior](media-references-2026-10-16.md).

- **Edit Chapter/Comic/Series:** title/description, original locale, existing localized text, immediate retranslate, searchable removable tag chips, links, cover and reading order as relevant. Save metadata automatically/explicitly without moving files; stage any necessary reorg separately.
- **Change Media Language (Mac):** each media row in Edit Chapter → Chapter Content has a language dropdown. Selecting another language opens the commit sheet with old/new language and folder paths. Cancel keeps the original selection. Commit saves the current chapter draft and applies the reviewed folder change. Duplicate media languages and existing target folders are blocked. Single-version chapters show a language-only commit, retaining the existing language-free path.
- **New Author:** name and multiple publisher/source site identities. Created author is immediately available in import search.
- **Create Comic:** title, author and optional searchable/create-new series.
- **Align Translation:** side-by-side page thumbnails / ordering of original and imported variant, additions/missing pages and manual mapping. Media translation remains independent of localized titles/descriptions.
- **Tag Picker:** selected colored chips in searchable input, dropdown of existing tags and Create New Tag; no language-specific tag vocabulary.
- **Add SMB:** device-side host/share/base path/login and encrypted connection test; no secret cloud sync.

## iPhone pages

The native bottom tabs are equally sized: Library, Reading, Offline, Saved, Authors. Offline opens Downloads; concise tab labels preserve system layout and animation.

| Page | Native SwiftUI behavior |
| --- | --- |
| Library | First tab; large title and search, two-column cover grid, circular Photos-style filter button opening a native popover; download only, no edit. |
| Comic / Series Detail | Push to the same chapter collection layout; swipe back; no separate chapter/language management page. |
| Authors | Fifth tab; row-based author browse; works thumbnails on right; tap to author collection; download all. |
| Tags / Tag Results | Browse/search/filter existing metadata only, no create/rename/tag assignment. |
| Reading | Second tab (Continue Reading collection), chapter collection and bottom accessory that resumes latest visible chapter. |
| Saved | Fourth tab combining Starred comics/chapters and Saved Pages; defaults to Saved Pages. Circular filter button opens a native popover: Starred / Saved Pages switch with an icon above each label, divider, Filters, All Items / Unread / Tags, then sorting. Rows retain 44-point touch targets without extra inter-row spacing; unselected rows reserve checkmark space. Saved pages use search, inherited tag, unread and NSFW filters; pages marked both favorite and starred appear once. Marks stay unchanged when switching. |
| Favorites | Library-like grid and personal-state toggles, accessible through More; no metadata edit. |
| History | Chapter collection with resume; respects NSFW hiding. |
| Statistics | Reading statistics view; no management entry points. |
| Downloads | Third tab labeled Offline, chapter collections and local download actions, queued/progress/offline state. |
| Reader / PDF / Video | Hide tab bar; canvas extends beneath system bars, with overlay controls outside the notch/Home indicator. Images/PDF fit the complete page at minimum zoom; pinch/double-tap enlarges images and permits pan. UIKit scroll-style page transitions track the finger; only a completed swipe changes page/progress. Top-right language menu and personal page marks. Tap toggles controls and system overlays. Swipe down at minimum zoom exits Preview; short/cancelled drags spring back, while zoomed pages retain panning. Video uses AVKit rendering; playback, position/time and mute share the reading overlay and hide/restore with a canvas tap. |
| Thumbnails | All-page collection navigates to selected page; no source-page reordering. |
| Settings | Native inset grouped lists → storage/read/sync subpages; SMB Keychain bindings, preferred manga language, NSFW, cache/download controls and sign-out. No endpoint editor or Ollama administration. |
| Sign-in | Full-screen SwiftUI welcome with app identity, Sign In and progress/error/retry. No nav bar/tab bar. Button opens hosted ASWeb login; verified identity reveals tabs, sign-out returns to welcome. |

## Gestures and state

System NavigationStack containers own push/pop and edge-back interactions. Readers use native page containers; zoom pan should not accidentally page. Vertical library scroll drives native tab minimization; continue-reading accessory participates in the system tab environment. No custom imitation of tab-bar glass/position animation. Changing media language retains canonical alignment; missing media/text fallbacks are separate. Popup confirmation is reserved for actual edit/create/commit flows, never required to pick a translation target on one-click text translate.

## Current native review

The SwiftUI rewrite and page-by-page checks are recorded in [UI verification](ui-verification.md). This specification retains the full accepted product scope; the status document distinguishes remaining service/storage features from implemented screens.

### Mac chapter content and All Pages additions

Chapter Content places an icon-only trash action beside each version's language/page count. A commit review explains removal of the whole version, or the final version and empty chapter folder. All Pages and Page Order place **Add Images…** beside the heading; the native multi-select picker leads to a language/destination/file-list commit sheet. Empty chapters keep this entry available through Edit Chapter.

### Manga image translation and organization submenus

Settings → Manga Image Translation uses a native grouped form for base URL/Test Connection and shared default options. The bottom of Edit Chapter adds Translate Manga; its confirmation sheet checks connectivity, exposes the same options, chooses source/destination and disables enqueueing until connected. Pending Organization expands to Not Yet Organized, File Management Queue, Translation Queue and Commit History. File rows are newest first and failed rows include Retry/Remove from Queue. Translation rows group by chapter, with description, target language, page progress and errors; chapter buttons open a native thumbnail grid and zoomable generated-page preview.
