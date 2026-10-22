# ADR 0016: Import shared-source reference index

Status: Accepted · 2026-10-20

## Context

Before moving imported media, the Mac checks whether another media version still
references the originals. The previous check opened every referenced root up front
and resolved each page's full filesystem path, repeating ancestor lookups on NAS
volumes. Comparing root IDs or filenames alone would miss nested bindings and
differently named symlinks to the same file.

## Decision

Build a metadata-only `SourceReferenceIndex` on the background worker, grouping
relative paths by storage root and directory with their referencing media IDs.
LocalMedia caches this index by verified owner and AppSession metadata generation.
Deleted entities are excluded; another language version in the same chapter still
counts as a reference. Account release clears the cache.

Resolve root bindings lazily, checking already-open roots first and stopping on a
positive match. Once a root is canonicalized, skip its references if all source
files are outside it: PathPolicy does not permit references escaping that root.
Within relevant roots, resolve common directory prefixes once per check. Match
ordinary filenames in memory; list each referenced directory with prefetched
symlink attributes to detect differently named file aliases. Only those aliases
need individual file resolution. If a sandbox file grant does not permit listing
its parent, use the previous per-reference resolution for that directory.

Cache no negative filesystem results between checks. Symlink changes and rebinding
must be seen immediately even when metadata is unchanged. If metadata or bindings
change while a negative answer is being computed, retry against the new snapshot;
after three changing snapshots, retain originals conservatively. Account changes
and cancellation abort the check. Unconnected roots keep the existing behavior:
their physical references cannot be checked on that device.

## Consequences

Ordinary import avoids per-page NAS path resolution. Cold bookmark resolution and
directory listings may still take time; this is not a guarantee of instant network
operations. There is no persistent filesystem index, API change, database migration
or change to file-copy integrity checks. Shared originals are still retained.

Regression checks cover media exclusion, nested/root aliases, renamed file
symlinks, external symlink changes, unsafe paths, PDF/video and Unicode names. A
20,000-reference fixture verifies 21 directory resolutions, 20 listings and zero
individual file resolutions; a disjoint root requires none of those probes.
Native import checks cover metadata invalidation, rebinding and retained bytes
after importing a source used by a differently named symlink.
