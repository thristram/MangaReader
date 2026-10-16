# Correct an imported media language

## Usage

1. On Mac, open **Edit Chapter → Chapter Content**. Each media version has its
   own **Media language** dropdown.
2. Choose the corrected language. The **Change Media Language** sheet shows the
   old/new language and directory paths. Cancel leaves metadata and files intact.
3. Choose **Commit**. The operation also saves the chapter's current editor
   changes. On success, the editor shows the corrected language and revision.

For example, changing an existing translation from `en` to `zh` changes
`Author/Chapter/en/` to `Author/Chapter/zh/` and updates that media version's paths.
It preserves page filenames, sidecar files, media ID, page mapping, reading
progress references, other media versions, and all text localizations. Correcting
a media language does not move titles/descriptions to another text locale.

A chapter with one media version has no language folder under the storage rules.
Its commit changes only the media language and preserves existing paths.

## Commit and recovery

- Another version in the requested language blocks the change. Existing target
  folders are never overwritten.
- The reviewed chapter revision must still match the current one. Pending
  translation imports for the same chapter must finish first.
- File operations require a connected, verified local archive root, including a
  Finder-mounted NAS. Multi-version media must already have one language directory
  for the selected version; unorganized paths need organization first.
- The whole language directory is copied and verified before saving metadata.
  Originals remain readable until the API confirms the update. Cleanup then
  removes the old directory, unless another chapter/version still references it.
- Failures after file staging retain the existing commit journal and desired
  metadata. Close the sheet and use **Pending Organization → Review & Recover**
  to reconcile the revision and finish verified cleanup. Repeated Commit is
  disabled after a failure that may require recovery.

This uses the existing entity update API and journal format. No server migration,
new environment variable or service deployment is required. iPhone retains its
reader role and has no file-language editing controls.

## Verification

- Mac and iPhone Simulator builds passed.
- MangaCore: 26 tests executed, one environment-dependent test skipped, zero
  failures. New cases cover PDF language paths, duplicate/unsafe/unorganized
  plans, stable IDs/page mappings/text locales, and a single video version.
- Native regression passed actual commits using synthetic files and the fixture
  API: review without mutation, stale revision rejection, whole-directory changes
  including sidecars, rejected metadata update with retained originals, journal
  recovery, shared source protection, target collisions and single-version commits.
- The running native Mac preview showed the per-version dropdowns and commit
  sheet. Cancelling a `zh → en` review retained `zh`. Committing the same change
  returned to Edit Chapter with **English** selected. Filesystem checks confirmed
  the old `zh` directory was absent, `en` held its three pages, and the six-page
  `ja` original was unchanged.
- These checks used isolated local synthetic media without production service
  calls. A real NAS and direct SMB execution were not verified for this feature.

Repeat after a Mac build:

```sh
swift test --package-path packages/MangaCore
python3 scripts/verify-mac-auth-ui.py
python3 scripts/preview-native-ui.py mac
```

The Mac preview prepares its first chapter with organized `ja`/`zh` folders for
this interaction check. It uses a separate preview bundle, synthetic API, and
invalid OAuth client, preserving the real account and library.
