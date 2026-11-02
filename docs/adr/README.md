# Architecture decision records

| ADR | Decision |
| --- | --- |
| [0001](0001-monorepo.md) | Native clients and Node service in a monorepo; auth separate |
| [0002](0002-control-data-planes.md) | Metadata control plane separate from comic storage |
| [0003](0003-native-oauth.md) | ASWeb public clients with PKCE, separate API audience and account scope |
| [0004](0004-text-and-media-locales.md) | Text localizations independent from media versions |
| [0005](0005-sync-revisions.md) | Mongo canonical metadata, revisioned writes and staged sync evolution |
| [0006](0006-native-ui-and-reuse.md) | AppKit/UIKit, OS 26 system chrome and reused media/SMB frameworks |
| [0007](0007-file-commit.md) | Explicit, journaled file commits separate from metadata saves |
| [0008](0008-build-config-and-welcome.md) | Project service configuration and full-window verified-account welcome gate |
| [0009](0009-swiftui-screens.md) | SwiftUI screens on both platforms; native lifecycle/media adapters retained |
| [0010](0010-import-source-grants.md) | Capture source grants at drop/picker callbacks and retain them through queued import retry |
| [0011](0011-iphone-native-reader.md) | UIKit iPhone paging, complete-page minimum zoom and edge-to-edge media |
| [0012](0012-background-media-loading.md) | Indexed collections, bounded background media work and read-only SMB Unicode resolution |
| [0013](0013-mac-page-batch-edit.md) | AppKit page multi-selection and staged translation/delete commits through existing file journals |

See each ADR for its acceptance date. An ADR can accept the target design while noting the first milestone's narrower implementation. Changes should supersede an ADR explicitly rather than silently contradict it.
- [0014: Journaled media-folder cleanup and image additions](0014-journaled-media-folder-cleanup.md)
- [0015: Local page image translation queue](0015-local-page-image-translation-queue.md)
- [0016: Import shared-source reference index](0016-import-source-reference-index.md)

- [0017: Same-volume organization without media-byte transfers](0017-same-volume-organization.md)

- [0018: Demand-driven sync and small mutations](0018-demand-driven-sync-and-small-mutations.md)
- [0019: Long descriptions, lazy text and local translation jobs](0019-long-descriptions-and-text-jobs.md)
