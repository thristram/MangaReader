# Move source-only comics from Pending Organization

## Usage

On Mac, open **Pending Organization → Not Yet Organized**. Imports added without
moving files are discovered from their persisted source-only storage roots,
including after restarting the app. A comic's pending chapters appear together
in one row; an independent chapter has its own row. NSFW visibility follows the
library preference. Archived chapters and downloaded reader-cache files are not
classified as temporary source media.

Choose a connected, initialized archive under **Move to**, then click **Move Files**
on a row. This click commits the move directly, without another confirmation.
The destination choice is shared with Import & Identify. If none exists, create
and connect one in Storage Locations before moving. This operates on local or
Finder-mounted folders authorized on this Mac; it does not add direct SMB mutation
or iPhone file management.

Each selected chapter uses its current author/optional series/optional comic/
chapter path. Single media versions omit the language folder; multiple versions
use language folders. All versions of that chapter move together, including an
already archived original when a source-only translation is added. PDF/video
filenames and image filenames are preserved. The completed row disappears once
no chapter still references a source-only root. Empty source directories may remain;
unreferenced folders are not recursively deleted.

## Commit and recovery

`TemporaryOrganization` reuses the same `organizeChapterFiles` executor as
translation imports, backed by existing `FileOrganization` journals:

1. Check account/manage access, chapter revision, active tasks, unfinished journals
   and the destination's library marker.
2. Resolve authorized source roots and validate safe paths off the main actor.
3. Inventory and copy/verify all files before the revision-checked metadata update.
4. Verify the destination again and remove verified source files only after the
   metadata commit. Originals referenced elsewhere stay in place.

Comics commit chapter by chapter. If a later chapter fails, completed chapters stay
archived and the remaining chapters stay pending. Existing target files are never
overwritten. A failure after staging retains its journal and original source;
**Review → Resume & Finish** reconciles that work. A chapter with unfinished work
cannot start a duplicate move. Active organization blocks deletion and media-language
file changes for the affected chapter. Switching accounts invalidates the operation
before further account-scoped commits.

This uses the existing source-only root marker and recovery schema. No API fields,
environment variables, database migration or new dependencies are required.

## Checks

`python3 scripts/verify-mac-auth-ui.py` includes real isolated add-only imports,
comic grouping and standalone rows, one-click MP4/WebM/PDF organization, multiple
media languages, preserved text/media identities, shared-original retention,
metadata rejection with recoverable source files, duplicate-move prevention and
destination-collision protection. Existing translation import and recovery tests
exercise the extracted shared executor. All fixtures remain inside disposable
local test directories; no real library is moved.

Native Mac preview verification imported a synthetic image folder with **Add
without Moving**, observed its standalone pending row and destination selector,
then clicked **Move Files** once. The row disappeared; filesystem verification
confirmed identical archived bytes and removal of the source file. Production Mac
and iPhone targets build successfully.
