# Apple requirements

Native Apple clients implement storage/read/UI requirements in the [overall baseline](../requirements.md). Mac is the library manager and commit executor; iPhone is the reader/offline downloader. Both must use ASWeb public-client PKCE login and account-isolated metadata/state.

iPhone reading clarification, 2026-10-14: the media canvas fills the screen, while minimum/default image and PDF zoom shows the complete page without cropping. Native horizontal transitions follow the finger and cancel safely. System safe areas protect controls without adding a fixed band above the media. See [reader verification](iphone-reader-fit-and-paging-2026-10-14.md).

P0 completion requires local/SMB operations, safe reviewed file plans, synchronized tags/text/personal state/progress, content fallbacks, full native reader gestures, all-page thumbnails, download groups and the specified Apple Music author/settings/collection layouts. iPhone must never expose source-file or metadata management controls.

English interface is the initial default; Chinese content preference is independent. Preserve title/description locales without duplicating media. NSFW hiding must apply to every screen and the continue-reading accessory. See [UI spec](ui-spec.md), [Apple spec](spec.md) and [current implementation status](../implementation-status.md).

Mac imports retain the user's selected source grant across the import workspace, background queue, and failed-job retry. Finder drops must preserve the native sandbox grant before asynchronous work. Translation mode edits only the new media language and its localized chapter description after choosing an original chapter. Numeric Pixiv filename prefixes pre-fill the source ID; normal chapters still require a nonempty title.

The API defaults to `https://manga-api.thenoirclub.com`; service URLs/resource are deployment configuration edited in the project and require a rebuild. No runtime API/auth endpoint editor is exposed. Signed-out or restoring sessions show a full-window welcome screen with Sign In, progress/error/retry behavior and no library, sidebar, reader windows or tab bar. Sign In opens hosted ASWeb authentication. Only a verified account reveals the library; sign-out removes private UI and returns to welcome.
