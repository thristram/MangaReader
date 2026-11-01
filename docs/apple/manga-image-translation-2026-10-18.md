# Manga image translation on Mac

## Setup

Run [zyddnys/manga-image-translator](https://github.com/zyddnys/manga-image-translator) separately, with its models and any translation-provider credentials configured on that machine. MangaReader is an HTTP client; it does not install models, launch Python or copy provider credentials into the metadata API.

In **Settings → Manga Image Translation**, enter the service base URL, for example `http://localhost:8000`, and click **Test Connection**. For a reverse proxy, include its API prefix, such as `https://translator.example.net/api`. The URL must be HTTP(S), without embedded credentials, query or fragment. Use the upstream API server, with a translator worker running; a frontend-only web server is insufficient. See upstream installation/API instructions for the supported launch command for your checkout.

The connection test reads `<base>/openapi.json` and prefers `POST /translate/with-form/image/stream`, the standard full-image endpoint. Older services advertising only `POST /translate/with-form/image` remain supported. MangaReader never selects the web-optimized `/stream/web` endpoint. A successful test confirms the API route, not that all models/providers have valid credentials. Actual model errors appear on the translation job. There is no new MangaReader server environment variable or database migration.

### White results after using the translator web UI / Custom OpenAI

The local translator checkout inspected on 2026-10-25 (`c888fdf`) keeps a shared worker's `_is_streaming_mode` flag after a web-optimized request. Its non-streaming `/simple_execute/translate` handler does not reset this flag. Later API calls can therefore receive a valid **1×1 white PNG** even though the worker saved the full translation to its `result/.../final.png`. This is transport state, independent of which translation provider was selected. The standard `/translate/with-form/image/stream` handler explicitly disables web optimization for each request, and MangaReader now prefers that route.

The binary response consists of a one-byte status, a four-byte big-endian payload length, and that payload. Queue/progress packets are skipped; only a complete status-0 terminal image is accepted. A status-2 error is shown on the job. Truncated packets, unknown statuses, missing terminal results, trailing packets and invalid PNGs fail before caching or file organization. A 1×1 result is refused unless the uploaded source itself was 1×1. Resuming an unfinished cached page also validates it, so older cached placeholders cannot newly enter the archive. A failed POST is never automatically repeated against another translation endpoint, avoiding duplicate provider work.

Existing committed white pages are not automatically replaced or treated as successful new translations. The old non-streaming response did not retain a deterministic service result identifier, so MangaReader cannot safely match those pages to arbitrary `final.png` files. Keep the service results and account cache. Recover the matching full-resolution results through **All Pages → Add Images**, removing the erroneous translation version first if replacing the whole version; alternatively remove that bad translation and submit a new job with the fixed client. Removing a translation uses the existing recycle/file-commit flow. No original pages, cached files or service results are automatically deleted by this fix, and no provider configuration change is required.

## Options and defaults

The native form follows the upstream web UI's **static** option lists, including the two pasted HTML sections. There is no invented model/option discovery request. Definitions were checked against upstream commit `d6de6ab62a7be6afc0d07a3184149cdefbcd32f2`, in [front/app/config.ts](https://github.com/zyddnys/manga-image-translator/blob/d6de6ab62a7be6afc0d07a3184149cdefbcd32f2/front/app/config.ts), `front/app/types.ts`, `front/app/App.tsx`, and `manga_translator/config.py`.

| Option | Choices / initial default |
| --- | --- |
| Detection resolution | 1024, **1536**, 2048, 2560 px |
| Text detector | **default**, ctd, paddle |
| Render direction | **auto**, horizontal, vertical |
| Translator | Upstream web choices, initially **youdao**; includes offline, OpenAI-compatible, DeepL, Sakura and others |
| Target language | All 26 upstream web language choices; initially **CHS** |
| Inpainting size | 516, 1024, **2048**, 2560 px; 516 intentionally follows upstream UI |
| Inpainter | **default**, lama_large, lama_mpe, sd, none, original |
| Unclip ratio | **2.3**; greater than 0, up to 10 |
| Box threshold | **0.7**; 0–1 |
| Mask dilation offset | **30**; integer 0–200 |

Valid edits in settings or the confirmation form automatically become defaults. Each job captures its URL and complete option set, so later preference changes do not change an existing job or retry. Chinese variants use separate media locales: CHS → `zh`, CHT → `zh-Hant`. Other examples: ENG → `en`, ESP → `es`, FRA → `fr`, PTB → `pt-BR`. Text title/description localizations remain independent.

## Translate a chapter

1. Open **Edit Chapter**, scroll to the bottom, and choose **Translate Manga…**.
2. Choose source media and the connected archive destination, then review translation options. The connection is tested automatically. An unavailable or incompatible service displays an error and disables the translation action.
3. Click **Translate Manga**. The job continues while reading/browsing or after closing the editor. The Mac app must remain running; this is not a Vercel/GPU background worker.
4. Open **Pending Organization → Translation Queue**. Jobs are grouped by chapter, newest chapter groups first. Each job shows its target language, description, page progress and error/retry controls. Click the chapter to see generated pages and open their zoomable native preview.

Source image versions and PDF pages are supported; video versions are excluded. Images use the existing bounded native image decoder, with orientation applied, then upload as PNG; exceptionally large images follow its 24-million-pixel Mac limit. PDFs are rasterized one page at a time, at up to 2400 pixels on the longest edge. The service returns rendered PNG images. Only one page/job is processed at a time to bound local memory and GPU requests.

The source page order is captured when queuing. Partial source versions use their original-page fallback. If source media/page order changes later, the job stops with an explicit error rather than attaching results to the wrong page. Chapter text-only edits do not invalidate an otherwise unchanged source.

## Page alignment and files

A successful result is validated, cached under the current account, then added at its exact canonical page position in the target language. Missing positions remain `nil` and continue to fall back to the original. Existing target image pages are skipped and preserved; a full existing translation needs no job. A PDF/video target language is refused rather than overwritten.

Each page uses the existing verified copy → revision-checked metadata update → source cleanup journal. When adding the first target language, the original and translated versions are organized using the normal author/series/comic/chapter/language policy. Originals retain their media identity, bytes and reading order. Generated filenames include the job ID and page number, and existing files are never overwritten. The selected archive destination is validated against the current account and destination marker.

The rendered page cache is retained for previews and retry. A network/model failure stops that job at the failed page; later queued chapters may proceed. Retry keeps committed pages, uses already-rendered cached results, and translates only unfinished pages. If metadata/file commit failed after rendering, Retry reconciles that page's exact file journal before continuing.

Recovery preserves newer descriptions, text localizations, tags, NSFW flags and source links. New image-addition journals retain the original chapter input: if file references, original title/language and parent relationships still match that baseline, recovery merges only the planned media into the latest revision. If the desired media references already match the server, recovery only verifies/finishes the journal without another metadata write. Changed paths, page order, media language or folder-defining metadata still require review in **File Management Queue**.

Old per-page translation jobs can also recover without a stored baseline. Both **Translation Queue → Retry** and **File Management Queue → recovery** match the journal to exactly one account-owned job/cache page, undo its single appended target slot, then prove the remaining media identities/order/alignment and every old-to-new file move against the current chapter. If the current target has extra append-only pages, recovery preserves them and appends the cached page after them; all previous canonical mappings must remain unchanged and the new slot must still be empty. Original files (including shared sources) and cached output must match the journal digests. Only that proven media change is merged; newer descriptive metadata stays intact. The rebased plan/baseline is saved before the metadata update, with optional `priorMetadata` retaining the old desired payload. Ambiguous/missing job records, competing target slots, unrelated operations or changed originals still block recovery. General old organization journals do not receive this translation-specific inference. No database migration is required.

Background synchronization merges by revision so an older snapshot cannot erase a successfully committed translated page. Recovery reads the latest on-disk journal, ignores an already-completed plan, closes the review sheet after success and refreshes the list. Failures stay visible in the sheet.

## Organization work and NAS performance

Ordinary import can use a same-volume rename through FileCommit when sources are exclusive. Multi-version reorganization uses FileOrganization's per-file verified copy/update/cleanup transaction; it is not a directory rename. Cross-volume transfers, retained shared originals, byte verification and API acknowledgement take real time. Generated translation images also travel from the Mac cache into the archive.

For an already-organized chapter, adding another translated image now skips filesystem resolution for unchanged existing references, does not resolve unrelated library roots or compute whole-library shared paths, and schedules no directory cleanup for preserved files. Only actual existing-file relocations require those sharing checks and source-folder cleanup. Actual changed paths still receive the same path/collision/digest/journal checks. First-language transitions and bulk relocation continue using verified copies; this change does not introduce a new folder-rename transaction.

The translation queue distinguishes checking the destination, preparing existing files, copying added images, saving the chapter and verifying files. This makes file-transfer time visible separately from metadata/API work. Native regressions verify that after the first six-page chapter transition, the next five page commits each contain exactly one new file and no old-folder cleanup. No measured speedup on a real NAS is claimed from local fixtures.

## Persistence and account boundaries

Job options, page status, errors and cached PNG references are stored in `accounts/<ownerId>/image-translations/queue.json` and per-job subfolders in local Application Support. Jobs are scoped to the verified owner and require `manga:manage`. Signing out cancels active client work and clears the in-memory queue. Returning to the same account restores its jobs. Queued jobs resume; jobs interrupted while running show an explicit Retry state. Originals and generated cache remain available for recovery.

The configured base URL/default options are device-local preferences. Translation images travel directly from Mac to the user-configured service, then into local/Finder-mounted NAS storage. The Node/Vercel control plane only receives ordinary media metadata; no image data or provider keys pass through it. Other Apple devices see committed language metadata via existing synchronization and read those files through their configured storage connection.

## Pending Organization navigation

- **Not Yet Organized**: source-only comic/chapter groups; its sidebar count matches the groups displayed. Move Files remains available.
- **File Management Queue**: imports in reverse enqueue-time order, plus unfinished file recovery. The sidebar shows activity while jobs are queued/running; with no pending jobs, failures show a warning. Failed rows provide Retry and Remove from Queue. Removing a failed row releases its retained import worker/grants but leaves files and recovery journals intact.
- **Translation Queue**: chapter groups, per-job progress/description, failure reason and Retry, with translated-page previews.
- **Commit History**: completed and unfinished file organization/import/deletion journals, including generated-page commits. Unfinished entries retain their recovery actions. History file reads run away from the main actor.

## Verification and limitations

Native integration tests use synthetic image responses rather than real translation models. They exercise multipart/config compatibility, service unavailability, progressive canonical alignment, cache/preview files, retry after a service error and app-queue restart, metadata-failure recovery without retranslating cached pages, existing partial translations, invalid PNG refusal, PDF page rasterization and failed file-queue removal. Mac/iPhone builds and the native UI preview cover navigation and forms. Real model quality, GPU capacity and provider credentials must be checked against your running service.

No API schema, auth scopes, dependencies or MongoDB indexes are added. Existing account/file journals remain compatible. New queue data is local only; no metadata migration is needed. Preserve the account cache and file journals when migrating a device or investigating an unfinished task. Completed old file journals are not retroactively used to recreate translation jobs.
