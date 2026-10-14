# Implementation status — SwiftUI presentation milestone

Updated: 2026-10-14. This is a working native/server foundation, **not a complete P0 release**. Accepted product/UI requirements are preserved in [requirements](requirements.md) and [UI spec](apple/ui-spec.md); the mock includes more functionality than the current applications.

## Implemented in source

| Area | Current behavior |
| --- | --- |
| Repository/docs | Monorepo, shared Swift package, two Xcode app targets, Node workspace, overall + Apple/server requirements/spec/README, ADRs, migration/recovery guide, OpenAPI and editable/exportable mock |
| Default language | English app strings; Chinese content preference is separately configurable; field-level text and preferred/original/available media fallback |
| API/account scope | Better Auth bearer helper, issuer/audience/expiry/signature validation, endpoint scopes, account-derived Mongo ownership, owned reference/hierarchy validation, strict request bodies |
| Persistence | Mongo entities/state, unique owner indexes/migration, per-document revision compare-and-swap, metadata tombstones, NSFW inheritance/filtering |
| Native auth | ASWeb public-client PKCE/state/nonce, Ed25519 ID-token validation, `/me` account confirmation, Keychain credentials, serialized refresh and sign-out generation checks |
| Sync | Owner-isolated snapshot/cache, automatic 30-second refresh while app runs, explicit refresh and iPhone foreground sync; writes require connection |
| Mac library | Native sidebar/unified toolbar, shared adaptive cover grids, search/sort/unread/tag filters, simple chapter detail, horizontal author rows, series/tag detail, history/favorites/stars/saved pages |
| Mac import | Whole-page drag/drop/select, recursive/natural-sorted images, PDF/MP4/WebM candidates, sequential candidate processing, author/comic/series creation, description/source IDs and tag add/create |
| File commit | Explicit primary Add & Move, same-volume rename only, root/traversal/symlink/collision checks, prepared recovery payload before movement and commit phases; add-only leaves originals untouched |
| Mac editing | Revision-aware original/localized title/description/tags/NSFW edit sheets, searchable removable tag chips and nested create sheets; local Ollama text translation to preferred locale immediately saved, no extra popup |
| Mac reading | SwiftUI reader, height-filling native image/zoom, PDFKit, AVKit, canonical media-language fallback, thumbnails/overview/adaptive description, page marks and active-time progress; local/Finder-mounted SMB root bookmarks |
| iPhone UI | UIKit scenes hosting SwiftUI, large-title NavigationStack/search, floating native TabView/minimization, continue-reading accessory, grids/browse filters, reading/connection settings; no metadata/source-file management |
| iPhone SMB/offline | Dynamic AMSMB2 encrypted share connection, per-owner/root Keychain NAS config, private foreground sequential chapter staging, completed manifests, work/series/author group downloads |
| iPhone reader | Native horizontal page-style TabView for image/PDF, image pinch/double-tap zoom, system video playback/error state, media-language menu, page marks/progress |
| New pages | Real active-time statistics, completed-download grid/cancel/retry/remove, storage bindings, settings submenus, metadata export, import commit review and journal reconciliation |
| Translation/page order | Import original/translated page-matching sheet; explicit null mapping falls back to original; drag-order sheet updates mapping without physical rename |

## Not yet a completed feature

- Full deferred bulk rename/reorganization planner, changed-file/conflict alternatives, cross-volume verified copy/delete, direct SMB file-management and idempotent import retry. Current Pending Organization reviews import journals and reconciles metadata only after a verified completed move.
- Automatic relocation of existing single-language folders when a second media language arrives. Translation import currently preserves source locations.
- Manual/separate cover files (`0.ext`) and physical filename renumbering. Covers derive from the naturally lowest source filename; PDF/video use system thumbnails.
- Finder color-tag projection, tag colors/merge, and robust source ID/URL normalization. The current picker supports search/select/create/remove, not tag merge.
- Durable offline metadata/state outbox, reconnect merge/conflict UI, incremental/transactional sync and fully offline relaunch; multi-document reference transactions.
- Background/resumable/verified downloads, on-demand page/range reading, a persistent job queue/pause, content hashes and quota policy. Both apps currently stage whole preferred chapters through foreground transfers.
- Configurable fit modes beyond default height filling, detailed historical reading sessions/page totals, distribution assets/signing, complete VoiceOver/Dynamic Type/Reduce Motion and physical-device gesture acceptance.
- P1 Tailscale setup/reachability and manga-image-translator full-media worker.

## Verified vs configuration-dependent

Verification results are recorded in [verification](verification.md). Local tests cover real Mongo persistence/CAS plus account/scope isolation and token security; shared Swift tests cover path safety, sorting, file journaling and locale/identity rules. Both native targets are built without distribution signing.

Live ASWeb sign-in/refresh against production thristram-auth, real NAS interoperability, actual device gesture/layout testing and local Ollama model output require configuration-dependent acceptance. Native deployment URLs/client ID and hosted resource/grant policy were configured and live iPhone-on-Mac sign-in verified in the preceding auth fix. The SwiftUI UI review uses synthetic data and does not certify a new live login or NAS operation. Signed-out UI is a full-window native welcome page; only verified identity reveals the library. No production deployment/migration or NAS file operation is claimed by the initial milestone; follow-up verification is recorded separately.

## Next acceptance order

1. Exercise the configured production resource/client with account isolation, refresh and switching against a real library/NAS.
2. Complete safe file-plan/recovery and media alignment/cover/reorder flows before using bulk management on original collections.
3. Add durable offline sync and download jobs, then finish approved UI details/reader gestures/statistics.
4. Complete release validation and distribution prerequisites; implement P1 workers/network reachability separately.
