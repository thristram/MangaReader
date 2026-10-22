# File references in editors and Preview

## Behavior

- Mac **Edit Comic / Edit Chapter → Referenced Folders** lists the persisted
  chapter/media folders, labelled by chapter and media language. Multiple images
  in one version's folder share a row; different folders and translations retain
  separate rows. A comic includes its visible child chapters. Newly created items
  without media have no references yet.
- Mac **Preview → … → Info** displays the current file's storage root name/ID,
  relative reference path, available physical source location and on-device copy.
  Existing Chapter Description behavior remains in the same menu.
- iPhone **Preview → …** now contains separate **Info** and **Chapter Description**
  actions. Info uses a native sheet; description retains its popover.
- Missing SMB configuration errors retain the Connections instruction and include
  the requested file's relative reference plus root name/ID. Errors and path
  details support text selection/copying.

## Resolution rules

`MediaReferences.swift` presents existing account metadata and device bindings;
it never opens/downloads a chapter to inspect its location. Mac bookmark resolution
uses the existing background, non-mounting `LocalMedia.readingRootURL` path. Folder
details resolve each root once per load. SMB source paths combine server authority,
share, base folder and the stored reference; account names, passwords, query strings
and fragments are excluded. Offline file paths come only from a matching download
manifest and are labelled separately from the source.

If this device lacks a root binding, the UI shows the root identity and relative
reference, with an explicit unconfigured-location explanation. The synchronized
metadata cannot supply a server/share known only to another device, so an absolute
NAS location is not invented. Finder-mounted storage uses its Mac mount path.

Reader Info uses `pageMedia` before resolving its file. Translation alignment and
fallback therefore select the same source shown on the canvas. Images use their
resolved source-page index; PDF pages and video chapters refer to physical file
index zero. Editor references reflect committed metadata, including reviewed media
language moves, rather than projecting draft rename paths.

This adds no API fields, authentication scopes, environment variables or database
migration. Device bookmarks/connections and offline cache paths are not synced to
the metadata service.

## Verification

Both production Apple targets build. The existing native Mac and iPhone regression
suites also run `NativeUIFixtures.storageReferenceChecks`: second-image selection,
PDF/video single-file references, partially translated page fallback, deduplicated
folder groups, root-level files, separate source/offline locations, SMB authority
redaction and the actual unconfigured-root download failure with the requested
second file. Tests use synthetic metadata/files and no NAS connection.

Native simulator inspection confirmed the two iPhone menu actions, the video Info
sheet with its reference/on-device path, and the separate description popover.
The native Mac preview also confirmed the comic editor's per-language folder rows,
wrapped full paths, and the reader's Info sheet with separate source/cache paths.

Run from the repository root after the Mac production build:

```sh
python3 scripts/verify-mac-auth-ui.py
python3 scripts/verify-phone-reader.py
python3 scripts/verify-apple-project.py
```
