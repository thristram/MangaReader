# 0012 — Indexed collections and bounded media loading

Accepted: 2026-10-14.

Collection updates must not repeatedly traverse the library for each tile or decode covers on the UI actor. `LibraryCatalog` snapshot indexes provide entity/parent/visibility lookup; personal-state indexes live in `AppSession`. Metadata mutations invalidate them. Inherited NSFW state propagates through reverse references, including cycles.

Cancellation-aware permits bound fetching, decoding, cache checking and page transfers. Shared requests cancel when their last consumer leaves. ImageIO downsamples on a worker; Quick Look provides the system fallback. File promotion, serial manifest merging and snapshot serialization stay off the UI actor. Availability publication is batched.

Finder and direct SMB paths may have different Unicode representations. Reads preserve exact paths first. A missing-path response permits a read-only walk within the configured base folder using actual server names, accepting exact UTF-8 or one unique canonical equivalent. This does not change metadata, move files, widen the root or perform fuzzy matching. Other SMB errors retain their meaning.

No control-plane service or API/schema migration is added. See [implementation and validation](../apple/collection-loading-and-smb-paths-2026-10-14.md) for limits and device acceptance.
