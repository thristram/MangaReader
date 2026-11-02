# Server requirements

This component owns ACC-02, ARC-01/02, metadata persistence and the server side of SYNC-01 in the [product baseline](../requirements.md).

P0 acceptance: verified account-scoped CRUD/search/reference joins, endpoint scopes, persistent Mongo revisions/tombstones, conflict-safe writes, language/media separation, NSFW visibility and reliable automatic sync. Never accept client-supplied owner IDs, native client secrets, SMB passwords, comic byte uploads, server-side file moves or private Ollama calls.

The current implementation adds owner manifests/selective record retrieval, scoped paginated queries, small metadata PATCHes and a native reading-state outbox. Transactional multi-document management, mutation-id idempotency, durable metadata edit outboxes and a transaction-backed change stream remain pending. Read [status](../implementation-status.md), [contract](../api-contract.md) and [server spec](spec.md) together.


Long-description metadata: original/localized fields accept up to 500,000 UTF-16
code units, with a 2.8-MB validated metadata / 4-MB HTTP body bound. Save errors
identify description/document limits. Ollama text translation remains client-side
and publishes only a complete field through the existing owner/revision API.
