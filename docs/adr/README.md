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

All accepted on 2026-10-13. An ADR can accept the target design while noting the first milestone's narrower implementation. Changes should supersede an ADR explicitly rather than silently contradict it.
