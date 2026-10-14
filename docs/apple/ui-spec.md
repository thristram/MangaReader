# Native UI specification

This is the intended full UI, including screens pending implementation. [Implementation status](../implementation-status.md) lists current coverage. Historical editable mock: [docs/mock](../mock/README.md).

## Shared visual rules

System appearance/type/accessibility; UI starts in English. Content titles/descriptions prefer the chosen manga language independently. Use real AppKit/UIKit bars, menus, sheets, collection views, native transitions and Liquid Glass on OS 26+. One Mac unified toolbar row; no second application navbar. iPhone large titles/search and floating system tabs. Use vertical scroll, back swipe, horizontal reader paging in their native contexts; respect VoiceOver, keyboard and Reduce Motion.

Common comic/chapter tile: cover, title, optional author/progress line. Download icon overlays upper-right cover. Mac pencil is icon-only beside title, top aligned with title and right aligned with cover edge. iPhone has no pencil. No language selector on thumbnails. NSFW covers never leak through hidden views.

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
| Reader | Image fills height to edges, Photos-like page transitions, pinch zoom/fullscreen/fit controls; top-right small language button; optional thumbnails/description; page favorite/star. |
| PDF Reader | Same reading navigation, PDFKit pages; no invented page files; same progress/marks/language semantics. |
| Video Reader | System AVKit playback and thumbnail; chapter favorite/star/progress; explicit unsupported-codec state. |
| Page Overview | All chapter thumbnails; select page; Preview-like drag order editing and separate file-renumber plan. |
| Tags | Account-wide searchable tag list; create/edit/merge/name/color and NSFW designation. |
| Tag Detail | Collection filtered by tag, respecting inherited tags and NSFW preference. |
| History | Library-style collection with last-read/current page and edit/download; history clearing does not erase media. |
| Statistics | Active time/pages/unique completed chapters; real data and NSFW-aware totals. |
| Downloads | Library-style collection plus download state/progress/pause/retry/remove-local-copy; edit where Mac supports it. |
| Storage Roots | Account roots, local/SMB binding and access status; never cloud-save raw credentials. |
| Import & Identify | Whole-page drop target plus visible drop/select box. Thumbnail-first sequential candidate review, searchable author/comic/tags, chapter description and source ID inputs. Default Add to Library & Move Files. |
| Pending Organization | Exact source→destination/file rename plan, conflicts/changed files, review and explicit Commit. Metadata already autosaved. |
| Conflict Review | No-overwrite choices, collision/external-change detail, safe destination alternatives; preview before commit. |
| Commit Result | Per-operation success/failure/recovery status with retry only after journal reconciliation. |
| Settings → Connections | Local/mounted SMB root bindings only; API/auth deployment configuration is in the project. |
| Settings → Reading | UI language, preferred content language, fallback, reader fit/direction/description and NSFW display. |
| Settings → Ollama | Local host/model URL, model, editable system prompt and test connection. |
| Settings → Sync | Verified account/device, sync state/conflicts/outbox/cache and sign-out. |

## Mac popups

- **Edit Chapter/Comic/Series:** title/description, original locale, existing localized text, immediate retranslate, searchable removable tag chips, links, cover and reading order as relevant. Save metadata automatically/explicitly without moving files; stage any necessary reorg separately.
- **New Author:** name and multiple publisher/source site identities. Created author is immediately available in import search.
- **Create Comic:** title, author and optional searchable/create-new series.
- **Align Translation:** side-by-side page thumbnails / ordering of original and imported variant, additions/missing pages and manual mapping. Media translation remains independent of localized titles/descriptions.
- **Tag Picker:** selected colored chips in searchable input, dropdown of existing tags and Create New Tag; no language-specific tag vocabulary.
- **Add SMB:** device-side host/share/base path/login and encrypted connection test; no secret cloud sync.

## iPhone pages

| Page | UIKit behavior |
| --- | --- |
| Library | Root large title and search, two-column cover grid, filter/sort More menu; download only, no edit. |
| Comic / Series Detail | Push to the same chapter collection layout; swipe back; no separate chapter/language management page. |
| Authors | Row-based author browse; works thumbnails on right; tap to author collection; download all. |
| Tags / Tag Results | Browse/search/filter existing metadata only, no create/rename/tag assignment. |
| Continue Reading | Root tab, chapter collection and bottom accessory that resumes latest visible chapter. |
| Favorites / Starred / Saved Pages | Library-like grids and personal-state toggles; no metadata edit. |
| History | Chapter collection with resume; respects NSFW hiding. |
| Statistics | Reading statistics view; no management entry points. |
| Downloads | Root tab, chapter collections and local download actions, queued/progress/offline state. |
| Reader / PDF / Video | Hide tab bar; image viewport full-height; native Photos-like horizontal transitions, pinch zoom, top-right language menu, personal page marks. Tap toggles controls. |
| Thumbnails | All-page collection navigates to selected page; no source-page reordering. |
| Settings | Native inset grouped lists → storage/read/sync subpages; SMB Keychain bindings, preferred manga language, NSFW, cache/download controls and sign-out. No endpoint editor or Ollama administration. |
| Sign-in | Full-screen UIKit welcome with app identity, Sign In and progress/error/retry. No nav bar/tab bar. Button opens hosted ASWeb login; verified identity reveals tabs, sign-out returns to welcome. |

## Gestures and state

System navigation controllers own push/pop and edge-back interactions. Readers use native page containers; zoom pan should not accidentally page. Vertical library scroll drives native tab minimization; continue-reading accessory participates in the system tab environment. No custom imitation of tab-bar glass/position animation. Changing media language retains canonical alignment; missing media/text fallbacks are separate. Popup confirmation is reserved for actual edit/create/commit flows, never required to pick a translation target on one-click text translate.
