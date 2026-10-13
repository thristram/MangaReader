# API contract — v1

The implemented contract is [OpenAPI 3.1](../packages/api-contract/openapi.json). Generate it with `npm run contract:generate` after changing server request validation. This document explains semantics that JSON Schema cannot express. The API is JSON metadata only, not a NAS/media proxy.

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
