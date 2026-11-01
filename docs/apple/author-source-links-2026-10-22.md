# Author source links on Mac and iPhone

Author links are now available in three shared native screens:

1. **Preview → … → Info** shows the author name, optional localized description,
   and a direct link for each configured source, above the existing file location.
2. **Comic detail** shows the author's sources beside the author name.
3. **Authors** shows each author's source links under their row. Source taps are
   independent from the author-detail navigation link.

Each website name is directly clickable; there is no extra source-selection menu.
Links use the system URL opener. Horizontal scrolling keeps multiple websites
accessible in narrow layouts. iPhone links have at least a 44-point touch height.
Authors without configured valid links still show their name without empty buttons.

Source URLs use the existing saved author metadata. Pixiv IDs resolve to `/users/`
for authors and `/artworks/` for comic sources; FANBOX creator IDs resolve to the
creator subdomain. Complete HTTPS URLs retain their path, query and fragment.
Patreon and E-Hentai retain the existing source-route handling. Author lookup uses
current metadata and falls back through the comic/Series when needed. Deleted or
hidden authors are not exposed by these links.

No server changes, environment variables, database migration or storage moves are
needed. Edit author source links on Mac; synced metadata supplies the same buttons
on iPhone.

## Verification

Source URL tests cover author/post routing, explicit HTTPS URLs, empty/unsupported
values and provider labels. The isolated preview uses synthetic author sources.
`python3 scripts/preview-native-ui.py mac --capture-links` or `phone --capture-links`
captures taps in its fixture directory's `captured-source-url.txt`; it does not open
external sites. This flag affects only preview entrypoints, never production apps.

Native checks validate that comic and reader attribution resolve the same author
and use the author-profile URL route. GUI checks and final build results are recorded
in [verification](../verification.md).

Final validation: both app targets build; core tests execute 69 cases with zero
failures and one existing second-volume skip; full native synthetic regressions
pass. Actual Mac and iPhone Simulator taps in all three requested locations
captured the expected Pixiv/FANBOX/Patreon URLs. This verifies URL dispatch and UI
placement; it does not certify the external services' availability.
