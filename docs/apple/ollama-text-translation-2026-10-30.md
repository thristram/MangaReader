# Ollama title and description translation

**Historical 2026-10-30 behavior.** The structured-output contract below is
superseded by [long-text async translation (2026-11-02)](long-text-translation-2026-11-02.md).
Current clients use plain output, bounded chunks and a durable progress queue.
The original diagnostics remain as a dated record.

Mac title/description translation calls the configured Ollama host directly using
`POST /api/chat`, with the exact selected model name, `stream: false` and
`format: "json"`. Text is stored in the preferred language's metadata localization;
it is separate from image translation and media files. Provider errors stop the
translation before its metadata save.

## Setup and diagnostics

In **Settings → Ollama Translation**, set the service URL and click **Test
Connection**. The native `GET /api/tags` response populates **Installed Models**.
Choose an installed model or enter its exact name, including any tag. No model is
downloaded, installed, substituted or selected automatically.

The connection status distinguishes a reachable empty host, an unavailable selected
model and a host with an available model. It never equates a running server with
an installed model. A changed URL or failed discovery cannot retain a newly fetched
list from another host. A fresh test on the new host is required before using its
model menu.

Service URLs accept the native base or pasted `/api`, `/api/chat`, `/api/tags`
suffixes, with surrounding whitespace/trailing slashes normalized. Reverse-proxy
prefixes are retained. Query strings, fragments and embedded credentials are
rejected. OpenAI-compatible `/v1` endpoints are not the native Ollama API.

HTTP failures display the status and Ollama's bounded JSON `error` detail. A 404
that specifically identifies a missing model explains how to select/install that
model; an unrelated route 404 does not claim the model is missing. Valid-HTTP error
objects, invalid JSON, malformed model output and missing translated fields also
fail explicitly. The app does not automatically retry inference or switch models.

On 2026-10-30 the initially running, incorrect instance at `http://127.0.0.1:11434` returned
`{"models":[]}` and a synthetic request for `galtransl:7b` returned HTTP 404 with
`model 'galtransl:7b' not found`. The running instance's model directory was
`/Users/thristram/.ollama/models`, with no model manifests. Restore the intended
directory containing `manifests` and `blobs` via that instance's `OLLAMA_MODELS`,
or install/import the intended model, then retest and select it. After the user
restarted the intended instance, `/api/tags` listed `galtransl:7b` and six other
models. Live calls through the production Swift adapter then translated both a
synthetic title and a multiline description successfully. A running server
or request log by itself does not establish model availability. Do not blindly
download a similarly named model: custom names may require their original
Modelfile/GGUF. See [Ollama API errors](https://docs.ollama.com/api/errors).

## Text and prompt behavior

Translate controls disable when the corresponding original source field is empty
or whitespace-only. The service adapter also rejects an entirely empty source
before making a request. The original field remains the source when regenerating
a localization; adding text only to another localization does not fill the original.

The editable system prompt remains in device-local preferences. MangaReader appends
a small output requirement to return a JSON object with string fields `title` and
`description`, keep empty source fields empty, and omit markdown/commentary. This
keeps custom prose/style instructions compatible with the metadata response parser.
Unicode, quotes and line breaks are JSON-encoded without truncation.

The shared adapter/settings are used by both app targets. No server endpoint,
OAuth scope, credential storage, database migration or media-file migration changes.

## Regression checks

After building the Mac target, run the isolated synthetic checks:

```sh
MANGA_OLLAMA_CHECKS_ONLY=1 python3 scripts/verify-mac-auth-ui.py .build/xcode-swiftui-mac
```

They use an ephemeral URLSession and separate UserDefaults suite. They cover exact
model/error details, empty source/model refusal without a POST, native endpoint
normalization and proxy prefixes, empty/installed model lists, custom prompt/output
contract, title/description-only results, Unicode/newlines and no fallback inference
or model download. They do not submit real comic text or install a model.

Both final Mac/iPhone builds and these isolated regressions passed. A separate
opt-in local diagnostic compiled the production `OllamaTranslator.swift` with an
isolated preferences suite and called the restarted host using `galtransl:7b` and
a custom Japanese-fiction prompt. Title `雨上がりの帰り道` returned `雨后的归途`;
description `雨がやんだ。\n二人は駅まで一緒に歩いた。` returned
`雨停了。\n两人一起走到车站。`. Both results decoded through the app's actual
`LocalizedText` parser. No account metadata, saved preferences or private comic text
was changed/submitted by that diagnostic. The user-provided local GGUF/Modelfile
registration started before the interruption also reported success; no further
model import was needed for the restarted-instance verification.
