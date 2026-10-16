# ADR 0010: Retain source grants across import owners

Status: accepted, 2026-10-14.

## Context

An import may outlive its review screen, wait behind other file jobs, or fail and
retry after its worker has closed. Finder drop URLs and system file-picker
selections enter through different native callbacks. Creating a bookmark only
after asynchronous metadata writes and reacquiring scopes independently on each
retry makes authorization depend on callback and UI lifetime.

## Decision

Read Finder drop URLs through the native drag pasteboard. Capture each selected
source's app-scoped bookmark while its callback owns access. A shared immutable
`ImportSourceAccess` owns that URL, bookmark and one balanced security-scope
lifetime. The import workspace, background queue and failed-job retry retain it
as needed. Persist its captured bookmark when binding a source root. Descendant
chapters reference the selected ancestor and full relative paths.

For a standalone PDF/MP4/WebM selection, retain and persist the file bookmark,
not a bookmark to its unselected parent. Each selected file has an independent
source binding. LocalMedia retains the actual scoped resource separately from
the logical directory used to resolve media-relative filenames; scope cleanup
stops the resource that was actually started. Existing directory bookmarks keep
their original behavior. See [single-file regression](../apple/single-file-import-2026-10-15.md).

Queue cancellation and account reset release retained grants. Successful jobs
release their queue ownership. Failed jobs retain the original grant and metadata
snapshot for Retry. A separately signed sandbox preview tests the same
entitlements as the real Mac app without using its account or container.

## Consequences

Closing the import UI no longer controls a queued job's source access. Failed jobs
hold access until retry or cancellation, so queue lifecycle cleanup must remain
part of sign-out/reset. The operating system still enforces permissions and NAS
availability. This does not create new entitlements or bypass genuine access
denials. Existing journal recovery remains necessary for failures after file
movement. In-memory retry state is not a promise of retry persistence across app
relaunch.

See [verification and limits](../apple/import-access-and-translation-2026-10-14.md).
