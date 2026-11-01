# Chapter reassignment and faster file organization

## Chapter reassignment

On Mac, open **Edit Chapter → Collection → Comic**, type another comic's full
name or select a search result, then choose **Save**. The chapter inherits that
comic's author and Series and appears in its chapter collection. Existing media
references, language versions and localized text survive unchanged.

Previously the search text could change without changing the selected comic ID.
A clicked result could disappear when the text field lost focus; selecting a comic
with a different parent also sent inconsistent author/Series IDs to the service.

A unique exact title now resolves to an ID. An incomplete or ambiguous query must
be selected from the results before Save; a visible message explains this instead
of silently saving the previous comic. Save errors appear below the scrolling form.
Changing an author or Series clears incompatible child-parent choices. Deleted or
unavailable destination entities cannot be silently selected.

Saving metadata does not move source files. Physical changes still require a file
commit. The iPhone remains read-only for comic management.

## Organization changes

Translation import, language correction, page splitting, additional images and
Not Yet Organized now use the common optimized organization executor. Existing
unchanged pages are skipped. Changed-file planning and shared-source checks are
batched off the main actor.

Exclusive same-volume files use filesystem metadata operations rather than a copy
and multiple complete SHA reads: hard links where available, or a journaled rename
with an original metadata snapshot. A Finder-mounted SMB share may reject links
and exclusive rename; its fallback performs a coordinated ordinary rename and
records the file's post-rename identity. Shared or cross-volume files still use
verified copies. Generated translation cache files and externally added images
remain independent copies. Sidecars and nested/empty folders survive language
corrections; empty source folders are cleaned only after metadata is confirmed.

If metadata saving fails after a rename, the files are at the journal's destination.
Use **Pending Organization → File Management Queue → Resume and Finish**. Do not
re-import the same chapter. Recovery requires the recorded target identity;
unverifiable files require review rather than being overwritten.

Direct import retains its existing fast folder move. Whole-chapter deletion and
Recycle retain their existing integrity/rollback checks; this change does not
remove deletion verification.

No service deployment, environment variable, MongoDB migration or media rewrite
is required. Earlier copy journals remain recoverable. Finish new pending file
work before downgrading the app. See [ADR 0017](../adr/0017-same-volume-organization.md)
for transaction and interrupted-SMB limits.

## Validation

- Final Mac and iPhone Simulator builds passed. Xcode project consistency and whitespace checks passed.
- MangaCore: 67 tests executed, zero failures, one second-volume test skipped.
  Regression tests cover hierarchy changes, media/text preservation,
  shared-reference aliases and exclusions, links, independent-copy fallback,
  journaled rename, collisions, replaced sources/targets, interrupted checkpoints,
  legacy SHA journals and destination-folder recovery.
- Native synthetic checks exercise the real revision-checked fixture API, comic
  reassignment across author/Series boundaries, translation import, all-pages split,
  language correction including sidecars, shared-source protection, failure/recovery,
  image translation's old-journal recovery and source-only organization.
- Actual isolated Mac UI: typing **Beyond the Blue** in a different comic's chapter
  editor updated author/Series and Save moved the chapter between collections.
  Searching **The Way** disabled Save until selecting the result; clicking the result
  and saving restored the chapter. No production library records were used.

The repeatable synthetic filesystem benchmark is
`scripts/check-file-organization-performance.swift`. Compile after a Mac build:

```sh
xcrun swiftc -parse-as-library \
  -I .build/xcode-swiftui-mac/Build/Products/Debug \
  scripts/check-file-organization-performance.swift \
  .build/xcode-swiftui-mac/Build/Products/Debug/MangaCore.o \
  -o .build/check-file-organization-performance
.build/check-file-organization-performance
# Optional: use a writable parent on a mounted NAS. Only a new temporary directory is used.
.build/check-file-organization-performance /Volumes/YOUR_SHARE
```

The benchmark generates 12 files totaling 24 MiB, verifies every output byte and
completed journal, and removes its temporary directory. Timings exclude generation,
attribute-settling and final byte-comparison overhead. They measure filesystem
execution, not API latency or total import time. A failed baseline is reported as
such and must not be used to claim a speedup ratio.

Final measured run (12 × 2 MiB; recovery journals on the local disk, as in the app):

| Location | SHA-verified copy baseline | Same-volume organization | Result |
| --- | --- | --- | --- |
| Local temporary directory | 0.127 s | 0.023 s | 5.43× for this synthetic workload |
| Mounted SMB share | Failed with Foundation copy permission error | 1.324 s | Every byte and completed journal verified; no valid baseline ratio |

The NAS checks created and removed only new synthetic directories/files. No existing
manga, production metadata or credentials were used. Per-file NAS metadata latency,
shared references and cross-volume transfer can still dominate large operations;
this is not an atomic whole-folder rename or a promise of constant-time organization.
