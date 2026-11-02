import Foundation
import MangaCore

private final class TextJobProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  static var bodies: [[String: Any]] = []
  static var failAt = 0
  static var delay = 0.01
  static func reset(failAt: Int = 0, delay: Double = 0.01) {
    lock.withLock { bodies = []; self.failAt = failAt; self.delay = delay }
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "text-jobs.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      var data = request.httpBody ?? Data()
      if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
      }
      let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      let (failed, delay) = Self.lock.withLock {
        Self.bodies.append(body); return (Self.bodies.count == Self.failAt, Self.delay)
      }
      let source = (body["messages"] as! [[String: String]])[1]["content"]!
      let response: [String: Any] = failed ? ["error": "fixture interrupted"] : ["message": ["content": source.replacingOccurrences(of: "雨", with: "雪")], "done": true]
      let result = try JSONSerialization.data(withJSONObject: response)
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: failed ? 503 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result); client?.urlProtocolDidFinishLoading(self)
      }
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@MainActor enum TextTranslationChecks {
  static func run(directory: URL) async throws {
    func check(_ value: @autoclosure () -> Bool, _ reason: String) throws {
      if !value() { throw LoginError.server("Text translation jobs: " + reason) }
    }
    func until(_ condition: () -> Bool) async throws {
      for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
      throw LoginError.server("Text translation job wait timed out")
    }
    let suite = "text-jobs-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("http://text-jobs.invalid", forKey: "OllamaURL")
    defaults.set("sakura-6b", forKey: "OllamaModel")
    defaults.set(1500, forKey: "TranslationChunkCharacters")
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TextJobProtocol.self]
    let transport = URLSession(configuration: configuration)
    defer { transport.invalidateAndCancel() }
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent(suite))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    let queue = TextTranslationQueue(library: library, transport: transport)
    defer { queue.reset(); library.reset(); session.signOut() }
    let position = session.entities.firstIndex { $0.id == "c0-0" }!
    var chapter = session.entities[position]
    chapter.description = "[chapter:雨]\n" + String(repeating: "雨が降る。\n", count: 5765)
    try await session.update(session.entities[position], input: chapter.input)
    chapter = session.entities[position]
    TextJobProtocol.reset(failAt: 3)
    let id = try await queue.enqueue(entity: chapter, title: chapter.title, field: "description",
      source: chapter.description, language: "zh", defaults: defaults)
    defaults.set("another-model", forKey: "OllamaModel")
    try await until { queue.jobs.first?.status == "failed" }
    try check(queue.jobs.first?.finished == 2 && (queue.jobs.first?.chunks.count ?? 0) > 20,
      "long novel was not chunked/checkpointed before a provider failure")
    try check(session.entities[position].localizations["zh"]?.description != chapter.description.replacingOccurrences(of: "雨", with: "雪"),
      "partially translated novel was published")
    let initial = TextJobProtocol.lock.withLock { TextJobProtocol.bodies }
    try check(initial.allSatisfy { $0["format"] == nil }, "JSON model output still forced")
    try check(initial.allSatisfy { $0["model"] as? String == "sakura-6b" },
      "an in-flight job switched models after preferences changed")
    try check(initial.allSatisfy {
      let options = $0["options"] as? [String: Int]
      return options?["num_ctx"] == 16384 && options?["num_predict"] == 4096
    }, "token settings lost")
    // Recreate the controller to prove disk recovery, not just in-memory retry.
    queue.reset()
    let resumed = TextTranslationQueue(library: library, transport: transport)
    defer { resumed.reset() }
    await resumed.restore()
    try check(resumed.jobs.first?.finished == 2, "cached completed chunks did not survive controller recreation")
    TextJobProtocol.reset()
    resumed.retry(id)
    try await until { resumed.jobs.first?.status == "completed" }
    let requests = TextJobProtocol.lock.withLock { TextJobProtocol.bodies.count }
    try check(TextJobProtocol.lock.withLock { TextJobProtocol.bodies.allSatisfy { $0["model"] as? String == "sakura-6b" } },
      "retry lost the original model configuration")
    try check(requests == (resumed.jobs.first!.chunks.count - 2), "retry retransmitted completed chunks")
    try check(session.entities[position].description == chapter.description,
      "source novel changed during translation")
    try check(session.entities[position].localizations["zh"]?.description == chapter.description.replacingOccurrences(of: "雨", with: "雪"),
      "full translated novel was not saved in order with paragraph breaks")
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let actualMedia = try encoder.encode(session.entities[position].media)
    let originalMedia = try encoder.encode(chapter.media)
    try check(actualMedia == originalMedia, "text job changed comic media")
    // A user editing the source while inference runs must retain their newer text.
    TextJobProtocol.reset(delay: 0.15)
    let draft = UUID()
    let draftId = try await resumed.enqueue(entity: nil, draft: draft, title: "Draft", field: "title", source: "雨の夜", language: "zh", defaults: defaults)
    try await until { resumed.jobs.first { $0.id == draftId }?.status == "completed" }
    try check(resumed.jobs.first { $0.id == draftId }?.result == "雪の夜", "unsaved draft output was discarded")
    let attachingDraft = UUID()
    let attachedId = try await resumed.enqueue(entity: nil, draft: attachingDraft, title: "雨の夜", field: "title", source: "雨の夜", language: "zh", draftTranslation: .init(title: "Old draft translation"), defaults: defaults)
    var createdInput = MetadataInput(kind: .work, title: "雨の夜", authorId: "a0")
    createdInput.localizations["zh"] = .init(title: "Old draft translation")
    let created = try await session.create(createdInput)
    resumed.attachDraft(attachingDraft, entity: created)
    try await until { resumed.jobs.first { $0.id == attachedId }?.status == "completed" }
    try check(session.entities.first { $0.id == created.id }?.localizations["zh"]?.title == "雪の夜",
      "saved draft did not attach/retranslate its existing localization")
    let current = session.entities[position]
    let stale = try await resumed.enqueue(entity: current, title: current.title, field: "title", source: current.title, language: "fr", defaults: defaults)
    try await until { resumed.jobs.first { $0.id == stale }?.status == "running" }
    var changed = current.input; changed.title = "New source title"
    try await session.update(current, input: changed)
    try await until { resumed.jobs.first { $0.id == stale }?.status == "failed" }
    try check(resumed.jobs.first { $0.id == stale }?.error.contains("source text changed") == true,
      "changed source was overwritten")
    let manual = session.entities[position]
    let protected = try await resumed.enqueue(entity: manual, title: manual.title, field: "title", source: manual.title, language: "fr", defaults: defaults)
    try await until { resumed.jobs.first { $0.id == protected }?.status == "running" }
    var manualInput = manual.input; manualInput.localizations["fr"] = .init(title: "Manually edited title")
    try await session.update(manual, input: manualInput)
    try await until { resumed.jobs.first { $0.id == protected }?.status == "failed" }
    try check(session.entities[position].localizations["fr"]?.title == "Manually edited title"
      && resumed.jobs.first { $0.id == protected }?.result != nil,
      "manual translation was overwritten or cached result was lost")
    // A compatible remote edit creates a 409, then only this entity is reloaded.
    let compatible = session.entities[position]
    let merging = try await resumed.enqueue(entity: compatible, title: compatible.title, field: "title", source: compatible.title, language: "es", defaults: defaults)
    try await until { resumed.jobs.first { $0.id == merging }?.status == "running" }
    var remote = compatible.input; remote.description += "\nRemote description edit."
    try NativeUIFixtures.updateRemotely(compatible.id, input: remote)
    try await until { resumed.jobs.first { $0.id == merging }?.status == "completed" }
    try check(session.entities[position].description == remote.description,
      "targeted conflict recovery overwrote compatible remote metadata")
    // Reset/account isolation must invalidate in-flight callbacks and retained jobs.
    let before = session.entities[position]
    let cancelling = try await resumed.enqueue(entity: before, title: before.title, field: "title", source: before.title, language: "de", defaults: defaults)
    try await until { resumed.jobs.first { $0.id == cancelling }?.status == "running" }
    resumed.reset()
    try await Task.sleep(for: .milliseconds(250))
    try check(resumed.jobs.isEmpty && session.entities[position].localizations["de"] == nil,
      "reset allowed a stale job to publish")
    let beforeOversized = TextJobProtocol.lock.withLock { TextJobProtocol.bodies.count }
    do {
      _ = try await resumed.enqueue(entity: nil, title: "Oversized", field: "description", source: String(repeating: "文", count: 500001), language: "zh", defaults: defaults)
      throw LoginError.server("Oversized source was accepted")
    } catch {
      try check(error.localizedDescription.contains("500,000"), "oversized-source error was opaque")
    }
    try check(TextJobProtocol.lock.withLock { TextJobProtocol.bodies.count } == beforeOversized,
      "oversized novel started inference")
    print("PASS: 34K+ novel async jobs; bounded plain-text requests; shared context/output options; chunk progress; no partial publication; disk resume skips completed inference; source/media preservation; unsaved draft result; stale-source rejection; account/reset isolation. Synthetic services only.")
  }
}
