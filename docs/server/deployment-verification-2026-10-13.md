# Deployment verification — 2026-10-13

Targets: local `http://127.0.0.1:3010` and production `https://manga-api.thenoirclub.com`.

## Observed results

| Boundary | Result | Evidence |
| --- | --- | --- |
| Local service liveness | Pass | `/health` returns 200 with `{"status":"ok","apiVersion":1}` over IPv4 and localhost IPv6. |
| Local unauthenticated API | Pass | `/v1/me` returns 401 `invalid_token` / `Sign in required`. This confirms enforcement, not successful authenticated access. |
| Production invocation | Fail | `/health`, `/v1/me`, `/v1/entities`, `/v1/sync` return 500 `FUNCTION_INVOCATION_FAILED`. |
| Production error diagnosis | Confirmed | Vercel runtime logs identify `/var/task/apps/server/src/app.js`: `Invalid export found … The default export must be a function or server.` |
| Local configured MongoDB connection | Pass | Real driver connect, ping, collection listing and migration/index queries succeed using the ignored `apps/server/.env`; no URI or credentials printed. |
| MongoDB readiness | Fail | Selected database `mangareader` has no `v1` marker or required unique `(ownerId,id)` indexes; entities/states counts both zero. |
| Auth discovery/JWKS | Pass | Both return 200; discovery issuer matches local configuration; JWKS contains an EdDSA key. |
| Production configuration metadata | Present | Mongo URI/database, issuer, JWKS and audience keys exist for production. Secret values were not decrypted/retrieved. This does not prove production DB connectivity. |

## Local correction prepared

Vercel recognizes `src/app.ts` as an Express entrypoint before `src/index.ts`. The former was an injectable factory rather than the actual default-exported service. Rename it to `src/create-app.ts` and update imports, leaving `src/index.ts` as the sole recognized Express entrypoint.

A regression test checks that only this entrypoint exists, that it exports a callable app, and that its real bootstrap serves `/health` and protects `/v1/me`. Typecheck/build pass; 9 backend tests pass. The isolated Mongo write integration test is skipped in this run: verification against the configured database is read-only, not a production test-data write.

## Remaining activation / verification

1. Commit/push the entrypoint correction and deploy it to the intended production project; then repeat `/health` and unauthorized-route checks.
2. Back up as appropriate and apply v1 migration to the intended metadata database: `npm run db:migrate -- --apply`. This creates indexes and the v1 marker; no comic files are involved. Dry-run was inspected, but the real database was not modified during verification.
3. Complete real hosted OAuth sign-in and verify authenticated `/v1/me`, `/v1/entities`, `/v1/states` and `/v1/sync` against local and production. No valid user access token was supplied for these checks, and no auth bypass is used.
4. Verify production Mongo connectivity through an authenticated library request. Direct local credential-based Mongo connectivity does not prove Vercel has the same reachable/valid credential configuration.

No production deployment, environment update, database migration, user metadata mutation or credential change was performed by this verification. Current production is still failing until the correction is deployed.


## Follow-up — root migration flag forwarding

The documented root command initially forwarded `--apply` to npm's workspace runner as an npm option rather than to the migration program. The root script now ends with its own `--` separator. The user's intended `npm run db:migrate -- --apply` reaches `src/migrate.ts --apply` correctly.

The corrected command was applied to the configured `mangareader` database after the user explicitly attempted the apply command. It returned `Schema v1 applied.` A direct read-only follow-up confirmed the v1 marker and both unique `(ownerId,id)` indexes. Entity/state counts remain zero. No comic/user records were inserted or deleted; no credentials were printed or committed. Dry-run behavior was also checked with an intentionally invalid URI and returned without attempting a connection.

This completes metadata-database initialization using the local configuration. It does not establish production-runtime DB connectivity or authenticated API CRUD; those still require the corrected deployment and a real account login.
