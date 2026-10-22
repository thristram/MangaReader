// Simulator-only lifecycle/race regressions with synthetic pages.
import MangaCore
import SwiftUI
import UIKit

@MainActor enum PhonePagingStressChecks {
  static func run(window: UIWindow, session: AppSession, library: LibraryUIModel) async throws {
    let parent = PhoneReaderPageController()
    let first = PhoneReaderPageHost(index: 0, content: AnyView(Color.red))
    let next = PhoneReaderPageHost(index: 1, content: AnyView(Color.blue))
    let oldCell = PhoneReaderCell(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let newCell = PhoneReaderCell(frame: oldCell.frame)
    oldCell.attach(first, to: parent, gap: 16)
    newCell.attach(first, to: parent, gap: 16)
    oldCell.detach()
    try PhoneReaderChecks.expect(first.view.superview === newCell.contentView && first.parent === parent,
      "Late old-cell teardown removes the new page's hosted view (persistent black page)")
    newCell.attach(next, to: parent, gap: 16)
    // An end-display event can arrive after the same cell was reused for another index.
    parent.collectionView(parent.collectionView, didEndDisplaying: newCell, forItemAt: IndexPath(item: 0, section: 0))
    try PhoneReaderChecks.expect(next.view.superview === newCell.contentView,
      "Old index callback detaches the cell's newer page")
    newCell.detach()

    let bitmap = PhoneReaderChecks.image(CGSize(width: 120, height: 240), title: "REUSE").cgImage!
    let pages = PhoneReaderPageController()
    window.rootViewController = pages
    var dismissed = 0
    var drag: CGFloat = 0
    pages.onDismiss = { dismissed += 1 }
    pages.onDismissDrag = { drag = $0 }
    pages.configure(index: 0, count: 200, rightToLeft: false, contentID: "stress") { index in
      AnyView(NativeReadingPage(url: URL(fileURLWithPath: "/synthetic/\(index).png"), onSwipe: { _ in },
        decode: { _, _ in
          try await Task.sleep(for: .milliseconds(60))
          return .image(bitmap)
        }))
    }
    pages.view.layoutIfNeeded()
    for index in Array(1...50) + Array((0...50).reversed()) {
      pages.collectionView.setContentOffset(CGPoint(x: CGFloat(index) * pages.pageStride, y: 0), animated: false)
      pages.collectionView.layoutIfNeeded()
      pages.scrollViewDidEndDecelerating(pages.collectionView)
      try await Task.sleep(for: .milliseconds(4))
      try PhoneReaderChecks.expect(pages.cachedPages.count <= 5, "Rapid paging retains distant decoded pages")
    }
    try await PhoneReaderChecks.wait("Rapid swiping leaves the returned page permanently black") {
      pages.visibleHost.map { PhoneReaderChecks.find(PhoneReadingViewport.self, in: $0.view)?.image.image != nil } == true
    }
    // Revisit pages whose first decode was cancelled while offscreen.
    for index in [1, 2, 1, 0, 49, 50, 49] {
      pages.collectionView.setContentOffset(CGPoint(x: CGFloat(index) * pages.pageStride, y: 0), animated: false)
      pages.collectionView.layoutIfNeeded()
      pages.scrollViewDidEndDecelerating(pages.collectionView)
      do {
        try await PhoneReaderChecks.wait("Previously cancelled page \(index) stays black") {
          pages.visibleHost.map { PhoneReaderChecks.find(PhoneReadingViewport.self, in: $0.view)?.image.image != nil } == true
        }
      } catch {
        let detail = "visible=\(pages.visibleIndex) cache=\(pages.cachedPages.keys.sorted()) offset=\(pages.collectionView.contentOffset) cells=\(pages.collectionView.visibleCells.map { (pages.collectionView.indexPath(for: $0)?.item, ($0 as? PhoneReaderCell)?.pageIndex) }) hostParent=\(String(describing: pages.visibleHost?.parent)) hostWindow=\(String(describing: pages.visibleHost?.view.window)) attached=\(pages.visibleHost?.attachedCell != nil)"
        throw NSError(domain: "PagingStress", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription + ": " + detail])
      }
    }
    try PhoneReaderChecks.expect(pages.shouldBeginDismissal(velocity: CGPoint(x: 10, y: 500)), "Downward drag cannot dismiss at fit zoom")
    try PhoneReaderChecks.expect(!pages.shouldBeginDismissal(velocity: CGPoint(x: 500, y: 20))
      && !pages.shouldBeginDismissal(velocity: CGPoint(x: 0, y: -500)), "Horizontal/upward drag accidentally dismisses")
    let viewport = PhoneReaderChecks.find(PhoneReadingViewport.self, in: pages.visibleHost!.view)!
    viewport.scroll.setZoomScale(2, animated: false)
    try PhoneReaderChecks.expect(!pages.shouldBeginDismissal(velocity: CGPoint(x: 0, y: 500)), "Zoomed image pan dismisses the reader")
    viewport.scroll.setZoomScale(1, animated: false)
    pages.updateDismissal(translation: CGPoint(x: 0, y: 30), velocity: .zero, state: .changed)
    try PhoneReaderChecks.expect(drag == 30, "Dismissal does not follow the finger")
    pages.updateDismissal(translation: CGPoint(x: 0, y: 30), velocity: .zero, state: .ended)
    try PhoneReaderChecks.expect(drag == 0 && dismissed == 0, "Short dismissal does not spring back")
    pages.updateDismissal(translation: CGPoint(x: 0, y: 120), velocity: .zero, state: .ended)
    try PhoneReaderChecks.expect(dismissed == 1, "Long downward swipe does not dismiss")

    // Exercise the actual lazy cover collection, including repeated reversals and
    // memory pressure while async thumbnails are starting/cancelling.
    let original = session.entities
    defer { session.entities = original }
    let seed = original.first { $0.id == "c0-0" }!
    let items = (0..<700).map { index in
      var chapter = seed; chapter.id = "scroll-stress-\(index)"; return chapter
    }
    session.entities += items
    let grid = UIHostingController(rootView: ScrollView { ComicGrid(entities: items).padding() }
      .environmentObject(library).environmentObject(session))
    window.rootViewController = grid
    try await PhoneReaderChecks.wait("Stress collection did not mount") {
      PhoneReaderChecks.find(UIScrollView.self, in: grid.view) != nil
    }
    let scroll = PhoneReaderChecks.find(UIScrollView.self, in: grid.view)!
    for index in 0..<100 {
      let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
      let fraction = CGFloat((index * 17) % 100) / 100
      scroll.setContentOffset(CGPoint(x: 0, y: maxY * fraction), animated: false)
      scroll.layoutIfNeeded()
      if index % 10 == 0 {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
      }
      try await Task.sleep(for: .milliseconds(8))
    }
    window.rootViewController = UIViewController()
    print("PASS: ownership-safe page transfer, delayed reuse callbacks, 100 rapid page changes/cancelled decodes, bounded page hosts; downward dismissal/cancel/zoom isolation; 700-tile native collection with 100 fast reversals and memory pressure.")
  }
}
