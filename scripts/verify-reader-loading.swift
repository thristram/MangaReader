import AppKit
import Foundation
import ImageIO
import MangaCore
import PDFKit
import SwiftUI

private final class DecodeGate: @unchecked Sendable {
  let started = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func block() throws {
    guard !Thread.isMainThread else { throw ReadingPageDecodingError.invalidImage }
    started.signal()
    guard release.wait(timeout: .now() + 10) == .success else {
      throw ReadingPageDecodingError.invalidImage
    }
  }
}

@main @MainActor struct ReaderLoadingChecks {
  static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }
  static func wait(_ message: String, until ready: () -> Bool) async throws {
    for _ in 0..<250 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    expect(false, message)
  }
  static func viewport(in view: NSView) -> MacReadingViewport? {
    if let viewport = view as? MacReadingViewport { return viewport }
    for child in view.subviews { if let result = viewport(in: child) { return result } }
    return nil
  }
  nonisolated static func pixels(_ width: Int, _ height: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }
  nonisolated static func png(_ image: CGImage, at url: URL) throws {
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ReadingPageDecodingError.invalidImage
    }
  }
  static func main() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.finishLaunching()

    let small = pixels(32, 64)
    let replacement = pixels(64, 32)
    let gate = DecodeGate()
    let slowURL = directory.appendingPathComponent("slow.png")
    let nextURL = directory.appendingPathComponent("next.png")
    let slowContent = DecodedReadingPage.image(small)
    let nextContent = DecodedReadingPage.image(replacement)
    let decode: @Sendable (URL, Int?) async throws -> DecodedReadingPage = { url, _ in
      try await FileTasks.perform {
        if url == slowURL {
          try gate.block()
          return slowContent
        }
        return nextContent
      }
    }
    let hosting = NSHostingController(
      rootView: NativeReadingPage(
        url: slowURL, onSwipe: { _ in }, decode: decode))
    hosting.sizingOptions = []
    let window = NSWindow(contentViewController: hosting)
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 1200, height: 800))
    window.orderFront(nil)
    defer { window.close() }
    try await wait("slow decode started on a worker") {
      gate.started.wait(timeout: .now()) == .success
    }
    expect(
      viewport(in: hosting.view) == nil, "loading phase must not mount a disk-reading viewport")
    var heartbeat = false
    Task { @MainActor in heartbeat = true }
    try await wait("main actor remains responsive during blocked file I/O") { heartbeat }

    hosting.rootView = NativeReadingPage(url: nextURL, onSwipe: { _ in }, decode: decode)
    try await wait("new page displays while old read is blocked") {
      viewport(in: hosting.view)?.image.image?.size.width == 64
    }
    gate.release.signal()
    try await Task.sleep(for: .milliseconds(100))
    expect(
      viewport(in: hosting.view)?.image.image?.size.width == 64,
      "late cancelled result must not overwrite the newer page")
    let view = viewport(in: hosting.view)!
    expect(view.bounds.height > 750, "decoded page fills native viewport height")
    window.setContentSize(NSSize(width: 900, height: 500))
    try await wait("decoded page follows window resizing") { abs(view.bounds.height - 500) < 1 }

    let imageURL = directory.appendingPathComponent("real.png")
    try png(small, at: imageURL)
    let decoded = try await ReadingPageDecoder.load(url: imageURL, pdfPage: nil)
    if case .image(let image) = decoded {
      expect(image.width == 32 && image.height == 64, "normal image keeps original dimensions")
    } else {
      expect(false, "decode PNG")
    }
    let largeURL = directory.appendingPathComponent("large.png")
    try await FileTasks.perform { try png(pixels(4800, 6400), at: largeURL) }
    let large = try await ReadingPageDecoder.load(url: largeURL, pdfPage: nil)
    if case .image(let image) = large {
      expect(
        Double(image.width * image.height) <= ReadingPageDecoder.maximumPixels,
        "oversized image decoded memory is bounded")
      expect(
        abs(Double(image.width) / Double(image.height) - 0.75) < 0.001,
        "downsampling preserves aspect ratio")
    } else {
      expect(false, "decode oversized PNG")
    }
    let pdfURL = directory.appendingPathComponent("chapter.pdf")
    let pdf = PDFDocument()
    pdf.insert(PDFPage(image: NSImage(cgImage: small, size: .zero))!, at: 0)
    pdf.insert(PDFPage(image: NSImage(cgImage: replacement, size: .zero))!, at: 1)
    expect(pdf.write(to: pdfURL), "write synthetic PDF")
    let page = try await ReadingPageDecoder.load(url: pdfURL, pdfPage: 1)
    if case .pdf(let document) = page {
      expect(
        document.pageCount == 1 && abs(page.aspect - 2) < 0.01,
        "PDF returns the requested single page and its aspect")
      let bitmap = document.page(at: 0)!.thumbnail(
        of: NSSize(width: 64, height: 32), for: .mediaBox)
      expect(
        bitmap.size.width > 0, "copied PDF remains renderable after source document is released")
    } else {
      expect(false, "decode PDF")
    }
    do {
      _ = try await ReadingPageDecoder.load(url: pdfURL, pdfPage: 10)
      expect(false, "missing PDF page must fail explicitly")
    } catch ReadingPageDecodingError.missingPage {}
    try Data("invalid".utf8).write(to: imageURL)
    do {
      _ = try await ReadingPageDecoder.load(url: imageURL, pdfPage: nil)
      expect(false, "corrupt image must fail explicitly")
    } catch ReadingPageDecodingError.invalidImage {}

    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(
      session: session, directory: directory.appendingPathComponent("fixtures"))
    try await CollectionLoadingChecks.run(directory: directory, session: session, library: library)
    let media = session.entities.first { $0.id == "c0-0" }!.media[0]
    library.local.release()
    let urls = try await withThrowingTaskGroup(of: URL.self) { group in
      for _ in 0..<3 { group.addTask { try await library.local.url(for: media, file: 0) } }
      var urls: [URL] = []
      for try await url in group { urls.append(url) }
      return urls
    }
    expect(
      urls.count == 3 && urls.allSatisfy { $0 == urls[0] }, "concurrent bookmark resolution agrees")
    library.local.release()
    let reopened = try await library.local.url(for: media, file: 0)
    expect(reopened == urls[0], "bookmark reopens after scope release")
    library.local.release()
    let savedEntities = session.entities
    var parent = savedEntities.first { $0.kind == .author }!
    parent.id = "large-library-parent"
    parent.tagIds = []
    parent.nsfw = false
    var chapter = savedEntities.first { $0.id == "c0-0" }!
    chapter.authorId = parent.id
    chapter.seriesId = nil
    chapter.workId = nil
    chapter.tagIds = []
    chapter.media = []
    chapter.nsfw = false
    let unrelated = (0..<20_000).map { index in
      var value = chapter
      value.id = "unrelated-\(index)"
      return value
    }
    chapter.id = "large-library-target"
    let defaults = UserDefaults.standard
    let savedNSFW = defaults.object(forKey: "ShowNSFW")
    defaults.set(false, forKey: "ShowNSFW")
    defer {
      session.entities = savedEntities
      if let savedNSFW {
        defaults.set(savedNSFW, forKey: "ShowNSFW")
      } else {
        defaults.removeObject(forKey: "ShowNSFW")
      }
    }
    session.entities = Array(unrelated.prefix(2000)) + [parent, chapter]
    let legacyStart = Date()
    let legacy = session.visibleEntities().first { $0.id == chapter.id }
    let legacySeconds = Date().timeIntervalSince(legacyStart)
    let lookupStart = Date()
    for _ in 0..<100 {
      expect(library.entity(chapter.id)?.id == legacy?.id, "lookup preserves visibility semantics")
    }
    let lookupSeconds = Date().timeIntervalSince(lookupStart) / 100
    print(
      String(
        format: "2,002-record synthetic lookup: prior full filter %.2f ms; direct lookup %.2f ms.",
        legacySeconds * 1000, lookupSeconds * 1000))
    session.entities = unrelated + [parent, chapter]
    let largeStart = Date()
    for _ in 0..<20 { expect(library.entity(chapter.id) != nil, "large-library target is visible") }
    expect(
      Date().timeIntervalSince(largeStart) < 1,
      "lookup must not filter all 20,002 records each time")
    session.entities[session.entities.count - 2].nsfw = true
    expect(library.entity(chapter.id) == nil, "direct lookup still hides inherited NSFW")
    defaults.set(true, forKey: "ShowNSFW")
    expect(library.entity(chapter.id) != nil, "explicit NSFW visibility remains supported")
    session.entities[session.entities.count - 1].deleted = true
    expect(library.entity(chapter.id) == nil, "deleted chapters remain hidden")
    print(
      "PASS: blocked decode leaves main actor responsive; newer page beats blocked old read; cancelled result ignored; height/resize; PNG and 30MP decode; PDF page/render/error; corrupt image error; concurrent bookmark reopening; 20,002-record lookup, inherited NSFW/deletion. Synthetic files only, no NAS/API calls."
    )
  }
}
