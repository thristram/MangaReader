# Server requirements

This component owns ACC-02, ARC-01/02, metadata persistence and the server side of SYNC-01 in the [product baseline](../requirements.md).

P0 acceptance: verified account-scoped CRUD/search/reference joins, endpoint scopes, persistent Mongo revisions/tombstones, conflict-safe writes, language/media separation, NSFW visibility and reliable automatic sync. Never accept client-supplied owner IDs, native client secrets, SMB passwords, comic byte uploads, server-side file moves or private Ollama calls.

The first milestone implements request/auth/tenant isolation and revisioned snapshot APIs. Transactional multi-document management, mutation-id idempotency and incremental/outbox sync remain pending. Read [status](../implementation-status.md), [contract](../api-contract.md) and [server spec](spec.md) together.
