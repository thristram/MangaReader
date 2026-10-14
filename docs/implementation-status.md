# Implementation status — first development milestone

Baseline: 2026-10-13. This is a working native/server foundation, **not a complete P0 release**. Accepted product/UI requirements are preserved in [requirements](requirements.md) and [UI spec](apple/ui-spec.md); the mock includes more functionality than the current applications.

## Implemented in source

| Area | Current behavior |
| --- | --- |
| Repository/docs | Monorepo, shared Swift package, two Xcode app targets, Node workspace, overall + Apple/server requirements/spec/README, ADRs, migration/recovery guide, OpenAPI and editable/exportable mock |
| Default language | English app strings; Chinese content preference is separately configurable; field-level text and preferred/original/available media fallback |
| API/account scope | Better Auth bearer helper, issuer/audience/expiry/signature validation, endpoint scopes, account-derived Mongo ownership, owned reference/hierarchy validation, strict request bodies |
| Persistence | Mongo entities/state, unique owner indexes/migration, per-document revision compare-and-swap, metadata tombstones, NSFW inheritance/filtering |
| Native auth | ASWeb public-client PKCE/state/nonce, Ed25519 ID-token validation, `/me` account confirmation, Keychain credentials, serialized refresh and sign-out generation checks |
| Sync | Owner-isolated snapshot/cache, automatic 30-second refresh while app runs, explicit refresh and iPhone foreground sync; writes require connection |
| Mac library | Native sidebar/unified toolbar, basic comic/chapter collections, search, comic chapter detail, author/series/tag browsing, basic history/favorites/stars filters |
| Mac import | Whole-sheet drag/drop/select, recursive/natural-sorted images, PDF/MP4/WebM candidates, sequential candidate processing, author/comic/series creation, description/source IDs and tag add/create |
| File commit | Explicit primary Add & Move, same-volume rename only, root/traversal/symlink/collision checks, prepared recovery payload before movement and commit phases; add-only leaves originals untouched |
| Mac editing | Title/description/tags/NSFW edit popup; local Ollama text translation to preferred locale immediately saved, no extra popup |
| Mac reading | Native page container, height-filling image/zoom, PDFKit, AVKit, page marks/progress and media-language switch; local/Finder-mounted SMB root bookmarks |
| iPhone UI | UIKit scenes, large-title nav/search, floating native tabs/minimization, continue-reading accessory, grids/browse filters, reading/connection settings; no metadata/source-file management |
| iPhone SMB/offline | Dynamic AMSMB2 encrypted share connection, per-owner/root Keychain NAS config, private foreground sequential chapter staging, completed manifests, work/series/author group downloads |
| iPhone reader | Native horizontal image/PDF page transitions, image pinch/double-tap zoom, system video playback, media-language menu, page marks/progress |

## Not yet a completed feature

- Full pending organization/preflight/recovery UI, bulk rename/reorganization, cross-volume verified copy/delete, direct SMB file-management operations and idempotent import retry.
- Actual media-translation import/alignment popup; automatic relocation of single-language media when a second version arrives; unmapped-image fallback.
- Manual/separate covers (`0.ext`), source page drag reordering/renumbering and all-page/thumbnail reading UI.
- Finder color-tag projection, full source-link normalization, removable/searchable token-chip tag editing, tag merge/management and manual text-localization editing.
- Full author-row-with-work-thumbnails layout and complete series/tag detail behavior; richer collection filters/sorting/accessibility/gesture polish.
- Text translate button on comic detail itself (currently edit popup only); Ollama connection test/cancellation UI.
- Entity-level personal mark UI polish and all saved-page collections. Reader controls currently expose page marks; API supports entity marks.
- Durable offline metadata/state outbox, reconnect merge/conflict UI, incremental/transactional sync and fully offline relaunch; multi-document reference transactions.
- Background/resumable/verified downloads, on-demand page/range reading, robust job queue/status/pause, local-download removal UI, changed-bytes validation and device quota policy. Current iPhone stages whole chosen chapter before opening it.
- Mac download queue: current Mac reads originals in place; its download affordance explains that offline jobs are pending.
- Active-reading statistics/time accounting (current progress activeSeconds remains zero); comprehensive history/session model.
- Fullscreen/fit mode chooser, thumbnail sidebar, adaptive description pane, RTL reading mode and robust zoom-vs-page gesture coordination.
- Full video codec/error-state coverage, PDF/video cover caching on iPhone, distribution icons/signing/accessibility QA and complete mobile visual parity with the approved mock.
- P1 Tailscale setup/reachability and manga-image-translator full-media worker.

## Verified vs configuration-dependent

Verification results are recorded in [verification](verification.md). Local tests cover real Mongo persistence/CAS plus account/scope isolation and token security; shared Swift tests cover path safety, sorting, file journaling and locale/identity rules. Both native targets are built without distribution signing.

Live ASWeb sign-in/refresh against production thristram-auth, real NAS interoperability, actual device gesture/layout testing and local Ollama model output require configuration-dependent acceptance. Native deployment URLs and the supplied public OAuth client ID are now configured in the project; hosted callback/grant/resource policy and successful account login still require verification. Signed-out UI is a full-window native welcome page; only verified identity reveals the library. No production deployment/migration or NAS file operation is claimed by the initial milestone; follow-up verification is recorded separately.

## Next acceptance order

1. Configure/register live API resource and both native clients; exercise account isolation, refresh and switching with a real library/NAS.
2. Complete safe file-plan/recovery and media alignment/cover/reorder flows before using bulk management on original collections.
3. Add durable offline sync and download jobs, then finish approved UI details/reader gestures/statistics.
4. Complete release validation and distribution prerequisites; implement P1 workers/network reachability separately.
