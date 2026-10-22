# Apple requirements

Mac All Pages batch edit, 2026-10-17: Edit enables native image multi-selection and
drag selection with blue circular checkmarks. Provide Select All, Deselect All,
Set as Translation and Delete. Translation extracts the selected pages into a new
language version of this same chapter, retaining reading order; alignment confirmation
must open a file Commit review, and only Commit can move/organize files. Delete
must retain recoverable copies. See [accepted behavior](all-pages-batch-edit-2026-10-17.md).

Native Apple clients implement storage/read/UI requirements in the [overall baseline](../requirements.md). Mac is the library manager and commit executor; iPhone is the reader/offline downloader. Both must use ASWeb public-client PKCE login and account-isolated metadata/state.

iPhone reading clarification, 2026-10-14: the media canvas fills the screen, while minimum/default image and PDF zoom shows the complete page without cropping. Native horizontal transitions follow the finger and cancel safely. System safe areas protect controls without adding a fixed band above the media. See [reader verification](iphone-reader-fit-and-paging-2026-10-14.md).

P0 completion requires local/SMB operations, safe reviewed file plans, synchronized tags/text/personal state/progress, content fallbacks, full native reader gestures, all-page thumbnails, download groups and the specified Apple Music author/settings/collection layouts. iPhone must never expose source-file or metadata management controls.

English interface is the initial default; Chinese content preference is independent. Preserve title/description locales without duplicating media. NSFW hiding must apply to every screen and the continue-reading accessory. See [UI spec](ui-spec.md), [Apple spec](spec.md) and [current implementation status](../implementation-status.md).

File-reference visibility, 2026-10-16: Mac comic/chapter editors list referenced folders. Both readers expose **… → Info** for the current image/PDF/video file; iPhone description is a separate menu action. An unconfigured SMB-root error includes its root identity and requested reference path. Paths are selectable; missing device connections retain the relative reference without inventing an absolute NAS location.

Pending Organization must also list existing comics/chapters whose media still
references source-only roots. Group a comic's chapters into one row, provide a
destination and one-click Move Files commit, and retain recoverable originals
when file or metadata work fails. This remains a Mac management feature.

Mac imports retain the user's selected source grant across the import workspace, background queue, and failed-job retry. Finder drops must preserve the native sandbox grant before asynchronous work. Translation mode edits only the new media language and its localized chapter description after choosing an original chapter. Numeric Pixiv filename prefixes pre-fill the source ID; normal chapters still require a nonempty title.

The API defaults to `https://manga-api.thenoirclub.com`; service URLs/resource are deployment configuration edited in the project and require a rebuild. No runtime API/auth endpoint editor is exposed. Signed-out or restoring sessions show a full-window welcome screen with Sign In, progress/error/retry behavior and no library, sidebar, reader windows or tab bar. Sign In opens hosted ASWeb authentication. Only a verified account reveals the library; sign-out removes private UI and returns to welcome.

### Mac media-version removal and image additions

- Chapter Content can recycle any complete media translation, including the last version and PDF/video content. Keep chapter metadata when media becomes empty.
- Successful version/chapter deletion removes its empty physical language/chapter directories; retain shared or unrelated contents and container/root directories.
- All Pages can select one or multiple image files for an explicit append commit. Support empty chapters, natural filename ordering, safe name collisions and new-language directories.

### Shared language choices

- macOS and iOS language selectors use the shared text/media language catalog, including Chinese (`zh`, 中文), Spanish (`es`, Español) and French (`fr`, Français). Media-language choices also include No text. Reader language switching lists the versions actually available in that chapter.

### Mac manga image translation

- Configure/test a manga-image-translator API base URL and persistent default options. Follow upstream static/dynamic option behavior; the inspected upstream web catalog is static.
- Edit Chapter provides Translate Manga with source/target language, destination and option confirmation. Connection failures block enqueueing.
- Translate image/PDF pages in a persistent account-scoped background queue, attaching and organizing successful pages incrementally. Preserve originals, existing target pages and missing-page fallback. Provide error reasons, retry and generated-page preview.
- Pending Organization exposes Not Yet Organized (count), File Management Queue (newest first, activity/error indicator, retry/remove failed entry), Translation Queue (chapter groups/progress/description/previews) and Commit History as separate sidebar children.
