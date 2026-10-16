# ADR 0011 — Native iPhone paging and whole-page minimum zoom

Status: Accepted, 2026-10-14. Refines ADR 0009's reader adapter and READ-01 for iPhone.

The iPhone reader cropped wide images at minimum zoom because it scaled every
page to screen height. The inner scroll view then competed with page navigation,
and automatic safe-area adjustments left a band above the media. The user
requested complete images at minimum zoom and Photos-like interaction.

Use a horizontally paged UICollectionView inside the SwiftUI reader. UIKit owns
finger tracking, settling, bounce and cancellation. Retain
the visible/adjacent hosting controllers and publish interactive selection only
after a completed transition. Keep the canonical page counter and language
alignment in the shared screen; provide its account-scoped environment explicitly
to hosted content. Version/revision changes refresh the page hosts.

Use whole-page aspect fit as image/PDF minimum scale on iPhone. Image pinch and
double-tap zoom use UIScrollView; PDFKit retains PDF zoom. Inner pan yields to
page navigation at fit scale and handles pan above that scale. Disable automatic
scroll insets/media-host safe-area additions. Expand the media canvas beneath
system bars, and measure safe areas separately for overlay controls. Hiding
controls also hides status/system overlays. Aspect-ratio letterboxing remains
necessary to display complete pages. Mac's height-fit default is unchanged.

Consequences: the iPhone reader's pager is a UIKit adapter; other screens remain
SwiftUI and no storyboard is introduced. Only a few pages are hosted at once.
NAS latency can still require a loading state; smooth native transitions do not
imply that remote media is already downloaded. Verify actual UIKit layout and
state transitions with synthetic offline media; physical-device frame pacing is
a separate acceptance check.

See [verification](../apple/iphone-reader-fit-and-paging-2026-10-14.md) and Apple's
[UICollectionView](https://developer.apple.com/documentation/uikit/uicollectionview),
[scroll inset behavior](https://developer.apple.com/documentation/uikit/uiscrollview/contentinsetadjustmentbehavior-swift.property)
and [hosting safe-area regions](https://developer.apple.com/documentation/swiftui/uihostingcontroller/safearearegions).
