# Novel descriptions and asynchronous text translation

## Save and read

Original and localized descriptions accept **500,000 UTF-16 code units per field**
(Japanese BMP characters count one each). A 34,592-character Japanese novel is
supported. The full validated metadata is capped at **2.8 MB UTF-8 JSON**, and
HTTP request bodies at 4 MB; keeping the document bounded ensures selective sync
can return it within its 3-MB response budget. Limit errors explain what to split
instead of returning only “Invalid request”. This requires the updated server;
rebuilding the app alone does not raise the old server limit.

Chapter opening does not fetch or lay out the full novel before showing media.
Collection detail shows a 600-character excerpt with Read Description. The reader
and expanded description use lazy, selectable, verbatim text blocks. Segmentation
and an account-scoped SHA-256 cache run outside the UI actor; the cache retains at
most 32 entries / 8 MB of UTF-8 source cost and clears on account reset. It caches
segmentation, not font-specific layout. Font controls remain available. Existing
per-account metadata snapshots already cache the full original/localized text on
disk; opening the chapter adds no description HTTP request.

## Translation settings

**Settings → Ollama Translation → Long Text · All Models** contains:

- Maximum chunk characters: default **1,500**, adjustable from 100 to 10,000.
- Context tokens (`num_ctx`): default **16,384**.
- Output tokens (`num_predict`): default **4,096**.

Settings are global across model selections, device-local, and captured when a
job is created. Context values are bounded to 1,024–131,072 and output to
128–(context−512). Choose values actually supported by the installed model.
Character limits are Swift extended grapheme-cluster counts, not exact token
counts. A conservative UTF-8 byte budget reserves output/system-prompt space;
over-budget input fails without truncation. No accumulating chat history is sent.

Partition at `[chapter:NAME]` first (case-insensitive, marker starts a new group),
then pack complete paragraphs. If a paragraph is too large, split at sentence
ends, retaining closing quotation marks. Never cross a chapter marker or silently
cut a long sentence: an individual sentence beyond the limit explains how to
increase the limit or add a paragraph/sentence break. Joining source chunks
reconstructs the input exactly, including Unicode and whitespace.

Ollama's HTTP transport remains JSON, as required by `/api/chat`; model input is
one plain-text source chunk and model output is `message.content` directly. No
`format: json`, source JSON object, or localized-output JSON parser is used. The
old built-in JSON prompt is recognized and superseded; custom prompts are retained
with target-language/plain-text instructions appended. Provider errors, empty
content, incomplete generation and output-token exhaustion stop the job before
publication. No automatic inference retry/model installation/substitution occurs.

## Jobs and recovery

Title/description Translate creates an owner-local async job independent of the
editor's lifetime. On Mac, inspect it in the toolbar's Text Translation Queue,
Settings → Ollama Translation, or Pending Organization → Translation Queue under
Text Translations. The editor and detail button show completed/total chunks.
These shared settings/read views build for iPhone too; iPhone retains its viewing
role and does not gain metadata-management buttons.

Jobs run one at a time. After each completed chunk, atomically persist its output,
source partition and configuration under the account cache in
`text-translations.json`. Retry keeps the original settings and skips completed
chunks. Restart with current settings intentionally discards the chunk outputs and
retranslates the source. Cancel/remove are explicit; old callbacks cannot publish
after sign-out/account reset. On next launch, interrupted queued/running jobs
resume while failed jobs wait for Retry. macOS must remain running/awake; this is
not a server worker or guaranteed iOS background execution.

Only the complete ordered result is saved to the preferred language's title or
description localization. Original text, the other localized field, other
languages, media paths and files are preserved. A 409 reloads just this entity;
the job rechecks source and previous translation, then merges its one output field.
Changed source/newer manually edited translations stop publication and retain
cached output. Retry after a lost save response recognizes an already-published
identical output. No intermediate novel translations are sent to Vercel.

In Edit, translating an edited original field saves **that source field only**
first. Other unsaved fields/media-language edits retain their normal Save/file
commit workflow. A new unsaved item's result stays in its draft until Save and is
also shareable from the queue if the editor closes. If the draft is saved before
completion, matching jobs attach to the new item. Existing jobs continue after
closing the editor. Concurrent edits remain revision checked.

## Setup, data migration and checks

Deploy the server before installing the new clients. No Mongo schema/index/data
conversion, OAuth changes or new environment variables are required. Keep the
account cache to resume queued text jobs; it contains private source/translated
text but no credentials. Existing image translation queues remain separate.

After a Mac build, run:

```sh
swift test --package-path packages/MangaCore
npm test
MANGA_OLLAMA_CHECKS_ONLY=1 python3 scripts/verify-mac-auth-ui.py .build/xcode-swiftui-mac
```

The isolated regressions use synthetic novels and local URLProtocol services, not
private text, a live model or production metadata. See the dated verification log
for results and the remaining physical-device/live-model acceptance limits.
