# API contract — v1

The implemented contract is [OpenAPI 3.1](../packages/api-contract/openapi.json). Generate it with `npm run contract:generate` after changing server request validation. This document explains semantics that JSON Schema cannot express. The API is JSON metadata only, not a NAS/media proxy.

Mac page batch editing uses the existing revision-checked chapter update. Splitting
a translation changes image `relativePaths`, `pageCount` and `pageAlignment` and
adds a new media ID; it does not create another chapter or duplicate localized text.
Deleting a version removes its media entry instead of sending a zero-page version;
an empty chapter media list is allowed. Physical move/Recycle operations remain
device-side and journaled. No endpoint/schema migration is added. Existing personal
state continues to address canonical page positions. See [batch edit semantics](apple/all-pages-batch-edit-2026-10-17.md).

## Authentication and account identity

Send `Authorization: Bearer <access_token>`. The server checks signature/JWKS, configured canonical issuer, permanent Manga API audience, expiry, subject and operation scope. The native ID token's audience is the client ID; it must never be sent as the API bearer token.

The server derives ownerId from `SHA256(issuer + NUL + subject)`. Every persistence lookup and reference validation uses that owner. Request schemas reject `ownerId`, arbitrary extra properties and unsafe storage paths. A foreign account's entity behaves as unavailable (404) rather than exposing its existence.

| Scope | Capability |
| --- | --- |
| `manga:read` | Account info, metadata lists/detail, snapshot, personal-state reads |
| `manga:state:write` | Favorite/star/progress state |
| `manga:manage` | Create/edit/delete library metadata (Mac) |

iPhone requests read + state scopes. Mac requests all three. Both may request OIDC `openid profile email offline_access` at login; those do not grant API management by themselves.

## Endpoints

| Method | Path | Scope | Behavior |
| --- | --- | --- | --- |
| GET | `/health` | public | Liveness only; not a DB/auth readiness probe |
| GET | `/v1/me` | read | Verified ownerId, issuer, subject, scopes |
| GET | `/v1/entities` | read | Filter by kind, title query `q`, workId or authorId; NSFW hidden by default |
| GET | `/v1/entities/:id` | read | Account-owned visible entity |
| POST | `/v1/entities` | manage | Create from MetadataInput; server UUID/revision=1; 201 |
| PUT | `/v1/entities/:id` | manage | Replace metadata; immutable entity kind; current revision required |
| DELETE | `/v1/entities/:id` | manage | Tombstone; 204; refuses referenced parents/tags/roots; no physical file deletion |
| GET | `/v1/states` | read | Personal states referencing visible, live entities |
| PUT | `/v1/states` | state:write | Replace entity/page state; current revision required |
| GET | `/v1/sync` | read | Complete account snapshot including tombstones and private NSFW metadata |

For entity/state reads, `includeNSFW=true` explicitly reveals NSFW. Snapshot always includes it for inheritance/sync; clients filter before rendering. A maximum of 10,000 entities/states is supported by this bootstrap API; larger accounts receive 503. Library routes also return `schema_not_ready` (503) before the database migration has been applied. There is no silent truncated-success response or incremental cursor.

## Writes and conflicts

`If-Match: 3` means the object must still have revision 3. This v1 contract uses an **unquoted decimal revision**, not a quoted HTTP ETag. Personal state creation uses `If-Match: 0`; metadata creation is POST without If-Match. Server increments revision after successful compare-and-swap. Missing/invalid revision: 428. Stale revision: 409; reload and intentionally merge, never retry the old replacement blindly.

PUT is a complete replacement of editable metadata; omitted fields take request-schema defaults, so send all values you want to preserve. Client `LibraryEntity.input` strips response-only fields. References (author/series/work/tag/root) must be live and owned by the same account. Chapters require an author. Work and chapter author relationships must be consistent; multi-document reference changes still require transaction work before release.

Body limit: 2 MB. Title ≤500 chars, description ≤30,000 chars, ≤100 tags, ≤50 source links, ≤30 media variants, ≤10,000 paths per variant. No arbitrary server execution/file paths are accepted.

A single metadata write is atomic; an import's multiple create/move/update steps are **not** an atomic API transaction in this milestone. Durable mutation-id idempotency and file-plan endpoints are pending. No advertised `/jobs`, `/files`, media download or Ollama proxy endpoint exists yet.

## Examples

Create an author:

```http
POST /v1/entities
Authorization: Bearer <mac-access-token>
Content-Type: application/json

{"kind":"author","title":"Author A","originalLanguage":"ja"}
```

Create a chapter with an existing author/root:

```json
{
  "kind": "chapter",
  "title": "Chapter 1",
  "originalLanguage": "ja",
  "description": "Original description",
  "authorId": "<author UUID>",
  "localizations": {"zh": {"title": "第一章"}},
  "media": [{
    "id": "<media UUID>", "language": "ja", "kind": "images",
    "storageRootId": "<root UUID>",
    "relativePaths": ["Author A/Chapter 1/1.jpg", "Author A/Chapter 1/2.jpg"],
    "pageCount": 2
  }]
}
```

The Chinese title does not create Chinese images. Chinese description is absent, so original description displays. All paths are relative to a root authorized/bound by the native app, never absolute server paths.

State:

```http
PUT /v1/states
If-Match: 0
Authorization: Bearer <iphone-access-token>
Content-Type: application/json

{"entityId":"<chapter UUID>","favorite":true,"starred":false,"progress":{"mediaId":"<media UUID>","pageIndex":0,"completed":false,"activeSeconds":0}}
```

A page favorite instead supplies `pageIndex` at the top level and omits progress. Progress must refer to an existing media page; negative/out-of-bounds indexes fail.

Errors use `{"error":{"code":"conflict","message":"Reload current revision before editing"}}`. Validation errors may include `details`. 401 uses a Bearer challenge; 403 uses insufficient_scope. Unexpected server errors do not expose tokens, Mongo credentials or stack traces.

## Contract compatibility

Additive optional response fields are compatible. Rename/removal or semantics changes require a new API/schema version, native decoder migration and tests. Keep text localization and media version identity separate in all migrations. The generated schema covers request/response shapes; relationship/ownership rules require integration tests.

SwiftUI uses the existing schema v1 `pageAlignment` array as canonical-page → source-page mapping. A null/missing/out-of-range mapping uses original media; localized title/description fields remain separate. Reading progress and page marks store canonical positions. This UI rewrite adds no endpoint or database migration.

Mac whole-media removal updates the chapter's existing `media` array; removing the final version sends `media: []` while retaining chapter metadata. Image additions use the same revision-checked update with appended physical paths/page counts/alignment. Chapter DELETE remains unchanged. Directory cleanup and source-file bookmarks are local file-journal details and are never API fields. No data migration is required.

### Optional Ollama text translation service

Apple clients call the configured native Ollama service directly: `GET /api/tags` for installed model names and `POST /api/chat` with `model`, `stream: false`, `format: "json"`, and system/user messages. The custom system prompt is retained with an appended JSON output requirement; the model response's `message.content` must decode as localized `title`/`description`. Entirely blank source text is rejected before HTTP. HTTP/JSON `error` details stop the operation before metadata updates, including explicit missing-model 404 errors. No automatic download, model substitution or inference retry occurs. Text is stored through the existing account/revision-checked entity update, independently of media translations. Service URL/model/prompt remain device-local and no thristram-auth token is sent to Ollama. See [setup and diagnostics](apple/ollama-text-translation-2026-10-30.md).

### Optional Mac image translation service

Mac calls the user-configured manga-image-translator directly: `GET <base>/openapi.json` for route compatibility, then the advertised `POST <base>/translate/with-form/image/stream` with multipart fields `image` (PNG) and `config` (upstream JSON). The standard stream disables the worker's web placeholder optimization. Each packet contains a status byte, four-byte big-endian length and payload; statuses 1/3/4 report progress/waiting, 2 is an error, and 0 must terminate with a readable rendered PNG. Services advertising only `/translate/with-form/image` retain raw-PNG support. Never use `/stream/web` or automatically retry another POST after a translation failure. A 1×1 placeholder for a larger source is rejected before caching/metadata/file commits; unfinished cached pages are checked too. This is a separate service and receives no thristram-auth token. Revision-checked chapter updates (small PATCH in current clients; legacy PUT remains supported) record each completed canonical slot; partial versions use explicit `null` alignment slots. Source media/text metadata remains independent. The MangaReader server's public API and MongoDB schema are unchanged. See the [client contract and existing-white-page recovery limits](apple/manga-image-translation-2026-10-18.md).

## Client organization update — 2026-10-22

No endpoint or payload schema changes. Chapter reassignment uses the existing revision-checked entity update and must send the selected comic's author/Series IDs. Filesystem identity journals remain client-local and are not server storage paths. See [ADR 0017](adr/0017-same-volume-organization.md).

## Selective sync and small mutations — 2026-11-01

The API URL/scopes remain v1; new clients negotiate a **schemaVersion 2 manifest**.
The legacy full snapshot and PUT remain for rolling upgrades. Deploy the server
first; old clients continue their previous polling behavior until updated.

| Method | Path | Scope | Behavior |
| --- | --- | --- | --- |
| GET | `/v1/sync/manifest` | read | Owner-scoped entity `{id,revision,deleted}` and state `{id,revision}` stamps; no descriptions/media paths; ETag and conditional 304 |
| POST | `/v1/sync/records` | read | Explicit `entities` / `states` ID arrays (each ≤100); only caller-owned matching records, including tombstones |
| PATCH | `/v1/entities/:id` | manage | RFC 6902 add/remove/replace/test on editable metadata, If-Match CAS, full resulting schema/reference checks; small receipt |
| GET | `/v1/states/:id` | read | One owned state, ID = `<entity UUID>:entity` or `<entity UUID>:<pageIndex>`; 404 if absent/deleted entity |

Manifest example:

```json
{"schemaVersion":2,"entities":[{"id":"<UUID>","revision":7,"deleted":false}],"states":[{"id":"<UUID>:entity","revision":3}]}
```

Send `If-None-Match: "<manifest hash>"` on later checks. The ETag incorporates the
verified owner and canonically ordered stamps. Equal manifests return 304 with no
body. Auth/scope checks still run. Responses remain **no-store**; no public/CDN cache
is authorized. This is latest-state reconciliation rather than a timestamp cursor
or transaction-backed event stream; no write is considered synchronized solely
because its wall-clock timestamp precedes a request. A later manifest notices
writes committed during an earlier batch. The current 10,000-per-collection limit
still fails explicitly with 503.

Record fetch request:

```json
{"entities":["<changed chapter UUID>"],"states":[]}
```

It returns `{schemaVersion:1,entities:[...],states:[...]}`. Media transport replaces
`relativePaths` with `pathDirectory` plus `pathFiles`; append `"/"` only when the
directory is nonempty to reconstruct existing root-relative paths. A common prefix
is selected per media version; nested filenames keep their relative subdirectories.
`pageCount` and `pageAlignment` are unchanged. Public records exclude internal
Mongo `_id` and ownerId. Storage/cache/journal documents retain full relative paths.

Responses budget 3,000,000 JSON bytes before transport compression. Remaining IDs
are returned as optional `remainingEntities`/`remainingStates`; fetch those again
before publishing the completed synchronization. A record individually exceeding
the limit is refused with 413. Missing/foreign IDs return no record and reveal no
ownership. Clients publish no partial catalog on a failed batch and merge by
revision, preserving newer local receipts and account/deletion guards.

Small update example (both `application/json` and `application/json-patch+json`
are accepted):

```http
PATCH /v1/entities/<chapter UUID>
If-Match: 7
Content-Type: application/json
Authorization: Bearer <mac-access-token>

[{"op":"add","path":"/media/1/relativePaths/-","value":"Author/Comic/Chapter/zh/008.png"},{"op":"replace","path":"/media/1/pageCount","value":8},{"op":"replace","path":"/media/1/pageAlignment/7","value":7}]
```

Receipt: `{id,revision:8,updatedAt,title}`. `title` is the canonical normalized title;
other metadata is the requested revision-checked result. Do not treat the receipt
as an idempotency token: after an ambiguous response loss, reconcile the current
revision before retrying. Identity, owner, entity kind, prototype mutation and
move/copy operations are forbidden. Empty patches are permitted but clients should
avoid unnecessary saves. Invalid operations fail before persistence; no media
files are touched server-side. Common sparse appends are small atomic Mongo updates;
array-removal or overlapping cases preserve safe replacement behavior.

Entity/state **list** reads now accept `limit` (1–250, default 100) and an exclusive
`after` ID cursor, returning optional `nextCursor`. State lists also accept
`entityId`; entity lists retain kind/work/author/literal-title query filters. Cursor
advancement uses the scanned page, before NSFW filtering, so hidden entries cannot
trap pagination. Detail reads fetch only the requested record plus visibility
parents/tags; lists fetch only a bounded page and its dependencies.

Reading state writes retain their small PUT contract. On 409, new apps fetch only
the target state and deliberately merge progress/favorite/star intent. Pending
reading intentions persist device-side with a changed-field mask and retry with
backoff. Merge only intended fields into the latest state before sending, even
after successful synchronization without a 409; progress must preserve remotely
changed favorite/star flags. This does not add
an offline metadata-edit API. Responses larger than 4 KB support gzip level 1;
compression does not replace owner isolation or selective retrieval.
