# Import source access, translation form and Pixiv names

## Source authorization

The reported error was `Connecting source folder …: The file … couldn't be
opened`, before file movement. The user had only tried Finder drag-and-drop.

The old drop handler loaded a URL from `NSItemProvider`, then switched to the main
actor before retaining access. Source bookmarks were created later, after async
metadata requests. Workers independently started/stopped scopes, and a failed
worker closed its scopes before Retry attempted to reacquire the same URLs.
This made the drop, queue, and retry depend on transient authorization.

Finder drops now read native `NSURL` objects through `NSPasteboard.Name.drag`.
The drop/picker callback captures an `ImportSourceAccess` containing the URL,
security scope, and app-scoped bookmark before async work. The provider fallback
also captures access before switching actors. The workspace, queued worker and
failed-job retry retain the same access object. Closing one owner does not
revoke another's lease. Successful completion or cancellation releases the
queue's lease; failed jobs retain it until retry or cancellation.

Source binding saves the captured bookmark instead of creating another during
commit. Parent-root relative paths, account isolation, explicit commit, collision
checks, journals and verified cleanup remain in place. No sandbox entitlements
were relaxed. Apple's [file access documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
describes persistent app-scoped bookmarks; the [native pasteboard documentation](https://developer.apple.com/documentation/appkit/nspasteboard)
describes native drag object transfer.

## Translation form

- The media translation toggle sits above Chapter Name.
- Enabling it hides Chapter Name, Author, Comic, Tags, NSFW and Source IDs.
  Choose the Original Chapter, then edit Media language and Chapter Description.
  Existing page alignment remains available.
- Submit stays disabled until an original chapter is selected. A hidden empty
  chapter title does not prevent a translation import.
- The selected original chapter supplies its identity, hierarchy and metadata.
  A supplied description updates the selected media language's text localization;
  original text and unrelated localized fields are preserved. An empty description
  leaves existing text intact. Media versions remain separate from text locales.

## Pixiv filename suggestions

`ImportName.parse` recognizes an ASCII numeric prefix followed by `_`, or an
entirely numeric name. Import selection pre-fills the Pixiv source ID and removes
the numeric prefix and first underscore from the suggested chapter title.

| Import name | Chapter Name | Pixiv ID |
| --- | --- | --- |
| `134675894_お帰りなさい` | `お帰りなさい` | `134675894` |
| `86583518_1-7` | `1-7` | `86583518` |
| `129126566` | Empty; enter a name for a normal chapter | `129126566` |

Later underscores are retained. Names without that pattern are unchanged. PDF
and video candidates use the filename without its extension. Suggestions do not
rename source files. Translation imports use the selected original chapter and
do not replace its source IDs with hidden suggestions.

## Verification

- Mac and iPhone Simulator builds passed.
- MangaCore: 24 tests executed, one environment-dependent test skipped, zero
  failures. Pixiv cases include Japanese titles, numeric ranges, numeric-only,
  later underscores and unrelated numeric names.
- Native regression passed: a deliberately unavailable destination fails a queued
  import; after closing its workspace, the failed job retains its source lease.
  Restoring the test destination and retrying the same job completes without
  reimport. Completion releases the lease. Translation import with a hidden empty
  title succeeds and preserves original text while saving the localized description.
- Existing nested image/PDF batches, add-only reopening, byte preservation,
  translation organization, recovery, deletion, downloads and reader checks passed.
- An isolated ad-hoc-signed preview was built with the actual app sandbox,
  user-selected read/write and app-scoped bookmark entitlements. A system file
  picker successfully imported a selected parent containing two synthetic
  chapters. Its UI showed the stripped title/Pixiv ID; toggling translation hid
  unrelated fields and disabled submission until an original was selected.
- The native UI bridge disconnected at the move-review action and remained
  unavailable after reconnection attempts. The sandbox preview's final Commit
  and a real Finder drag were therefore not verified. The user's NAS error has
  not been reproduced on their real library. Automated tests use local synthetic
  files and an isolated account with no production API calls.

```sh
swift test --package-path packages/MangaCore
python3 scripts/verify-mac-auth-ui.py
python3 scripts/preview-native-ui.py mac --sandbox
```

The sandbox preview has a separate `.sandboxpreview` bundle, container, fixtures
and invalid OAuth ID. It never restores production credentials. Its local signing
does not change the production app's signing configuration.
