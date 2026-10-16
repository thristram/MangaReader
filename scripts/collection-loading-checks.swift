// Synthetic checks compiled into isolated Mac/iPhone harnesses only.
import Foundation
import ImageIO
import MangaCore

private final class CoverDecodeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let release = DispatchSemaphore(value: 0)
  var started: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func decode(_ image: CGImage) throws -> CGImage {
    guard !Thread.isMainThread else { throw CheckFailure.message("Cover decoded on main thread") }
    lock.lock()
    count += 1
    let position = count
    lock.unlock()
    if position <= 2 && release.wait(timeout: .now() + 10) != .success {
      throw CheckFailure.message("Cover test gate timed out")
    }
    return image
  }
}
private enum CheckFailure: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}
@MainActor enum CollectionLoadingChecks {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.message(message) }
  }
  static func run(directory: URL, session: AppSession, library: LibraryUIModel) async throws {
    let savedEntities = session.entities
    defer { session.entities = savedEntities }
    let work = session.entities.first { $0.kind == .work && !$0.nsfw }!
    let chapter = session.entities.first { $0.kind == .chapter && $0.workId == work.id }!
    let additional = (0..<2000).map { index in
      var item = chapter
      item.id = "stress-\(index)"
      item.title = "Chapter \(index)"
      item.tagIds = []
      item.nsfw = false
      return item
    }
    session.entities += additional
    let children = library.children(work)
    try expect(
      Set(children.map(\.id)).isSuperset(of: Set(additional.map(\.id))),
      "A large chapter collection is truncated")
    for item in additional {
      try expect(
        library.entity(item.id)?.id == item.id && library.chapters(item).count == 1,
        "A chapter is missing from the cached index")
    }
    let start = Date()
    for _ in 0..<5 {
      for item in additional {
        _ = library.coverKey(item)
        _ = library.state(item.id)
        _ = library.chapters(item)
      }
    }
    let elapsed = Date().timeIntervalSince(start)
    try expect(elapsed < 1, "Indexed tile queries still scan the whole library: \(elapsed)s")
    session.entities[session.entities.count - 1].deleted = true
    try expect(library.entity("stress-1999") == nil, "In-place metadata edits leave a stale index")
    session.entities = savedEntities

    let context = CGContext(
      data: nil, width: 32, height: 64, bitsPerComponent: 8, bytesPerRow: 128,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bitmap = context.makeImage()!
    let gate = CoverDecodeGate()
    let thumbnails = CoverThumbnails { _ in try gate.decode(bitmap) }
    let folder = directory.appendingPathComponent("cover-stress")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let urls = try (0..<63).map { index in
      let url = folder.appendingPathComponent("\(index).png")
      try Data([0]).write(to: url)
      return url
    }
    let first = urls.prefix(2).map { url in Task { try await thumbnails.image(at: url) } }
    defer {
      gate.release.signal()
      gate.release.signal()
    }
    for _ in 0..<200 {
      if gate.started == 2 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try expect(gate.started == 2, "Background cover workers did not start")
    let queued = urls.dropFirst(2).dropLast().map { url in
      Task { try await thumbnails.image(at: url) }
    }
    try await Task.sleep(for: .milliseconds(50))
    try expect(gate.started == 2, "More than two cover decodes ran at once")
    // Reaching this check while both workers are blocked proves the UI actor remains available.
    queued.forEach { $0.cancel() }
    for task in queued {
      do {
        _ = try await task.value
        throw CheckFailure.message("Cancelled queued cover decoded")
      } catch is CancellationError {}
    }
    gate.release.signal()
    gate.release.signal()
    for task in first { _ = try await task.value }
    _ = try await thumbnails.image(at: urls[0])
    try expect(gate.started == 2, "Cached cover decoded again")
    _ = try await thumbnails.image(at: urls.last!)
    try expect(gate.started == 3, "Cancelled queued covers started decoding")
    try Data([0, 1]).write(to: urls[0])
    _ = try await thumbnails.image(at: urls[0])
    try expect(gate.started == 4, "Replaced cover reused a stale bitmap")
    let presentation = ThumbnailPresentation { _ in bitmap }
    await presentation.load(urls[0])
    try expect(presentation.image != nil, "Visible thumbnail did not load")
    presentation.clear()
    try expect(presentation.image == nil && !presentation.loading, "Offscreen cell retains its bitmap")
    let lateGate = CoverDecodeGate()
    let latePipeline = CoverThumbnails { _ in try lateGate.decode(bitmap) }
    let latePresentation = ThumbnailPresentation { try await latePipeline.image(at: $0) }
    let lateTask = Task { await latePresentation.load(urls[0]) }
    for _ in 0..<200 {
      if lateGate.started == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try expect(lateGate.started == 1, "Late thumbnail worker did not start")
    latePresentation.clear()
    lateGate.release.signal()
    await lateTask.value
    try expect(latePresentation.image == nil, "Late completion repopulates an offscreen cell")
    thumbnails.purge()
    _ = try await thumbnails.image(at: urls[0])
    try expect(gate.started == 5, "Thumbnail cache cannot be purged under memory pressure")

    let imageURL = folder.appendingPathComponent("large.png")
    try await FileTasks.perform {
      let large = CGContext(
        data: nil, width: 1800, height: 2700, bitsPerComponent: 8, bytesPerRow: 7200,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      let output = CGImageDestinationCreateWithURL(
        imageURL as CFURL, "public.png" as CFString, 1, nil)!
      CGImageDestinationAddImage(output, large.makeImage()!, nil)
      guard CGImageDestinationFinalize(output) else { throw CheckFailure.message("Write PNG") }
    }
    let downsampled = try await CoverThumbnails.shared.image(at: imageURL)
    try expect(
      max(downsampled.width, downsampled.height) <= 768, "Cover was decoded at full resolution")
    try expect(
      abs(Double(downsampled.width) / Double(downsampled.height) - 2.0 / 3.0) < 0.01,
      "Downsampled cover aspect changed")

    let media = MediaVersion(
      language: "ja", kind: "images", storageRootId: "synthetic-root",
      relativePaths: ["Test/0.png", "Test/1.png", "Test/2.png"], pageCount: 3)
    let sources = [imageURL, imageURL, imageURL]
    async let a = library.smb.download(media, localURLs: sources, indices: [0])
    async let b = library.smb.download(media, localURLs: sources, indices: [1])
    async let c = library.smb.download(media, localURLs: sources, indices: [2])
    _ = try await (a, b, c)
    let reopened = SMBMedia(session: session)
    for index in 0..<3 {
      let page = try await reopened.cachedPage(media, index: index)
      try expect(page != nil, "Concurrent cover/reader downloads lost a persisted manifest entry")
    }
    try await Task.sleep(for: .milliseconds(250))
    let revision = library.revision
    for _ in 0..<100 { library.smb.availabilityChanged?() }
    try await Task.sleep(for: .milliseconds(250))
    try expect(
      library.revision == revision + 1,
      "Availability updates invalidate the whole collection per cover")
    print(
      String(
        format:
          "PASS: 2,000 chapters; 10,000 indexed tile queries in %.1f ms; bounded off-main cover decode; UI heartbeat while blocked; 60 cancelled covers; cache refresh; 768px downsampling; concurrent persisted manifests; batched availability.",
        elapsed * 1000))
  }
}
