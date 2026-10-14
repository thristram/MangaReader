import AppKit
import Foundation
import MangaCore
import SwiftUI

@main @MainActor struct WelcomeStateChecks {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }
  static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
  static func main() throws {
    let defaults = UserDefaults.standard
    defaults.set("https://obsolete.invalid", forKey: "MangaAPIURL")
    defaults.set("https://obsolete.invalid/resource", forKey: "MangaAPIAudience")
    defaults.set(false, forKey: "ShowNSFW")
    defer {
      for key in ["MangaAPIURL", "MangaAPIAudience", "ShowNSFW"] {
        defaults.removeObject(forKey: key)
      }
    }
    expect(
      AppConfiguration.current().apiURL.absoluteString == Bundle.main.object(
        forInfoDictionaryKey: "MangaAPIURL") as? String,
      "obsolete runtime URL must not override project config")
    expect(
      AppConfiguration.current().audience == Bundle.main.object(
        forInfoDictionaryKey: "MangaAPIAudience") as? String,
      "obsolete audience must not override project config")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.finishLaunching()
    let session = AppSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    let hosting = NSHostingController(rootView: MangaRootScreen(session: session, library: library))
    hosting.sizingOptions = []
    let window = NSWindow(contentViewController: hosting)
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 1200, height: 800))
    _ = hosting.view
    drain()
    expect(library.canManage, "Mac manager scope must enable editing")
    expect(library.collection(.library).count == 6, "NSFW work must be hidden")
    expect(library.collection(.history).count == 2, "history must contain chapters with progress")
    expect(
      library.collection(.continuing).count == 1,
      "completed chapters must not appear in Continue Reading")
    expect(
      library.children(session.entities.first { $0.id == "w0" }!).count == 2,
      "comic detail must list its chapters")
    library.query = "Haruka"
    expect(library.collection(.library).count == 2, "search must match authors")
    library.query = ""
    library.selectedTag = "t0"
    expect(library.collection(.library).count == 2, "tag filtering must select matching works")
    library.selectedTag = nil
    library.path = [.entity("w0"), .entity("c0-0")]
    drain()
    library.navigateBack()
    drain()
    expect(
      library.path == [.entity("w0")] && library.forwardPath == [.entity("c0-0")],
      "native back gesture must retain forward history")
    library.navigateForward()
    drain()
    expect(
      library.path == [.entity("w0"), .entity("c0-0")] && library.forwardPath.isEmpty,
      "forward gesture must restore the popped route")
    // Regression: the first native page must fill the actual viewport, not its
    // hosting controller's initial ideal size, and must follow window resizing.
    let media = session.entities.first { $0.id == "c0-0" }!.media[0]
    let imageURL = library.cachedURLs(media)![0]
    let pager = NSHostingController(
      rootView:
        MacReaderPager(index: .constant(0), count: 1) { _ in
          AnyView(
            NativeReadingPage(url: imageURL, onSwipe: { _ in })
              .frame(maxWidth: .infinity, maxHeight: .infinity))
        })
    pager.sizingOptions = []
    let readerWindow = NSWindow(contentViewController: pager)
    readerWindow.isReleasedWhenClosed = false
    readerWindow.setContentSize(NSSize(width: 1200, height: 800))
    readerWindow.orderFront(nil)
    drain()
    func viewport(in view: NSView) -> MacReadingViewport? {
      if let viewport = view as? MacReadingViewport { return viewport }
      for child in view.subviews { if let result = viewport(in: child) { return result } }
      return nil
    }
    let firstViewport = viewport(in: pager.view)
    expect(firstViewport != nil, "native pager must mount an image viewport")
    expect(firstViewport!.bounds.height > 750, "first page must fill the window height")
    expect(
      abs(firstViewport!.image.frame.height - firstViewport!.bounds.height) < 1,
      "image must fit viewport height")
    readerWindow.setContentSize(NSSize(width: 900, height: 500))
    drain()
    expect(
      abs(firstViewport!.bounds.height - pager.view.bounds.height) < 1,
      "native page must resize with its window")
    readerWindow.close()

    let chapter = session.entities.first { $0.id == "c0-0" }!
    library.reader = ReadingContext(
      chapter: chapter, version: chapter.media[0], urls: library.cachedURLs(chapter.media[0])!,
      page: 3)
    library.editor = .init(entity: chapter, kind: .chapter)
    library.path = [.entity("w0")]
    drain()
    var next = session.account!
    next.ownerId = "another-fixture-owner"
    session.account = next
    drain()
    expect(
      library.reader == nil && library.editor == nil && library.path.isEmpty,
      "account change must dismiss private presentations and clear navigation")
    session.account = nil
    drain()
    expect(
      !library.canManage && library.reader == nil,
      "signed-out app must not offer management/readers")
    session.login()
    drain()
    expect(
      session.account == nil && !session.busy
        && session.status == "Sign-in is not configured for this build.",
      "unconfigured sign-in must fail locally and remain retryable")
    window.close()
    print(
      "PASS: native pager first layout/resize; SwiftUI account gating/reset; NSFW, history, collections, author search and tag filters; build endpoint policy; retryable sign-in error. No server calls."
    )
  }
}
