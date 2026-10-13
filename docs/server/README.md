# Server setup and usage

The server is a stateless Express 5 / TypeScript app running on Node.js 22.16+. MongoDB is canonical; pool connections are reused across warm Vercel invocations. `src/index.ts` default-exports the Express app; `src/dev.ts` adds a local listener.

## Local setup

From repository root:

```sh
npm ci
cp apps/server/.env.example apps/server/.env
```

Fill `MONGODB_URI`, `MONGODB_DATABASE`, `AUTH_ISSUER`, `AUTH_JWKS_URL`, `MANGA_API_AUDIENCE`. No secrets are committed. Git ignores real `.env*` / `*.env` files, Vercel local state and private signing material; only sanitized `*.env.example` files are tracked. Copy the sample locally and enter credentials there or in Vercel Environment Variables. Native apps must use the same canonical issuer/API resource. Optional introspection client values are confidential **API-server** credentials, not Mac/iPhone credentials.

```sh
npm run db:migrate                 # describes v1 indexes; no database connection/write
npm run db:migrate -- --apply      # applies idempotent v1 indexes after backup
npm run dev
```

The migration creates compound unique `(ownerId,id)` indexes for entities and states and an account/kind listing index. These indexes are mandatory for safe creation/CAS. Production library routes return 503 until the v1 migration marker is present. `MONGODB_DATABASE` separates this service from the auth database. No auth database migration is executed by this repository.

`GET /health` is public liveness. Every `/v1` request needs a real Manga audience access token. Production has no fake tokens or memory repository. The test suite uses injected dependencies only.

## Vercel setup

- Import this monorepo; choose Root Directory **`apps/server`**.
- Use Vercel's native Express detection (default export in `src/index.ts`). No Edge runtime or hand-written legacy function wrapper.
- Set server environment values for Preview/Production. Build/install respects the root workspace lockfile. `npm run build` validates TypeScript; Express detection provides runtime packaging.
- Use a stable production API resource; rotating preview URLs need not change the token audience. Configure issuer's per-client allowed resources and scopes.
- Mongo connection must be reachable from Vercel with TLS/auth appropriate to the deployment. NAS credentials and comic files never enter Vercel.
- Auth discovery/JWKS and the auth service's own production migration/clients must be ready before testing native sign-in.

No deployment was provisioned automatically in this milestone. Replace sample values first.

## Development and validation

```sh
npm run typecheck
npm run build
npm test
npm run contract:generate
```

`npm test` covers tenant CRUD/reference/state/snapshot isolation, management permissions, stale revisions, tombstones, NSFW inheritance, text/media separation and real signed-token verification (wrong signature/issuer/audience/expiry). To run the Mongo integration test, use a dedicated temporary Mongo server and set `MONGODB_TEST_URI`; the test creates a random `mangareader_test_*` database and drops **only that test database**.

```sh
MONGODB_TEST_URI=mongodb://127.0.0.1:27383 npm test
```

## Operations and migrations

Back up before migration; [shared migration guide](../data-migration.md) covers steps and rollback. Index migration defaults to dry run. Do not drop owner indexes or globally deduplicate IDs without including ownerId.

API responses use `Cache-Control: no-store`. Error logs intentionally avoid token/credential/request-body dumps. Monitor status codes, database connection failures and revision conflicts. The bootstrap snapshot is limited to 10,000 entities/states; transactional incremental sync, idempotent mutation receipts, rate limits and durable file-plan metadata remain release work. No in-memory global sync cursor is used in a serverless environment.

See [server specification](spec.md), [requirements](requirements.md), [auth integration](auth-integration.md) and [API contract](../api-contract.md).

References: [Vercel Express](https://vercel.com/docs/frameworks/backend/express), [Better Auth OAuth Provider](https://better-auth.com/docs/plugins/oauth-provider), [MongoDB Node driver](https://www.mongodb.com/docs/drivers/node/current/).
