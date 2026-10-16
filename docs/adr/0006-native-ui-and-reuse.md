# ADR 0006 — Native Apple UI and existing storage/media frameworks

Status: Accepted · 2026-10-13

## Context

Apple Music navigation/chrome and Photos/Preview reading gestures are core requirements. iPhone explicitly requires UIKit. Reimplementing SMB/image/PDF/video infrastructure would add avoidable complexity.

## Decision

Use AppKit on Mac, UIKit on iPhone, shared Swift core and OS 26+ for actual Liquid Glass system bars. UIKit navigation/tab controllers and UITabAccessory own their layout/transitions; no embedded mock/web UI. Use AuthenticationServices, PDFKit, AVKit/AVFoundation, native image decoding and QuickLookThumbnailing. Use dynamic AMSMB2 4.0.3 for device SMB; Finder mounting also supports Mac storage.

## Consequences

Minimum deployment version is 26; older OS styling is not an initial target. Dependency/codec compatibility must be tested on actual NAS/devices; WebM ingestion does not imply all codecs decode. AMSMB2 wraps LGPL libsmb2; retain notices/source and review distribution obligations before App Store release. The P1 manga-image-translator worker's licensing is evaluated separately.

References: [AMSMB2](https://github.com/amosavian/AMSMB2), [Apple UIKit](https://developer.apple.com/documentation/uikit), [Apple PDFKit](https://developer.apple.com/documentation/pdfkit).

## SMB diagnostics and network privacy, 2026-10-14

Keep AMSMB2 4.0.3 as a local source dependency pinned to its upstream commit,
with patches preserving error details before context destruction and preventing
further socket I/O after a protocol callback closes the connection. Preserve
its dynamic framework embedding and licenses. This restores actionable server
errors without replacing SMB negotiation/authentication/encryption code. Use
Network.framework for a credential-free TCP readiness check before a host's first
SMB connection so local-network authorization can finish before the raw-socket
SMB implementation starts. iPhone only validates an existing Mac-initialized
library. Encryption remains required. See [verification](../apple/smb-connection-diagnostics-2026-10-14.md).
