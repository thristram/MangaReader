import AppKit
import Foundation
import MangaCore
import SwiftUI

final class ImageTranslationTestProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  static var result = Data()
  static var calls = 0
  static var failOnCall: Int?
  static var badPNG = false
  static var offline = false
  static var responseDelay = 0.0
  private var responseTask: Task<Void, Never>?
  static var payloads: [Data] = []
  static var supportsStream = false
  static var legacyResult: Data?
  static var streamPayload: Data?
  static var requestedPaths: [String] = []
  static func frame(_ status: UInt8, _ payload: Data) -> Data {
    var size = UInt32(payload.count).bigEndian
    return Data([status]) + withUnsafeBytes(of: &size) { Data($0) } + payload
  }
  static func configure(result: Data, failure: Int? = nil, badPNG: Bool = false, offline: Bool = false,
    supportsStream: Bool = false, legacyResult: Data? = nil, streamPayload: Data? = nil) {
    lock.withLock {
      self.result = result; calls = 0; failOnCall = failure; self.badPNG = badPNG
      self.offline = offline; responseDelay = 0; payloads = []
      self.supportsStream = supportsStream; self.legacyResult = legacyResult
      self.streamPayload = streamPayload; requestedPaths = []
    }
  }
  static var count: Int { lock.withLock { calls } }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image-translation-fixtures.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 8192)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
    }
    let (status, data, type): (Int, Data, String) = Self.lock.withLock {
      if Self.offline { return (503, Data("{\"detail\":\"Translator unavailable\"}".utf8), "application/json") }
      if request.url!.path.hasSuffix("openapi.json") {
        var paths = ["/translate/with-form/image": ["post": [:] as [String: String]]]
        if Self.supportsStream { paths["/translate/with-form/image/stream"] = ["post": [:]] }
        return (200, try! JSONSerialization.data(withJSONObject: ["paths": paths]), "application/json")
      }
      let streaming = request.url!.path == "/api/translate/with-form/image/stream"
      guard (request.url!.path == "/api/translate/with-form/image" || (streaming && Self.supportsStream)), request.httpMethod == "POST" else {
        return (404, Data(), "application/json")
      }
      Self.calls += 1
      Self.payloads.append(body)
      Self.requestedPaths.append(request.url!.path)
      if Self.calls == Self.failOnCall { return (503, Data("{\"detail\":\"GPU worker unavailable\"}".utf8), "application/json") }
      let image = Self.badPNG ? Data("Not an image".utf8) : Self.result
      if streaming {
        return (200, Self.streamPayload ?? (Self.frame(3, Data("1".utf8)) + Self.frame(4, Data())
          + Self.frame(1, Data("rendering_folder:fixture".utf8)) + Self.frame(0, image)), "application/octet-stream")
      }
      return (200, Self.legacyResult ?? image, "image/png")
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    let delay = Self.lock.withLock { Self.responseDelay }
    responseTask = Task {
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      guard !Task.isCancelled else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() { responseTask?.cancel() }
}

@MainActor enum ImageTranslationChecks {
  static func run(directory: URL) async throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
      if !condition() { throw LoginError.server("Image translation: " + message) }
    }
    let oldDefaults = UserDefaults.standard.data(forKey: "ImageTranslationDefaults")
    defer { UserDefaults.standard.set(oldDefaults, forKey: "ImageTranslationDefaults") }
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    defer { library.reset() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ImageTranslationTestProtocol.self]
    let network = URLSession(configuration: configuration)
    defer { network.invalidateAndCancel() }
    let queue = library.translationQueue
    defer {
      let diagnostics = queue.jobs.map { "\($0.status) \($0.finishedCount)/\($0.pages.count): \($0.error)" }.joined(separator: "\n")
      fputs("Translation check jobs:\n" + diagnostics + "\n", stderr)
    }
    queue.serviceSession = network
    let chapter = session.entities.first { $0.id == "c1-1" }!
    let original = chapter.media[0]
    let root = original.storageRootId
    let originalURL = try await library.local.url(for: original, file: 0)
    let png = try Data(contentsOf: originalURL)
    let endpoint = "https://image-translation-fixtures.invalid/api"
    let staleSnapshot = try NativeUIFixtures.response(URLRequest(url: URL(string: "https://native-fixtures.invalid/sync")!)).1
    var options = MangaImageTranslationOptions()
    options.targetLanguage = "ENG"
    let config = try JSONSerialization.jsonObject(with: options.configData()) as! [String: Any]
    try check((config["translator"] as? [String: Any])?["target_lang"] as? String == "ENG", "wrong upstream language field")
    try check((config["detector"] as? [String: Any])?["detection_size"] as? Int == 1536, "wrong detector payload")
    for (api, media) in [("CHS", "zh"), ("CHT", "zh-Hant"), ("ESP", "es"), ("FRA", "fr")] {
      var variant = options; variant.targetLanguage = api
      try check(variant.mediaLanguage == media, "incorrect API/storage language mapping")
    }
    var invalid = options; invalid.boxThreshold = 4
    try check((try? invalid.validate()) == nil, "invalid numeric options accepted")
    try check((try? MangaImageTranslationService(baseURL: "file:///tmp")) == nil, "non-HTTP endpoint accepted")
    // The user's service leaves its web placeholder flag set on the shared
    // worker. Only its standard stream endpoint resets that flag per request.
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.setColor(.white, atX: 0, y: 0)
    let placeholder = bitmap.representation(using: .png, properties: [:])!
    let client = try MangaImageTranslationService(baseURL: endpoint, session: network)
    var custom = options; custom.translator = "custom_openai"
    ImageTranslationTestProtocol.configure(result: png, supportsStream: true, legacyResult: placeholder)
    let rendered = try await client.translate(image: png, options: custom)
    try check(rendered == png, "full-image stream did not preserve the rendered PNG")
    let streamRequest = ImageTranslationTestProtocol.lock.withLock {
      (ImageTranslationTestProtocol.requestedPaths, ImageTranslationTestProtocol.payloads)
    }
    try check(streamRequest.0 == ["/api/translate/with-form/image/stream"], "client chose the sticky web/legacy placeholder endpoint")
    try check(streamRequest.1[0].range(of: Data("\"translator\":\"custom_openai\"".utf8)) != nil,
      "custom OpenAI selection was not sent to the service")
    func rejected(_ operation: () async throws -> Void) async throws -> String {
      do { try await operation() } catch { return error.localizedDescription }
      throw LoginError.server("Image translation: invalid service response was accepted")
    }
    let frame = ImageTranslationTestProtocol.frame
    for malformed in [Data(), Data([0, 0]), Data([0, 255, 255, 255, 255]), frame(1, Data("finished".utf8)),
      frame(9, Data()), frame(0, png) + frame(1, Data()), frame(0, Data("not PNG".utf8)), frame(0, placeholder)] {
      ImageTranslationTestProtocol.configure(result: png, supportsStream: true, streamPayload: malformed)
      _ = try await rejected { _ = try await client.translate(image: png, options: custom) }
      try check(ImageTranslationTestProtocol.count == 1, "invalid stream automatically repeated a paid translation")
    }
    ImageTranslationTestProtocol.configure(result: png, supportsStream: true,
      streamPayload: frame(1, Data("translating".utf8)) + frame(2, Data("Custom provider unavailable".utf8)))
    let upstreamError = try await rejected { _ = try await client.translate(image: png, options: custom) }
    try check(upstreamError.contains("Custom provider unavailable"), "stream provider error was hidden")
    ImageTranslationTestProtocol.configure(result: png, failure: 1, supportsStream: true)
    _ = try await rejected { _ = try await client.translate(image: png, options: custom) }
    try check(ImageTranslationTestProtocol.count == 1, "HTTP failure retried the legacy translation endpoint")
    ImageTranslationTestProtocol.configure(result: placeholder)
    let placeholderError = try await rejected { _ = try await client.translate(image: png, options: custom) }
    try check(placeholderError.contains("1×1 placeholder"), "legacy placeholder lacked an actionable error")
    _ = try await rejected { try await MangaImageTranslationService.validateResult(placeholder) }
    // Do not mistake a genuine one-pixel source for the known placeholder bug.
    let tiny = try await client.translate(image: placeholder, options: custom)
    try check(tiny == placeholder, "a genuine one-pixel source was rejected")
    ImageTranslationTestProtocol.configure(result: png, offline: true)
    do {
      _ = try await queue.enqueue(chapter: chapter, source: original, options: options, baseURL: endpoint, destinationId: root)
      throw LoginError.server("offline service was accepted")
    } catch { try check(queue.jobs.isEmpty && ImageTranslationTestProtocol.count == 0, "offline enqueue changed queue or submitted images") }
    ImageTranslationTestProtocol.configure(result: png, failure: 2, supportsStream: true, legacyResult: placeholder)
    let id = try await queue.enqueue(chapter: chapter, source: original, options: options, baseURL: endpoint, destinationId: root)
    try await wait { queue.jobs.first { $0.id == id }?.status == "failed" }
    let failed = queue.jobs.first { $0.id == id }!
    try check(failed.finishedCount == 1 && failed.error.contains("GPU worker unavailable"), "page error/progress not preserved")
    let partial = session.entities.first { $0.id == chapter.id }!.media.first { $0.id == failed.targetMediaId }!
    try check(partial.pageCount == 1 && partial.pageAlignment == [0, nil, nil, nil, nil, nil], "partial translation does not fall back per page")
    // A polling response captured before the page commit must not erase it in
    // memory or in snapshot.json, which would poison the next page's file plan.
    NativeUIFixtures.heldSnapshot = staleSnapshot
    defer { NativeUIFixtures.heldSnapshot = nil }
    try await session.synchronize()
    NativeUIFixtures.heldSnapshot = nil
    try check(session.entities.first { $0.id == chapter.id }!.media.contains { $0.id == failed.targetMediaId },
      "stale background sync erased a committed translation")
    let persisted = try JSONDecoder().decode(SyncSnapshot.self,
      from: Data(contentsOf: session.cacheDirectory!.appendingPathComponent("snapshot.json")))
    try check(persisted.entities.first { $0.id == chapter.id }!.media.contains { $0.id == failed.targetMediaId },
      "stale background sync persisted an older chapter revision")
    let uploaded = ImageTranslationTestProtocol.lock.withLock { ImageTranslationTestProtocol.payloads[0] }
    try check(uploaded.range(of: Data("name=\"config\"".utf8)) != nil && uploaded.range(of: Data("name=\"image\"".utf8)) != nil,
      "multipart field names do not match the upstream API")
    try check(uploaded.range(of: Data([137, 80, 78, 71, 13, 10, 26, 10])) != nil, "source PNG not uploaded")
    let partialURL = try await library.local.url(for: partial, file: 0)
    let organizedBytes = try Data(contentsOf: partialURL)
    try check(organizedBytes == png, "organized image bytes changed")
    let cached = queue.outputURL(job: failed, page: failed.pages[0])!
    try check(FileManager.default.fileExists(atPath: cached.path), "preview cache missing")
    // Closing/restarting the queue preserves completed pages and explicit retry state.
    queue.reset()
    await queue.restore()
    try check(queue.jobs.first { $0.id == id }?.finishedCount == 1, "restart lost committed progress")
    ImageTranslationTestProtocol.lock.withLock { ImageTranslationTestProtocol.failOnCall = nil }
    queue.retry(id)
    try await wait { queue.jobs.first { $0.id == id }?.status == "completed" }
    let completed = queue.jobs.first { $0.id == id }!
    try check(completed.finishedCount == 6 && ImageTranslationTestProtocol.count == 7, "retry translated completed pages again")
    let current = session.entities.first { $0.id == chapter.id }!
    let english = current.media.first { $0.id == completed.targetMediaId }!
    try check(english.pageCount == 6 && english.pageAlignment == [0, 1, 2, 3, 4, 5], "completed target alignment incorrect")
    try check(current.media.first { $0.id == original.id }?.relativePaths.map { ($0 as NSString).lastPathComponent }
      == original.relativePaths.map { ($0 as NSString).lastPathComponent }, "original files or page order changed")
    let pagePlans = try FileManager.default.contentsOfDirectory(
      at: session.cacheDirectory!.appendingPathComponent("organization-journals"), includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .compactMap { try? JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: $0)) }
      .filter { $0.entityId == chapter.id }
    try check(pagePlans.count == 6 && pagePlans.filter { $0.files.count == 1 }.count == 5,
      "subsequent translated pages copied unchanged chapter images")
    try check(pagePlans.filter { $0.files.count == 1 }.allSatisfy { ($0.cleanupFolders ?? []).isEmpty },
      "a one-page append attempted directory cleanup for unchanged media")

    // A metadata failure retains the generated image; retry resumes the file journal without paying for translation again.
    let committing = session.entities.first { $0.id == "c2-1" }!
    let committingSource = committing.media[0]
    NativeUIFixtures.rejectedUpdateIds.insert(committing.id)
    defer { NativeUIFixtures.rejectedUpdateIds.remove(committing.id) }
    ImageTranslationTestProtocol.configure(result: png)
    let commitId = try await queue.enqueue(chapter: committing, source: committingSource, options: options, baseURL: endpoint, destinationId: root)
    try await wait { queue.jobs.first { $0.id == commitId }?.status == "failed" }
    let commitFailure = queue.jobs.first { $0.id == commitId }!
    try check(commitFailure.pages[0].cachedName != nil && ImageTranslationTestProtocol.count == 1,
      "metadata failure lost translated output")
    let journals = session.cacheDirectory!.appendingPathComponent("organization-journals")
    let legacyURL = try FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil)
      .first { url in
        guard let plan = try? JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: url)) else { return false }
        return plan.entityId == committing.id && plan.phase != "complete"
      }!
    var legacyPlan = try JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: legacyURL))
    // Real old journals used content digests, not the newer same-volume identity.
    for index in legacyPlan.files.indices {
      legacyPlan.files[index].digest = try FileInventory.digest(URL(fileURLWithPath: legacyPlan.files[index].source))
      legacyPlan.files[index].identity = nil
      legacyPlan.files[index].allowRename = nil
    }
    legacyPlan.originalMetadata = nil
    try JSONEncoder().encode(legacyPlan).write(to: legacyURL, options: .atomic)
    NativeUIFixtures.rejectedUpdateIds.remove(committing.id)
    // Reproduce the reported recovery error: a failed page commit, then a description/
    // title translation edit on another client before Retry. Preserve those edits.
    let beforeRetry = session.entities.first { $0.id == committing.id }!
    var edited = beforeRetry.input
    edited.description = "Description updated while translation was paused"
    edited.localizations["fr"] = .init(title: "New French chapter title")
    try await session.update(beforeRetry, input: edited)
    guard case .conflict = try legacyPlan.recovery(current: edited, revision: beforeRetry.revision + 1) else {
      throw LoginError.server("Legacy fixture did not reproduce the missing-snapshot conflict")
    }
    queue.reset()
    await queue.restore()
    // File Management Queue recovery and Translation Queue Retry share the proven
    // legacy reconstruction; neither requires re-import or a new model request.
    try await library.resumeOrganizationPlan(legacyPlan)
    queue.retry(commitId)
    try await wait { queue.jobs.first { $0.id == commitId }?.status == "completed" }
    try check(ImageTranslationTestProtocol.count == 6, "file-journal retry sent the cached page again")
    let pending = try await library.pendingFileOrganizationIds()
    try check(!pending.contains(committing.id), "recovered commit journal remains pending")
    let recovered = session.entities.first { $0.id == committing.id }!
    try check(recovered.description == edited.description && recovered.localizations == edited.localizations,
      "recovery overwrote newer metadata")
    // Simulate a lost response after the final media update, with a legacy journal.
    let plans = try FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .compactMap { try? JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: $0)) }
    var lostReply = plans.first { $0.entityId == committing.id
      && $0.metadata.media.contains { $0.id == commitFailure.targetMediaId && $0.pageCount == 6 } }!
    lostReply.phase = "filesReady_metadataPending"
    lostReply.originalMetadata = nil
    try JSONEncoder().encode(lostReply).write(to: journals.appendingPathComponent(lostReply.id + ".json"), options: .atomic)
    var newer = recovered.input
    newer.description = "Even newer description after server commit"
    try await session.update(recovered, input: newer)
    let revision = session.entities.first { $0.id == committing.id }!.revision
    try await library.resumeOrganizationPlan(lostReply)
    let finished = session.entities.first { $0.id == committing.id }!
    try check(finished.description == newer.description && finished.revision == revision,
      "already-committed recovery rewrote newer metadata")
    let finishedPlan = try FileOrganization.read(lostReply.id, in: journals)
    try check(finishedPlan.phase == "complete",
      "already-committed journal did not finish")

    // Existing partial media is filled in place, with existing translations left untouched.
    let bilingual = session.entities.first { $0.id == "c0-0" }!
    let existing = bilingual.media.first { $0.language == "zh" }!
    var chinese = options; chinese.targetLanguage = "CHS"
    ImageTranslationTestProtocol.configure(result: png)
    NativeUIFixtures.rejectedUpdateIds.insert(bilingual.id)
    defer { NativeUIFixtures.rejectedUpdateIds.remove(bilingual.id) }
    let partialId = try await queue.enqueue(chapter: bilingual, source: bilingual.media.first { $0.language == "ja" }!,
      options: chinese, baseURL: endpoint, destinationId: root)
    try await wait { queue.jobs.first { $0.id == partialId }?.status == "failed" }
    let partialFailure = queue.jobs.first { $0.id == partialId }!
    try check(partialFailure.finishedCount == 3 && ImageTranslationTestProtocol.count == 1,
      "partial legacy fixture did not retain its existing translated pages")
    let partialPlanURL = try FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil)
      .first { url in
        guard let plan = try? JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: url)) else { return false }
        return plan.entityId == bilingual.id && plan.phase != "complete"
      }!
    var partialPlan = try JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: partialPlanURL))
    for index in partialPlan.files.indices {
      partialPlan.files[index].digest = try FileInventory.digest(URL(fileURLWithPath: partialPlan.files[index].source))
      partialPlan.files[index].identity = nil
      partialPlan.files[index].allowRename = nil
    }
    partialPlan.originalMetadata = nil
    // Match the three real failures: the pending plan omitted one prior success,
    // while the current chapter already has that earlier page. The cached page
    // must be appended to the newer media, never replace that successful page.
    let staleTarget = partialPlan.metadata.media.firstIndex { $0.id == existing.id }!
    let missingIndex = existing.relativePaths.count - 1
    let missingPath = partialPlan.metadata.media[staleTarget].relativePaths.remove(at: missingIndex)
    partialPlan.metadata.media[staleTarget].pageCount -= 1
    partialPlan.metadata.media[staleTarget].pageAlignment = partialPlan.metadata.media[staleTarget].pageAlignment?.map {
      guard let value = $0, value != missingIndex else { return nil }
      return value > missingIndex ? value - 1 : value
    }
    partialPlan.files.removeAll { $0.relativePath == missingPath }
    try JSONEncoder().encode(partialPlan).write(to: partialPlanURL, options: .atomic)
    NativeUIFixtures.rejectedUpdateIds.remove(bilingual.id)
    let paused = session.entities.first { $0.id == bilingual.id }!
    var changed = paused.input
    changed.description = "Updated while a partial translation was paused"
    // The omitted successful page is already stored in the archive, just like
    // the real failures. Retain the fixture's staged copy as that committed page.
    changed.media[staleTarget].relativePaths[missingIndex] = missingPath
    try await session.update(paused, input: changed)
    // The ordinary Translation Queue action must infer the old page commit too.
    queue.retry(partialId)
    try await wait { queue.jobs.first { $0.id == partialId }?.status == "completed" }
    let filled = session.entities.first { $0.id == bilingual.id }!.media.first { $0.id == existing.id }!
    try check(ImageTranslationTestProtocol.count == 3 && filled.pageCount == 6,
      "existing partial translation was overwritten or duplicated")
    try check(session.entities.first { $0.id == bilingual.id }!.description == changed.description,
      "partial legacy retry overwrote a newer description")
    let rebased = try FileOrganization.read(partialPlan.id, in: journals)
    try check(rebased.phase == "complete" && rebased.priorMetadata != nil && rebased.originalMetadata != nil,
      "rebased recovery payload was not persisted for audit and subsequent retry")
    let invalidChapter = session.entities.first { $0.id == "c3-1" }!
    ImageTranslationTestProtocol.configure(result: png, badPNG: true)
    let invalidId = try await queue.enqueue(chapter: invalidChapter, source: invalidChapter.media[0], options: options,
      baseURL: endpoint, destinationId: root)
    try await wait { queue.jobs.first { $0.id == invalidId }?.status == "failed" }
    try check(queue.jobs.first { $0.id == invalidId }?.pages[0].cachedName == nil, "invalid PNG entered translation cache")
    try check(session.entities.first { $0.id == invalidChapter.id }!.media.count == 1, "invalid PNG changed chapter metadata")
    ImageTranslationTestProtocol.configure(result: placeholder, supportsStream: true)
    let placeholderId = try await queue.enqueue(chapter: invalidChapter, source: invalidChapter.media[0], options: custom,
      baseURL: endpoint, destinationId: root)
    try await wait { queue.jobs.first { $0.id == placeholderId }?.status == "failed" }
    let rejectedPage = queue.jobs.first { $0.id == placeholderId }!
    try check(rejectedPage.error.contains("1×1 placeholder") && rejectedPage.pages[0].cachedName == nil,
      "placeholder was cached or its reason was hidden")
    try check(session.entities.first { $0.id == invalidChapter.id }!.media.count == 1,
      "placeholder changed chapter metadata")
    // Replay a pre-fix uncommitted cached placeholder. Retry must stop before
    // recovering/writing file metadata, and retain the cache for inspection.
    var oldJobs = queue.jobs
    let oldIndex = oldJobs.firstIndex { $0.id == placeholderId }!
    oldJobs[oldIndex].pages[0].cachedName = placeholderId + "-000001.png"
    let badCache = queue.outputURL(job: oldJobs[oldIndex], page: oldJobs[oldIndex].pages[0])!
    let savedQueue = queue.directory!.appendingPathComponent("queue.json")
    queue.reset()
    try FileManager.default.createDirectory(at: badCache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try placeholder.write(to: badCache, options: .atomic)
    try JSONEncoder().encode(oldJobs).write(to: savedQueue, options: .atomic)
    ImageTranslationTestProtocol.configure(result: png, supportsStream: true)
    await queue.restore()
    queue.retry(placeholderId)
    try await wait { queue.jobs.first { $0.id == placeholderId }?.status == "failed" }
    try check(ImageTranslationTestProtocol.count == 0 && FileManager.default.fileExists(atPath: badCache.path),
      "cached-placeholder recovery submitted another translation or deleted the cache")
    try check(session.entities.first { $0.id == invalidChapter.id }!.media.count == 1,
      "old cached placeholder was published on retry")
    let pdf = session.entities.first { $0.id == "c5-1" }!.media[0]
    let pdfURL = try await library.local.url(for: pdf, file: 0)
    let pdfPNG = try await MangaTranslationQueue.png(url: pdfURL, pdfPage: 1)
    try check(pdfPNG.starts(with: [137, 80, 78, 71]), "PDF page was not rasterized for the image service")
    let cancellationChapter = session.entities.first { $0.id == "c4-1" }!
    ImageTranslationTestProtocol.configure(result: png)
    ImageTranslationTestProtocol.lock.withLock { ImageTranslationTestProtocol.responseDelay = 0.3 }
    let cancellationId = try await queue.enqueue(chapter: cancellationChapter, source: cancellationChapter.media[0],
      options: options, baseURL: endpoint, destinationId: root)
    try await wait { ImageTranslationTestProtocol.count > 0 }
    let owner = session.account
    queue.reset()
    session.account = nil
    try await Task.sleep(for: .milliseconds(500))
    try check(queue.jobs.isEmpty && session.entities.first { $0.id == cancellationChapter.id }!.media.count == 1,
      "sign-out allowed a late translation result to modify metadata")
    session.account = owner
    ImageTranslationTestProtocol.lock.withLock { ImageTranslationTestProtocol.responseDelay = 0 }
    await queue.restore()
    try check(queue.jobs.first { $0.id == cancellationId }?.status == "failed",
      "interrupted request was silently resumed after account restore")

    let failedEntry = FileQueueItem(id: UUID(), title: "Failed import", status: "Failed", failed: true)
    library.fileQueue.items.append(failedEntry)
    library.fileQueue.removeFailed(failedEntry.id)
    try check(!library.fileQueue.items.contains { $0.id == failedEntry.id }, "failed file task could not be removed")
    print("PASS: standard full-image stream preferred over sticky white placeholders; custom OpenAI contract; strict binary framing/provider errors; no duplicate paid POST fallback; legacy API compatibility; placeholder rejected before cache/metadata; upstream multipart/options/locale contract; offline enqueue blocked; progressive page alignment/fallback; cached previews; persisted retry without retranslation; legacy missing-snapshot recovery through file recovery and queue Retry; newer descriptions/localizations preserved; existing translations preserved; invalid image rejection; PDF rasterization; in-flight cancellation/account restore; failed file queue removal.")
  }
  private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
    let limit = Date().addingTimeInterval(40)
    while !condition() {
      if Date() > limit { throw LoginError.server("Image translation integration check timed out") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}
