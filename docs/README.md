# Documentation

Baseline: 2026-10-13. These documents preserve the latest decisions from the design conversation. Requirements describe the intended product; [implementation status](implementation-status.md) describes what this first milestone actually does.

| Document | Contents |
| --- | --- |
| [Requirements](requirements.md) | P0/P1 scope, platform boundaries, requirements IDs and acceptance criteria |
| [Specification](spec.md) | Data model, language/visibility rules, sync, import, file commits and UI behavior |
| [API contract](api-contract.md) | Current endpoints, scopes, optimistic concurrency, errors and examples |
| [Machine contract](../packages/api-contract/openapi.json) | OpenAPI 3.1, generated from server request schemas |
| [Architecture decisions](adr/README.md) | Monorepo, control/data separation, auth, locales, sync, native UI and file safety |
| [Data migration](data-migration.md) | Existing folders, schema upgrades, backup and file-journal recovery |
| [Apple docs](apple/README.md) | Xcode setup, Mac / iPhone usage, storage, credentials and native UI |
| [Server docs](server/README.md) | Node/Vercel/Mongo setup, operations and auth registration |
| [UI specification](apple/ui-spec.md) | Every planned page and popup, including platform restrictions |
| [Mock](mock/README.md) | Preserved editable design and offline standalone preview |

Change requirements/spec and implementation status together when behavior changes. Record an ADR when a durable architecture decision changes. The mock is a visual reference and may contain screens that are not implemented yet.
