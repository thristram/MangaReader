# Standalone video/PDF source grants

The reported `Connecting source folder … couldn't be opened` error occurred
before file movement. A standalone MP4/WebM/PDF grant authorizes that file.
The importer previously selected its parent as the source root, then attempted
to create a bookmark for that unselected directory. macOS sandbox denies it.

The importer now retains the exact selected resource and its captured bookmark.
Directory selections still cover descendant chapters. Standalone files each
receive their own source binding, even when they share a parent. LocalMedia
keeps the scoped resource separate from the logical directory used to resolve
the media's relative filename and stops access on that actual resource.
Both Add without Moving and reviewed file commits use this path.

The bookmark dictionary stays `[rootId: bookmarkData]`; existing directory
bindings still work. Updated Mac builds understand file bookmarks as well.
Media relative paths, API contracts, MongoDB records and file-commit recovery
formats require no migration. Sandbox entitlements remain unchanged.

## Verification

- Mac and iPhone Simulator builds pass.
- `python3 scripts/verify-mac-auth-ui.py` covers standalone MP4/WebM/PDF imports,
  independent sibling-file grants, persisted bookmark readback after releasing
  local scopes, exact byte preservation and source cleanup during commit.
  Existing nested folder/PDF imports, retries, language organization, shared
  sources, deletion, account isolation and import responsiveness also pass.
- `python3 scripts/verify-single-file-sandbox.py` builds a separate app with the
  production sandbox entitlements and synthetic API/media. In its system open
  panel select all six generated files (first row, Shift-click last row).
  The parent-directory bookmark is confirmed denied. Add-only and Commit both
  succeed for MP4/WebM/PDF; local scope release/bookmark resolution, archived
  bytes and source cleanup are checked. The app exits with a PASS/FAIL result.
  Only generated `.build` fixtures and its private container are used.
- Video fixture bytes are synthetic: these checks validate import authorization
  and file movement, not video codecs or playback. No real NAS, production API
  or user media were modified.

After updating the Mac app, retry the selected file import. A file genuinely
removed/unmounted at its original location still needs to be selected again.
