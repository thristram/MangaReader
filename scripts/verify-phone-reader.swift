// Isolated simulator app only. Never included in the production targets.
import MangaCore
import PDFKit
import SwiftUI
import UIKit

@main final class PhoneAppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting sceneSession: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    UISceneConfiguration(name: "Default", sessionRole: sceneSession.role)
  }
}
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    self.window = window
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
    Task { await PhoneReaderChecks.run(window) }
  }
}

@MainActor enum PhoneReaderChecks {
  static let result = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("phone-reader-checks.txt")
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "PhoneReaderChecks", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
  }
  static func wait(_ message: String, until ready: () -> Bool) async throws {
    for _ in 0..<250 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    try expect(false, message)
  }
  static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { find(type, in: $0) }.first
  }
  static func pager(in controller: UIViewController) -> PhoneReaderPageController? {
    if let match = controller as? PhoneReaderPageController { return match }
    if let presented = controller.presentedViewController, let match = pager(in: presented) { return match }
    return controller.children.lazy.compactMap { pager(in: $0) }.first
  }
  static func tabs(in controller: UIViewController) -> UITabBarController? {
    if let match = controller as? UITabBarController { return match }
    return controller.children.lazy.compactMap { tabs(in: $0) }.first
  }
  static func tabControls(in view: UIView) -> [UIControl] {
    guard !view.isHidden && view.alpha > 0.01 else { return [] }
    if let control = view as? UIControl, control.bounds.width > 20 { return [control] }
    return view.subviews.flatMap { tabControls(in: $0) }
  }
  static func savedCollectionChecks(_ session: AppSession, _ model: LibraryUIModel) throws {
    let entities = session.entities
    let states = session.states
    defer {
      session.entities = entities
      session.states = states
      model.query = ""
      model.selectedTag = nil
      model.unreadOnly = false
      model.sort = .updated
    }
    try expect(model.savedPages().map(\.id) == ["p5"],
               "A page with both marks appears twice, or chapter marks leak into Saved Pages")
    try expect(model.collection(.starred).contains { $0.id == "w2" }, "Starred comic is missing")
    try expect(!model.collection(.starred).contains { $0.id == "c0-0" },
               "A starred page incorrectly appears as a starred chapter")
    model.query = "no such saved page"
    try expect(model.savedPages().isEmpty, "Saved page search does not filter")
    model.query = ""
    model.selectedTag = "t0"
    try expect(model.savedPages().count == 1, "Saved pages ignore inherited tags")
    model.selectedTag = "t1"
    try expect(model.savedPages().isEmpty, "Saved page tag filter has no effect")
    model.selectedTag = nil
    let index = session.states.firstIndex { $0.id == "p1" }!
    session.states[index].progress?.completed = true
    model.unreadOnly = true
    try expect(model.savedPages().isEmpty, "Completed chapters ignore the unread filter")
    model.unreadOnly = false
    let work = session.entities.firstIndex { $0.id == "w0" }!
    session.entities[work].nsfw = true
    try expect(model.savedPages().isEmpty, "Saved pages expose hidden parent media")
  }
  static func image(_ size: CGSize, title: String) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.systemIndigo.setFill(); context.fill(CGRect(origin: .zero, size: size))
      UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: size.height))
      UIColor.systemOrange.setFill(); context.fill(CGRect(x: size.width - 24, y: 0, width: 24, height: size.height))
      UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: size.width, height: 24))
      UIColor.systemYellow.setFill(); context.fill(CGRect(x: 0, y: size.height - 24, width: size.width, height: 24))
      (title as NSString).draw(at: CGPoint(x: 45, y: size.height / 2), withAttributes: [
        .foregroundColor: UIColor.white, .font: UIFont.boldSystemFont(ofSize: 30)])
    }
  }
  static func run(_ window: UIWindow) async {
    do {
      try? FileManager.default.removeItem(at: result)
      let viewport = PhoneReadingViewport(frame: window.bounds)
      for size in [CGSize(width: 1800, height: 600), CGSize(width: 600, height: 3000), CGSize(width: 600, height: 1100)] {
        viewport.set(content: .image(image(size, title: "FIT CHECK").cgImage!))
        viewport.layoutIfNeeded()
        let fitted = viewport.image.convert(viewport.image.bounds, to: viewport)
        try expect(viewport.bounds.insetBy(dx: -0.5, dy: -0.5).contains(fitted), "Minimum zoom crops image \(size): \(fitted)")
        try expect(viewport.scroll.contentInsetAdjustmentBehavior == .never, "Unexpected safe-area image inset")
        try expect(!viewport.scroll.gestureRecognizerShouldBegin(viewport.scroll.panGestureRecognizer), "Fit image consumes paging drag")
        viewport.scroll.setZoomScale(2, animated: false)
        viewport.setNeedsLayout(); viewport.layoutIfNeeded()
        try expect(viewport.scroll.zoomScale == 2, "Layout resets user zoom")
        try expect(viewport.scroll.contentSize.width > fitted.width, "Image does not actually zoom")
        viewport.frame.size = CGSize(width: window.bounds.height, height: window.bounds.width)
        viewport.layoutIfNeeded()
        let rotated = viewport.image.convert(viewport.image.bounds, to: viewport)
        try expect(viewport.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rotated), "Resize crops image")
        viewport.frame = window.bounds
      }
      for size in [CGSize(width: 1800, height: 600), CGSize(width: 600, height: 1800)] {
        let document = PDFDocument(); document.insert(PDFPage(image: image(size, title: "PDF FIT"))!, at: 0)
        viewport.set(content: .pdf(document)); viewport.layoutIfNeeded()
        let pdf = viewport.pdf!
        let box = pdf.currentPage!.bounds(for: pdf.displayBox)
        try expect(pdf.scaleFactor > 0 && box.width * pdf.scaleFactor <= viewport.bounds.width + 1
          && box.height * pdf.scaleFactor <= viewport.bounds.height + 1, "Minimum zoom crops PDF")
        try expect(abs(pdf.scaleFactor - pdf.minScaleFactor) < 0.01, "PDF minimum scale is not fit")
        pdf.scaleFactor = pdf.minScaleFactor * 2
        viewport.setNeedsLayout(); viewport.layoutIfNeeded()
        try expect(pdf.scaleFactor > pdf.minScaleFactor * 1.5, "Layout resets PDF user zoom")
      }

      let pages = PhoneReaderPageController()
      pages.view.frame = window.bounds
      var settled: [Int] = []
      pages.onPageSettled = { settled.append($0) }
      pages.configure(index: 0, count: 1000, rightToLeft: false, contentID: "test") { AnyView(Text("\($0)")) }
      pages.scrollViewWillBeginDragging(pages.collectionView)
      pages.collectionView.contentOffset.x = pages.pageStride * 0.2
      try expect(settled.isEmpty && pages.visibleIndex == 0, "Partial drag changes selection")
      pages.collectionView.contentOffset = .zero
      pages.scrollViewDidEndDragging(pages.collectionView, willDecelerate: false)
      try expect(settled.isEmpty && pages.visibleIndex == 0, "Cancelled drag changes selection")
      pages.scrollViewWillBeginDragging(pages.collectionView)
      pages.collectionView.setContentOffset(CGPoint(x: pages.pageStride, y: 0), animated: false)
      pages.scrollViewDidEndDecelerating(pages.collectionView)
      try expect(settled == [1] && pages.visibleIndex == 1, "Completed drag does not publish selection")
      try expect(pages.cachedPages.count <= 3, "Pager retains a whole chapter")
      pages.configure(index: 1, count: 3, rightToLeft: true, contentID: "rtl") { AnyView(Text("\($0)")) }
      try expect(pages.position(for: 2) == 0 && pages.position(for: 0) == 2, "RTL order")
      pages.collectionView.setContentOffset(.zero, animated: false)
      pages.scrollViewDidEndDecelerating(pages.collectionView)
      try expect(pages.visibleIndex == 2, "RTL settled page")
      pages.configure(index: 0, count: 1, rightToLeft: false, contentID: "single") { AnyView(Text("\($0)")) }
      try expect(pages.collectionView.numberOfItems(inSection: 0) == 1 && pages.visibleIndex == 0, "Single-page bounds")

      // The full production reader and presentation, backed by synthetic API and
      // private offline downloads. No real account, NAS or production requests.
      UserDefaults.standard.set(false, forKey: "ReaderDescription")
      UserDefaults.standard.set("ltr", forKey: "ReaderDirection")
      let directory = result.deletingLastPathComponent().appendingPathComponent("fixtures")
      let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
      let model = try NativeUIFixtures.seed(session: session, directory: directory)
      try await CollectionLoadingChecks.run(directory: directory, session: session, library: model)
      try savedCollectionChecks(session, model)
      let chapter = session.entities.first { $0.id == "c0-0" }!
      model.mark(chapter, starred: true, page: 0)
      try expect(model.stateInput(chapter.id, page: 0)?.starred == true, "Star has no immediate feedback")
      model.mark(chapter, starred: true, page: 0)
      try expect(model.stateInput(chapter.id, page: 0)?.starred == false, "Rapid unstar ignores pending state")
      model.mark(chapter, starred: true, page: 0)
      try await wait("Page star did not persist") { model.state(chapter.id, page: 0)?.starred == true }
      session.states.removeAll { $0.entityId == chapter.id && $0.pageIndex == 0 }
      try await session.synchronize()
      try expect(model.state(chapter.id, page: 0)?.starred == true, "Page star was not restored by API sync")
      try expect(model.state(chapter.id)?.starred != true, "Page star accidentally starred its chapter")
      let version = chapter.media[0]
      let sizes = [window.bounds.size, CGSize(width: 1800, height: 600), CGSize(width: 600, height: 3000)]
      let urls = try version.relativePaths.enumerated().map { index, path in
        let url = directory.appendingPathComponent("media").appendingPathComponent(path)
        try image(sizes[index % sizes.count], title: ["EDGE TO EDGE", "WIDE PAGE", "LONG PAGE"][index % 3]).pngData()!.write(to: url)
        return url
      }
      // seed() already creates offline copies. Replace those fixture bytes too,
      // otherwise a valid manifest correctly keeps the original seeded images.
      for media in chapter.media {
        let download = session.cacheDirectory!.appendingPathComponent("downloads/" + media.id)
        for (index, path) in media.relativePaths.enumerated() {
          try Data(contentsOf: directory.appendingPathComponent("media").appendingPathComponent(path))
            .write(to: download.appendingPathComponent("\(index).png"))
        }
      }
      _ = try await model.smb.download(version, localURLs: urls)
      window.rootViewController = UIHostingController(rootView: MangaRootScreen(session: session, library: model))
      try await wait("Native tabs did not load") {
        tabs(in: window.rootViewController!)?.tabBar.items?.count == 5
      }
      try expect(tabs(in: window.rootViewController!)!.tabBar.items!.map(\.title) ==
                 ["Library", "Reading", "Offline", "Saved", "Authors"],
                 "Native tab order or labels differ from the requested five destinations")
      let tabBar = tabs(in: window.rootViewController!)!.tabBar
      tabBar.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      let controls = tabControls(in: tabBar)
      let widths = controls.map { $0.bounds.width }
      try expect(controls.count >= 5 && (widths.max()! - widths.min()!) <= 1,
                 "Native tab hit areas are not equal width: \(controls.map { "\(type(of: $0)) \($0.bounds)" })")
      model.open(chapter, page: 0)
      try await wait("Production reader did not load") {
        guard let pager = pager(in: window.rootViewController!), let host = pager.visibleHost else { return false }
        return find(PhoneReadingViewport.self, in: host.view)?.image.image != nil
      }
      let live = pager(in: window.rootViewController!)!
      let page = find(PhoneReadingViewport.self, in: live.visibleHost!.view)!
      let frame = page.convert(page.bounds, to: window)
      try expect(abs(frame.minY) < 1 && abs(frame.height - window.bounds.height) < 1, "Full-screen viewport leaves a top/bottom band: \(frame)")
      let imageFrame = page.image.convert(page.image.bounds, to: window)
      try expect(abs(imageFrame.minY) < 1, "Screen-aspect image starts below status bar: \(imageFrame)")
      // Exercise the SwiftUI binding -> representable -> UIKit path used by
      // buttons/thumbnail jumps, not just the data-source/delegate in isolation.
      try expect(!live.transitioning, "Reader is stuck in its initial transition")
      live.onPageSettled?(1)
      try await wait("Bound next-page request did not display the wide page") {
        guard live.visibleIndex == 1, !live.transitioning,
          let view = live.visibleHost?.view,
          let viewport = find(PhoneReadingViewport.self, in: view),
          let image = viewport.image.image else { return false }
        return image.size.width / image.size.height > 2.9
      }
      let wideFrame = live.visibleHost!.view.convert(live.visibleHost!.view.bounds, to: window)
      try expect(abs(wideFrame.minX) < 1 && abs(wideFrame.width - window.bounds.width) < 1,
                 "Selected host is offscreen after programmatic paging: \(wideFrame)")
      let wideViewport = find(PhoneReadingViewport.self, in: live.visibleHost!.view)!
      wideViewport.scroll.setZoomScale(2, animated: false)
      live.onPageSettled?(2)
      try await wait("Second bound page request did not display the long page") {
        guard live.visibleIndex == 2, !live.transitioning, let view = live.visibleHost?.view,
          let viewport = find(PhoneReadingViewport.self, in: view), let image = viewport.image.image else { return false }
        return image.size.width / image.size.height < 0.21
      }
      live.onPageSettled?(1)
      try await wait("Returning to the adjacent page did not reuse its loaded viewport") {
        live.visibleIndex == 1 && !live.transitioning
          && live.visibleHost.map { find(PhoneReadingViewport.self, in: $0.view) === wideViewport } == true
      }
      try expect(wideViewport.scroll.zoomScale == 2, "Returning to a loaded neighbour resets zoom")
      wideViewport.scroll.setZoomScale(1, animated: false)
      live.onPageSettled?(0)
      try await wait("Return to first page") { live.visibleIndex == 0 && !live.transitioning }
      let report = "PASS: five equal-width native tabs in order; Saved Pages/Starred membership separation; saved page search, inherited tags, unread and inherited NSFW filters. Wide/long/portrait image fit; pinch layout stability; resized fit; PDF fit and zoom; cancelled/completed paging; RTL/bounds; bounded controllers; consecutive bound page jumps; neighbour viewport/zoom reuse; production full-screen viewport and image reach screen top. 2,000-chapter index and bounded background cover loading/cancellation. Synthetic offline data only.\n"
      try report.write(to: result, atomically: true, encoding: .utf8)
      NSLog("%@", report)
    } catch {
      let report = "FAIL: " + error.localizedDescription
      try? report.write(to: result, atomically: true, encoding: .utf8)
      NSLog("%@", report)
    }
  }
}
