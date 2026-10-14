# Product requirements

Status: accepted product baseline, 2026-10-13. Latest instructions supersede earlier proposals: iPhone is a reader, every app must sign in through ASWeb, UI defaults to English, MongoDB stores metadata, and text translations are independent of media versions.

## Scope and priorities

**P0:** native Mac library management + local/SMB reading; native iPhone SMB reading and private offline downloads; account login and automatic metadata/state sync. **P1:** Tailscale NAS reachability and full media translation with a local worker.

No online comic scraping, extension marketplace, hosted media upload or shared public libraries are requested. Mangayomi provides library/tag/history/statistics inspiration, while Apple Music / Photos / Preview define native layout and interactions.

## Accounts and architecture

| ID | Requirement / acceptance |
| --- | --- |
| ACC-01 | Both Mac and iPhone must sign in to thristram-auth using ASWebAuthenticationSession, hosted sign-in/consent, public clients and S256 PKCE. No embedded password form or native client secret. |
| ACC-02 | All metadata, personal state, storage references, file plans, caches and downloads belong to the verified account. A client cannot supply an owner ID to change ownership. Cross-account CRUD, joins, references, search and sync fail closed. |
| ACC-03 | Signed-out/restore state shows a full-window welcome screen and Sign In; no library/sidebar/tab bar. Hosted ASWeb sign-in reveals library only after identity verification; sign-out returns to welcome and closes private UI. |
| ARC-01 | Control plane (metadata, authorization, revisions, plans) is separate from data plane (local files, NAS SMB bytes, offline copies). Vercel never proxies comic bytes or performs NAS moves. |
| ARC-02 | Small Node.js / TypeScript API deployable on Vercel; MongoDB canonical metadata. Apple and server live in a monorepo with independent builds/deployments. Auth stays separate. |
| ARC-03 | Shared docs plus separate Apple/server docs cover requirements, spec, ADR, API contract, setup, usage and data migration. Samples contain no secrets; public deployment domains may be real and credential placeholders remain unfilled. UI mock is retained in `docs/mock`. |
| ARC-04 | Apple API defaults to `https://manga-api.thenoirclub.com`. Deployment URLs/resource are project configuration, changed by rebuilding, with no runtime endpoint editor; old app preferences cannot override them. |

## Storage and organization

| ID | Priority | Requirement / acceptance |
| --- | --- | --- |
| STO-01 | P0 Mac | Read/manage local and SMB libraries; rename and reorganize explicitly. SMB can use Finder mounting on Mac; iPhone uses a library client. |
| STO-02 | P1 | Reach private NAS through Tailscale. Connectivity is device-side; no Vercel-to-private-NAS assumption. |
| STO-03 | P0 | Layout: `author / optional series / optional comic / chapter / optional language`. Author and chapter required. Unknown author folder exactly `other author`. Skip missing optional levels. |
| STO-04 | P0 | One actual media language omits language folder. Adding another actual media language stages moves for both variants under language folders; text translation alone causes no move. |
| STO-05 | P0 Mac | Metadata changes autosave; filesystem changes await explicit commit and a reviewed plan. Import's primary Add to Library & Move Files action is an explicit commit. No silent moves from editing metadata. |
| STO-06 | P0 Mac | Commit checks collisions, permissions, root containment, traversal, symlinks and external changes; never overwrites. Track recoverable phases; cross-volume/SMB copy verifies content before deleting the source. |
| STO-07 | P0 | iPhone downloads to private account storage and can remove local copies without changing originals. Chapters, comics, series and complete author collections can be selected for download. |
| STO-08 | P0 | JPEG, PNG, WebP and other system-supported common images; PDF as one chapter; MP4/WebM each as one chapter. Video thumbnail comes from system file thumbnailing. Codec support must be checked; accepted import does not guarantee AVFoundation can decode every WebM codec. |

## Import and editing (Mac)

| ID | Requirement / acceptance |
| --- | --- |
| IMP-01 | Drop folders anywhere in Import & Identify. Also provide a visible selectable drop box. Recursively discover candidate chapters; each folder's direct image filenames use natural numeric sorting; folder name initializes chapter title. Mixed image/subfolder layouts require review. |
| IMP-02 | Multiple folders are processed one chapter at a time with visible queue position. Thumbnails dominate the result. Avoid duplicate commit on retry. |
| IMP-03 | Author input searches existing authors, allows creation in a popup and defaults unknown author appropriately. Enter chapter description. |
| IMP-04 | Optional input named Comic searches existing comics and includes Create Comic. Creation can attach the comic to a series. |
| IMP-05 | A candidate can be attached as another media translation of an existing chapter. A popup aligns pages / order with that chapter; unmapped pages fall back safely. |
| IMP-06 | Chapter source inputs accept Pixiv ID, Fanbox post ID and e-hentai gallery ID/token or URL. An e-hentai ID alone can be saved but cannot always reconstruct a usable gallery URL. |
| IMP-07 | Default primary action is Add to Library & Move Files; secondary is add without moving. Preview resulting organization before commit. |
| EDT-01 | Preview-like drag reordering updates reading order. File renaming/renumbering remains a separate staged commit. PDF original page order remains intact unless explicitly exporting a new file. |
| EDT-02 | Auto cover is the lowest-numbered image. Choose a page or separate cover. Written cover defaults to `0.ext`; conflicts are reviewed before writing. |
| EDT-03 | A pencil icon beside each chapter/comic title opens an edit popup; no standalone chapter-language administration page. |

## Metadata, tags and translations

| ID | Requirement / acceptance |
| --- | --- |
| META-01 | Authors hold multiple site links. Series/comic/chapter hold title, localized description, multiple site links, tags, favorites and stars. Pixiv/Patreon/Fanbox/e-hentai IDs or URLs are normalized without losing input. |
| META-02 | Tags are universal within the account. Every Mac tag editor/import input supports search, selected chips, dropdown, selecting existing and creating new tags. Multiple tags supported; direct vs inherited tags distinguishable. |
| META-03 | Favorites and stars are independent; chapter/series/comic and individual image/page can have either. Mac maps these to configured Finder colored tags on folder/file, preserving unrelated tags. PDF per-page marks remain metadata; only the actual PDF file/folder receives Finder tags. Unsupported NAS xattrs show an explicit failure. |
| META-04 | NSFW is a tag with inherited visibility semantics. Automatically hide NSFW from ordinary library, search, thumbnails, favorites, history, downloads and statistics. Explicit display preference reveals it; never deletes it. |
| LNG-01 | App interface defaults to English. Preferred manga language defaults to Chinese (`zh`) and can be changed. Media fallback: preferred → original → available. Text fallback happens independently for each missing field. |
| LNG-02 | One set of images/video/PDF can have multiple localized chapter/comic/series titles and descriptions. Partial translated text falls back to original text. No storage duplication or new media language folder. |
| LNG-03 | Translate buttons appear only on comic detail and edit popup; one click translates title/description into preferred language, with no extra popup. Store/retranslate the locale; preserve original. Translations can be edited manually. |
| LNG-04 | Mac calls the user's local Ollama host. Settings edit model URL/host, model, system prompt, preferred language and connections. A response is validated before saving. |
| LNG-05 | P1 full media translation based on manga-image-translator runs a separate local worker. Review licensing and output alignment. |

## Reading, history and statistics

| ID | Requirement / acceptance |
| --- | --- |
| READ-01 | Image fills reading viewport top to bottom by default, preserving aspect ratio; controls overlay rather than reserve a persistent description pane. No intentional top/bottom padding. Wider images support pan. |
| READ-02 | Native Photos-like left/right paging for images and PDF. Pinch zoom, fullscreen/window, automatic resize, fit width/fit window/original size. When zoomed, pan takes priority. |
| READ-03 | Optional Preview-style thumbnails and a chapter's all-pages grid; selecting a thumbnail opens that page. |
| READ-04 | Reader top-right language button switches media version and keeps aligned page. No language controls on library/detail thumbnails. |
| READ-05 | Description may sit bottom/right according to image ratio, or hide. Default image-first reading. |
| READ-06 | Page favorites/stars, resume progress, completed/unread state; favorite/star UI reflects persisted state. |
| HIST-01 | Automatically record reading history with chapter, page and timestamp. Collection layout, like Library. |
| STAT-01 | Statistics for active reading time, pages and distinct completed chapters; no background-time inflation or double counting. Respect NSFW display rules. |
| SYNC-01 | Description/localizations, tags, favorite/star state and reading progress automatically synchronize between Mac/iPhone. Account cache/outbox survives restart. Conflicts never silently overwrite concurrent edits. |

## Platform UI boundaries

| ID | Requirement / acceptance |
| --- | --- |
| UI-01 | macOS native SwiftUI/Apple frameworks with AppKit lifecycle; Apple Music sidebar and single-row unified toolbar. Native Liquid Glass surfaces, not manually drawn fake glass. |
| UI-02 | iPhone uses SwiftUI system navigation/tab bars with UIKit lifecycle with native positioning, transitions, gestures and Liquid Glass. Apple Music large title/search, floating bottom bar and continue-reading accessory. |
| UI-03 | Native directional navigation: vertical scrolling, horizontal paging and back swipes where applicable. Preserve platform gesture meanings rather than forcing every direction into every screen. |
| UI-04 | Library and comic detail use the same thumbnail grid. Download overlays cover top-right; edit icon aligns with title's top and cover's right edge. iPhone omits edit icons. |
| UI-05 | Author page uses one row per author, avatar/name left, several works' thumbnails aligned right. Series/history/downloads use library grids. |
| UI-06 | Mac settings have sidebar submenus, not another horizontal navbar. |
| IOS-01 | iPhone is for browsing/reading, personal state and download management only. No source-file import, move/rename/reorg/commit; no author/comic/chapter/tag editing; no translation administration. |

[Current implementation status](implementation-status.md) is tracked separately; an accepted requirement is not automatically implemented.
