# Collection activation and nested imports

## Collection cards

Previously, only the cover and title had open actions. The subtitle, reserved
second title line, progress, and gaps inside the card could appear clickable but
did nothing. `ComicTile` now has one rectangular activation region around the
complete card. Chapter cards open the reader; other entities use native
navigation. Download and edit controls remain separate sibling controls layered
over that region, avoiding nested buttons and links.

## Selected directory grants

The importer scans a selected directory recursively. Previously it created a
separate storage binding for every discovered chapter directory, even though
the user had selected the containing directory. Generated descendant URLs are
not independent security-scoped grants, and a bookmark for a moved chapter can
follow that chapter to its destination.

The importer now uses the closest selected ancestor as the source storage root
and records media paths relative to that root, for example
`Collection One/Chapter A/1.png`. Background queue workers retain the selected
directory scope independently of the import workspace. Moving one descendant
therefore leaves the source root and remaining siblings stable. This also
applies to PDF/video files nested in the selected directory; individually
selected files retain their existing parent-directory binding behavior.

Move destinations, collision checks, recovery journals, metadata commits, and
source cleanup rules are unchanged. Errors now name the failed stage. The
Pending Organization reminder appears once file work has started, rather than
for every preliminary access or validation failure.

## Verification

- Mac and iPhone Simulator builds succeeded.
- In the running Mac preview, coordinate clicks on the author/chapters subtitle
  and the reserved second title line opened the expected comic. The pencil
  opened Edit Comic; cancelling returned to All Comics without navigating.
- `scripts/verify-mac-auth-ui.py` covers one selected parent containing two image
  chapters and a PDF in separate nested collections. All three queue jobs finish
  after the import workspace closes, share one source binding, preserve exact
  media bytes, and leave the source bookmark pointing to the selected parent
  after the children move.
- An add-only nested import retains its full relative path and reopens correctly
  after source bindings are released and resolved again.
- Existing import, translation, recovery, deletion, download, and reader checks
  remain in the same regression harness.

These checks use synthetic local files and an isolated test account without
production API calls. The user's NAS permissions and the original sandboxed
failure have not been reproduced on their real library.

To repeat the native regression after a Mac build:

```sh
python3 scripts/verify-mac-auth-ui.py
```

If an earlier failed operation already moved files, finish or recover that
operation in Pending Organization before importing the same source again.
