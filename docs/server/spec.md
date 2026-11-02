# Server specification

Entry points: `src/index.ts` (Vercel Express export) and `src/dev.ts` (local HTTP listener). Authentication is built once from environment, fails closed on missing/insecure issuer configuration, and delegates cryptographic verification to Better Auth's OAuth resource helper.

`src/create-app.ts` contains the injectable app factory; `src/index.ts` is the only reserved Express deployment entrypoint. Do not name the factory `src/app.ts`: Vercel may select it instead of the default-exporting bootstrap.

`createApp` accepts a repository factory and token verifier to make isolation/security tests deterministic. Production wires only `MongoRepository` and real bearer verification. There is no environment switch bypassing authorization.

Collections: `entities`, `states`, `schema_migrations`. Each metadata/state operation uses compound account identity and public ID. Creation relies on required unique compound indexes; updates/deletions compare the expected revision. Deletion stores tombstones and refuses visible references. Mongo pool maximum 10; failed initial connections clear the cached promise for retry. Secrets stay in environment, never response bodies or logs.

Legacy `/v1/sync` remains compatible. Current clients use `/v1/sync/manifest`
(projected owner/id/revision/deleted, conditional ETag) and `/v1/sync/records`
(explicit ID batches, compact path transport, 3-MB response budget with deferrals).
No in-process cursor can omit another instance's write. Reads are eventually
consistent and revision-merged; this is not a transactional change log.

Native PATCHes are schema/reference/CAS validated and return a small receipt.
Mongo uses small atomic operators where their semantics match RFC 6902, otherwise
safe replacement. Detail, state, paginated list and reference existence queries
avoid full library reads. Fetch only visibility dependencies. Compress responses
larger than 4 KB at level 1; retain no-store and owner-scoped authorization.
Transaction-backed multi-document management/idempotency remains future work.

Canonical shapes/limits: [OpenAPI](../../packages/api-contract/openapi.json), generated from `src/domain.ts`. API semantics: [contract](../api-contract.md). Migration/operation details: [README](README.md).


### Novel metadata limits

Original/localized description limit is 500,000 UTF-16 code units per field.
Validated metadata is bounded to 2.8 MB UTF-8 JSON so selective-sync records remain
retrievable; HTTP JSON bodies accept up to 4 MB. Description-limit responses expose
an actionable message. Existing PATCH/PUT/GET/sync paths and owner/CAS checks apply;
Ollama inference and text-job state stay on the client. No schema migration is needed.
