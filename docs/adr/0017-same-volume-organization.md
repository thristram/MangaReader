# ADR 0017 — Same-volume organization without media-byte transfers

Status: Accepted · 2026-10-22. Supersedes the copy-before-commit implementation for
exclusive same-volume organization in ADR 0007; copy behavior remains for shared
or cross-volume sources.

## Context

Translation imports, page splits, image-translation commits, temporary-file
organization and language corrections were copying existing media and repeatedly
reading whole files for SHA verification. Planning also opened unrelated storage
bindings and dispatched one filesystem operation per page. Direct folder import
already used a faster move path.

A Finder-mounted SMB share tested here supports ordinary rename, but rejects
hard links and exclusive-rename flags. It changes file identifiers and modification
timestamps on rename. Those capabilities cannot be inferred from local APFS.

## Decision

Keep metadata and storage separate. A metadata-only chapter reassignment inherits
the selected comic's author and series, with the existing revision-checked API.
It does not move media. Explicit file commits remain the boundary for movement.

For file commits:

- Compare root/path metadata first and skip unchanged pages. Batch path planning
  off the UI actor, and use the shared-source index with chapter-wide exclusions
  to identify references in other chapters. Retained/duplicate sources remain copies.
- For an exclusive regular file on the destination device, record device/inode,
  size and modification time instead of reading its bytes. Stage with a hard link
  when supported. Links keep the source readable until metadata commits.
- Callers explicitly opting into rename must supply original metadata. Persist
  target publication intent before touching the source. If links are unsupported,
  rename the file, then immediately persist the actual target identity. Prefer
  the OS exclusive rename; a mounted SMB fallback coordinates both paths, checks
  target absence again and performs an ordinary filesystem rename. Coordination
  covers cooperating macOS clients; it is not a distributed lock against a separate
  NAS client manually writing the same target concurrently.
- An authorized move stages the current source object: require the same device,
  inode and size, and refresh timestamp-only changes before staging. NAS metadata
  access can advance mtime without replacing the file. This is not an immutable
  content snapshot. After publication, require the recorded identity strictly.
- On a successful rename, trust the filesystem operation to preserve the bytes;
  check the target's device/size and record its new inode/timestamps. Later recovery
  and finish require that exact published identity. This accommodates SMB-generated
  identifiers without accepting arbitrary same-sized files during recovery.
- Shared originals, cross-device transfers and callers without rename authorization
  retain independent verified copies and full SHA checks. Generated translation
  cache files and externally added images remain copies.
- Checkpoint link operations in batches. Checkpoint renamed files immediately,
  because SMB can change their identity. Update metadata with its expected revision,
  verify published files, remove any remaining exclusive originals, then remove
  only explicitly planned empty source directories.
- Route language-folder corrections through the same executor. Include sidecar
  files, nested/empty destination folders and bounded source-folder cleanup.
  Reject source symlinks and existing destination directories.

## Recovery and compatibility

Renamed sources can be absent before the API write succeeds. The destination
contains the media; File Management Queue resumes the persisted operation rather
than importing or copying it again. A failed API write never authorizes deleting
an unrelated source or target. Shared sources retain their originals.

Journal identity, rename authorization and destination-folder fields are optional.
Old journals still use their original SHA verification. New plans persist an
original metadata snapshot. No API or database migration is required. Complete
new pending work before downgrading to a build without these journal fields.

An abrupt interruption between an SMB rename and its immediate identity checkpoint,
or a remount that changes device/file identity, can require manual review. Recovery
fails closed on an identity mismatch; it does not infer success from filename or
size alone. Existing-file collision checks and filesystem-root/account checks remain.

## Verification

See [fixes and measured checks](../apple/chapter-reassignment-and-organization-2026-10-22.md).

## Extension — all commit paths (2026-10-31)

Translation imports, Additional Pages, generated image translations, page splits,
media-language corrections and temporary-file organization share the organization
executor. Keep exclusive same-volume media on its existing link/authorized-rename
path; never turn retained originals into links merely to improve speed.

- Independent copies retain a source SHA and verify the copied temporary file by
  SHA. Optional `copySourceIdentity` and `publishedCopyIdentity` avoid subsequent
  full-byte rereads while the exact file object remains unchanged. If either
  identity changes, fall back to the recorded SHA. On NAS reads that advance mtime,
  require two equal inventories on the same device/inode/size before recording a
  fresh source identity. Content changes still fail verification.
- Chapter/version/page deletion uses same-volume rename into Recycle with optional
  source `identity` and `publishedIdentity`, without reading media bytes. Verify
  the exact source before rename and record the actual published identity. Legacy
  or unsupported/cross-volume entries retain SHA verification. Preserve rollback,
  shared-reference exclusions, bounded empty-folder cleanup and collision checks.
- Validate each unique Recycle root once per phase. Move deletion preflight and
  shared-source canonicalization off the UI actor. Resolve selected candidates by
  parent directory rather than resolving the same ancestors once per page.
- Mutation paths use one component walk, rejecting symlinks and invalid components;
  stop filesystem probes after the first missing suffix component. No path safety
  result is cached across commits.
- Keep an actor-owned index of completed/rolled-back journal file identities. Skip
  parsing unchanged completed bodies on repeated scans, always reread pending
  records, refresh changed/replaced history and evict entries outside the current
  scan. This cache is a scan optimization, never authority to resume an operation.

The new identity fields are optional; existing journals retain their old SHA path.
No server/API/metadata schema changes are required. The recovery limits above still
apply, including the SMB rename/checkpoint interruption gap. Complete new pending
operations before downgrading the app. NAS performance depends on filesystem
metadata and journal latency even when no media bytes need copying.
