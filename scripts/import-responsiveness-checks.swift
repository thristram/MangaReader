import AppKit
import Foundation
import MangaCore
import SwiftUI

@MainActor enum ImportResponsivenessChecks {
  static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw LoginError.server("Import response check: " + message) }
  }
  static func fields(in view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
  }
  static func scroll(in view: NSView) -> NSScrollView? {
    if let view = view as? NSScrollView { return view }
    return view.subviews.lazy.compactMap { scroll(in: $0) }.first
  }
  static func scrolls(in view: NSView) -> [NSScrollView] {
    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrolls(in: $0) }
  }
  static func dropHost(in view: NSView) -> ImportDropHostingView? {
    (view as? ImportDropHostingView) ?? view.subviews.lazy.compactMap { dropHost(in: $0) }.first
  }
  static func run(directory: URL) async throws {
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    let work = session.entities.first { $0.id == "w0" }!
    let source = directory.appendingPathComponent("Batch")
    let original = try library.local.urls(
      for: session.entities.first { $0.id == "c0-0" }!.media[0])[0]
    let bytes = try Data(contentsOf: original)
    for index in 0..<30 {
      let chapter = source.appendingPathComponent("Import-\(index)")
      try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
      for page in 1...8 { try bytes.write(to: chapter.appendingPathComponent("\(page).png")) }
    }
    let destination = directory.appendingPathComponent("Archive")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let root = try await session.create(
      .init(kind: .storageRoot, title: "Archive", storageKind: "local"))
    try library.local.bind(root, to: destination)
    let model = ImportWorkspaceModel(library: library)
    let hosting = NSHostingController(
      rootView: ImportWorkspace(library: library, model: model)
        .environmentObject(library).environmentObject(session))
    hosting.sizingOptions = []
    let window = NSWindow(contentViewController: hosting)
    window.isReleasedWhenClosed = false
    defer {
      window.close()
      library.reset()
    }
    window.setContentSize(NSSize(width: 1050, height: 850))
    _ = hosting.view
    try await Task.sleep(for: .milliseconds(100))
    hosting.view.layoutSubtreeIfNeeded()
    guard let host = dropHost(in: hosting.view) else {
      throw LoginError.server("Native import drop host did not appear")
    }
    try expect(
      host.bounds.width > 1000 && host.bounds.height > 800,
      "empty import does not fill its available page")
    model.append([source])
    model.input.authorId = work.authorId
    model.input.workId = work.id
    model.destinationId = root.id
    try await Task.sleep(for: .milliseconds(150))
    hosting.view.layoutSubtreeIfNeeded()
    let nativeScrolls = scrolls(in: hosting.view)
    guard let review = nativeScrolls.max(by: { $0.bounds.width < $1.bounds.width }),
      let queue = nativeScrolls.first(where: {
        $0.bounds.width > 120 && $0.bounds.width < 190
          && $0.bounds.height > 300
      }),
      let strip = nativeScrolls.first(where: {
        $0.bounds.height < 110 && $0.bounds.width > 200
          && ($0.documentView?.bounds.width ?? 0) > $0.bounds.width
      })
    else { throw LoginError.server("Review, right queue or horizontal page strip did not appear") }
    let reviewFrame = review.convert(review.bounds, to: hosting.view)
    let queueFrame = queue.convert(queue.bounds, to: hosting.view)
    try expect(
      queueFrame.minX >= reviewFrame.maxX - 1,
      "folder queue is not a single column on the right")
    let footerSpace =
      hosting.view.isFlipped
      ? hosting.view.bounds.maxY - reviewFrame.maxY : reviewFrame.minY - hosting.view.bounds.minY
    try expect(
      footerSpace >= 50 && footerSpace < 150,
      "review scroll view does not reserve a fixed bottom action area: \(footerSpace)")
    strip.contentView.scroll(to: NSPoint(x: 4 * 63, y: 0))
    strip.reflectScrolledClipView(strip.contentView)
    try await Task.sleep(for: .milliseconds(50))
    try expect(
      strip.contentView.bounds.minX > 0, "thumbnail strip cannot scroll past its first pages")
    review.contentView.scroll(to: NSPoint(x: 0, y: 300))
    review.reflectScrolledClipView(review.contentView)
    try await Task.sleep(for: .milliseconds(50))
    try expect(
      review.convert(review.bounds, to: hosting.view) == reviewFrame,
      "scrolling changes the fixed review/footer boundary")
    host.targeted(true)
    try await Task.sleep(for: .milliseconds(150))
    try expect(
      host.bounds.width > 1000 && host.bounds.height > 800,
      "drag feedback shrinks the full-page native drop destination")
    host.targeted(false)
    try await Task.sleep(for: .milliseconds(150))
    model.enqueue(move: true)
    for _ in 0..<500 {
      if library.fileQueue.items.first?.completed == true
        || library.fileQueue.items.first?.failed == true
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    try expect(
      library.fileQueue.items.first?.completed == true,
      "real file commit failed: \(library.fileQueue.items.first?.status ?? "no result")")
    try expect(model.queue.count == 29, "import queue lost other chapters")
    let clones = (0..<2000).map { index in
      var row = work
      row.id = "search-work-\(index)"
      row.title = "Search Comic \(index)"
      return row
    }
    session.entities += clones
    try await Task.sleep(for: .milliseconds(100))
    hosting.view.layoutSubtreeIfNeeded()
    let comicFields = fields(in: hosting.view).filter {
      $0.placeholderString == "Search or create a comic"
    }
    try expect(comicFields.count == 1, "adaptive import creates duplicate Comic inputs")
    guard let field = comicFields.first, let scrolling = scroll(in: hosting.view) else {
      throw LoginError.server("Native import controls did not appear")
    }
    let start = Date()
    for index in 0..<15 {
      _ = window.makeFirstResponder(field)
      scrolling.contentView.scroll(to: NSPoint(x: 0, y: index % 2 == 0 ? 200 : 0))
      scrolling.reflectScrolledClipView(scrolling.contentView)
      _ = window.makeFirstResponder(nil)
      hosting.view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
    let elapsed = Date().timeIntervalSince(start)
    try expect(elapsed < 4, "focus/scroll blocked after commit: \(elapsed)s")
    for width in [486.0, 760.0, 1050.0] {
      window.setContentSize(NSSize(width: width, height: 850))
      try await Task.sleep(for: .milliseconds(50))
      hosting.view.layoutSubtreeIfNeeded()
      try expect(
        fields(in: hosting.view).filter { $0.placeholderString == "Search or create a comic" }.count
          == 1,
        "resize creates a second search form")
    }
    let searchStart = Date()
    for _ in 0..<1000 {
      _ = session.catalog.search(kind: .work, query: "", limit: 7, showNSFW: false)
    }
    try expect(Date().timeIntervalSince(searchStart) < 1, "empty dropdown scans the full catalog")
    print(
      String(
        format:
          "PASS: full empty drop host; right folder queue; fixed footer allocation; horizontal thumbnail scrolling; full-page drag destination. Native import after real commit; 30 folders; 2,000 comic choices; single form at narrow/wide widths; 15 focus/scroll cycles %.0f ms; bounded dropdown search.",
        elapsed * 1000))
  }
}
