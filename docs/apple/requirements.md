# Apple requirements

Native Apple clients implement storage/read/UI requirements in the [overall baseline](../requirements.md). Mac is the library manager and commit executor; iPhone is the reader/offline downloader. Both must use ASWeb public-client PKCE login and account-isolated metadata/state.

P0 completion requires local/SMB operations, safe reviewed file plans, synchronized tags/text/personal state/progress, content fallbacks, full native reader gestures, all-page thumbnails, download groups and the specified Apple Music author/settings/collection layouts. iPhone must never expose source-file or metadata management controls.

English interface is the initial default; Chinese content preference is independent. Preserve title/description locales without duplicating media. NSFW hiding must apply to every screen and the continue-reading accessory. See [UI spec](ui-spec.md), [Apple spec](spec.md) and [current implementation status](../implementation-status.md).
