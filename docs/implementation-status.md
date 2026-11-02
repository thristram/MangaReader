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
| Sync | Owner manifests/304, selective bounded record batches, small PATCH receipts; event/idle-driven Mac refresh, active-only iPhone refresh; coalesced durable reading intentions and targeted state conflict reload |
| Mac library | Native sidebar/unified toolbar, shared adaptive cover grids, search/sort/unread/tag filters, simple chapter detail, horizontal author rows, series/tag detail, history/favorites/stars/saved pages |
| Mac import | Whole-page drag/drop/select, recursive/natural-sorted images, PDF/MP4/WebM candidates, sequential candidate processing, author/comic/series creation, description/source IDs and tag add/create |
| File commit | Explicit primary Add & Move, same-volume rename only, root/traversal/symlink/collision checks, prepared recovery payload before movement and commit phases; add-only leaves originals untouched |
| Mac editing | Revision-aware original/localized title/description/tags/NSFW edit sheets, searchable removable tag chips and nested create sheets; resumable chunked local Ollama text translation to preferred locale with progress, no confirmation popup |
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
- P1 Tailscale setup/reachability. External manga-image-translator model/GPU/provider setup and real translation-quality acceptance remain outside the Mac HTTP client implementation.

## Verified vs configuration-dependent

Verification results are recorded in [verification](verification.md). Local tests cover real Mongo persistence/CAS plus account/scope isolation and token security; shared Swift tests cover path safety, sorting, file journaling and locale/identity rules. Both native targets are built without distribution signing.

Live ASWeb sign-in/refresh against production thristram-auth, real NAS interoperability, actual device gesture/layout testing and local Ollama model output require configuration-dependent acceptance. Native deployment URLs/client ID and hosted resource/grant policy were configured and live iPhone-on-Mac sign-in verified in the preceding auth fix. The SwiftUI UI review uses synthetic data and does not certify a new live login or NAS operation. Signed-out UI is a full-window native welcome page; only verified identity reveals the library. No production deployment/migration or NAS file operation is claimed by the initial milestone; follow-up verification is recorded separately.

## Next acceptance order

1. Exercise the configured production resource/client with account isolation, refresh and switching against a real library/NAS.
2. Complete safe file-plan/recovery and media alignment/cover/reorder flows before using bulk management on original collections.
3. Add durable offline sync and download jobs, then finish approved UI details/reader gestures/statistics.
4. Complete release validation and distribution prerequisites; implement P1 workers/network reachability separately.

## Mac image translation (2026-10-18)

Implemented: native service/default-option settings and route test; Edit Chapter confirmation; owner-scoped persisted serialized image/PDF page jobs; progressive aligned media/file commits; cached preview; retry/restart and file-journal recovery; four organization sidebar children, file-queue remove/reverse-order/status, and background history reads. Native synthetic integration tests pass, and the local port-8000 image API passed an actual connection/schema check. Real model quality/provider readiness has not been validated by synthetic responses. See [setup and acceptance scope](apple/manga-image-translation-2026-10-18.md).

## Chapter reassignment and organization — 2026-10-22

Mac chapter reassignment resolves typed/exact selections, inherits destination comic parents and preserves file references. Translation imports, language correction, source-only organization, page splitting/recycling and image additions share batched planning and exclusive same-volume link/rename execution. Shared/cross-volume copies, older SHA journals, file recovery and sidecar/empty-folder preservation remain covered. See [usage, measured checks and limits](apple/chapter-reassignment-and-organization-2026-10-22.md). No server/database migration is needed.

## Author source links — 2026-10-22

Mac/iPhone share direct author source buttons in reader Info, comic detail and Authors rows. The info sheet also shows author name/description. Provider ID routing is shared and tested; no API/schema change is required. See [details](apple/author-source-links-2026-10-22.md).

2026-10-31: Mac Import & Identify now has New Chapter / Translation / Additional Pages segments, aligned input columns and standalone image support. Additional Pages and All Pages reuse the same file append/commit workflow. Chapter tiles expose a normal All Pages navigation destination and compact labeled action buttons. Mac/iPhone use a shared compact filter panel, located in the toolbar before search on Mac and at top-right navigation on iPhone. See the [Apple spec](apple/spec.md#import-modes-all-pages-navigation-and-unified-filters).


2026-10-31 commit-flow follow-up: common copy/path/shared-source optimizations now
cover translations, Additional Pages and language changes; deletion uses identity-
verified same-volume Recycle renames. Delete planning and pending history scans
avoid blocking/repeated full reads. Import labels are left of aligned textboxes.
Both native builds, 75 core tests and full Mac fixture regression passed. Local
benchmarks improve; the NAS fixture has a copy permission limitation and small-file
Recycle overhead, so NAS acceleration remains workload-dependent. See
[measurements and limits](verification.md#all-commit-paths-and-import-label-correction--2026-10-31)
and [journal compatibility](adr/0017-same-volume-organization.md).


2026-11-01 sync/traffic follow-up: see [ADR 0018](adr/0018-demand-driven-sync-and-small-mutations.md).
Legacy full snapshots remain only for old clients/rolling upgrades. Current clients
compare manifests, skip unchanged UI/cache work, fetch changed records and send small
metadata PATCHes. Query/index, batching, progress durability and backoff behavior
are specified in [the API extension](api-contract.md#selective-sync-and-small-mutations--2026-11-01).
Deployment rollout and Vercel quota recovery are separate operational steps.


## Long novel descriptions and text jobs (2026-11-02)

Server description limits now support bounded novel-length original/localized text.
The shared reader caches display segmentation off the UI actor and lays out lazily;
collections show excerpts. Local text jobs use chapter/paragraph/sentence chunks,
plain model output, global model-independent context/output settings, disk resume
and revision/source/translation guards. See [setup and recovery](apple/long-text-translation-2026-11-02.md).
This is app-runtime work, not a deployed server worker; live model quality and
physical-device long-novel performance remain separate acceptance checks.
