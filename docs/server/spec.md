# Server specification

Entry points: `src/index.ts` (Vercel Express export) and `src/dev.ts` (local HTTP listener). Authentication is built once from environment, fails closed on missing/insecure issuer configuration, and delegates cryptographic verification to Better Auth's OAuth resource helper.

`src/create-app.ts` contains the injectable app factory; `src/index.ts` is the only reserved Express deployment entrypoint. Do not name the factory `src/app.ts`: Vercel may select it instead of the default-exporting bootstrap.

`createApp` accepts a repository factory and token verifier to make isolation/security tests deterministic. Production wires only `MongoRepository` and real bearer verification. There is no environment switch bypassing authorization.

Collections: `entities`, `states`, `schema_migrations`. Each metadata/state operation uses compound account identity and public ID. Creation relies on required unique compound indexes; updates/deletions compare the expected revision. Deletion stores tombstones and refuses visible references. Mongo pool maximum 10; failed initial connections clear the cached promise for retry. Secrets stay in environment, never response bodies or logs.

The v1 synchronization endpoint reads the complete account metadata and states separately. It is bounded, eventually consistent and includes hidden/tombstoned metadata. It is deliberately not presented as a resumable incremental change stream. The next milestone must add a transaction-backed account sequence plus durable idempotency receipts and client outboxes; it must also make reference create/delete checks atomic across documents.

Canonical shapes/limits: [OpenAPI](../../packages/api-contract/openapi.json), generated from `src/domain.ts`. API semantics: [contract](../api-contract.md). Migration/operation details: [README](README.md).
