import Foundation
import MangaCore

private final class SyncTrafficProtocol: URLProtocol, @unchecked Sendable {
  static var engine: SyncTrafficEngine?
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sync-traffic.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      var captured = request
      if captured.httpBody == nil, let stream = captured.httpBodyStream {
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        captured.httpBody = data
      }
      let (status, headers, data) = try Self.engine!.handle(captured)
      // Permit overlapping callers/account changes while the request is in flight.
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { [self] in
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
      }
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
private final class SyncTrafficEngine: @unchecked Sendable {
  let lock = NSLock()
  var records: [[String: Any]] = [], states: [[String: Any]] = []
  var manifests = 0, batches = 0, writes = 0, stateReads = 0
  var requestedEntities: [[String]] = [], requestedStates: [[String]] = []
  var failBatch = 0, rejectWrites = false, generation = 1
  var batchLimit = 100
  func handle(_ r: URLRequest) throws -> (Int, [String: String], Data) {
    try lock.withLock {
      func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
      let path = r.url!.path
      if path == "/v1/sync/manifest" {
        manifests += 1
        let etag = "\"generation-\(generation)\""
        if r.value(forHTTPHeaderField: "If-None-Match") == etag { return (304, ["ETag": etag], Data()) }
        return (200, ["ETag": etag], try json(["schemaVersion": 2,
          "entities": records.map { ["id": $0["id"]!, "revision": $0["revision"]!, "deleted": $0["deleted"]!] },
          "states": states.map { ["id": $0["id"]!, "revision": $0["revision"]!] }]))
      }
      if path == "/v1/sync/records" {
        batches += 1
        if batches == failBatch { return (503, [:], Data()) }
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: [String]]
        requestedEntities.append(body["entities"]!); requestedStates.append(body["states"]!)
        let selected = records.filter { body["entities"]!.contains($0["id"] as! String) }
        let selectedStates = states.filter { body["states"]!.contains($0["id"] as! String) }
        return (200, [:], try json(["schemaVersion": 1,
          "entities": Array(selected.prefix(batchLimit)), "states": selectedStates,
          "remainingEntities": selected.dropFirst(batchLimit).map { $0["id"]! }]))
      }
      if path.hasPrefix("/v1/states/") && r.httpMethod == "GET" {
        stateReads += 1
        guard let value = states.first(where: { $0["id"] as? String == r.url!.lastPathComponent }) else { return (404, [:], Data()) }
        return (200, [:], try json(value))
      }
      if path == "/v1/states" && r.httpMethod == "PUT" {
        writes += 1
        if rejectWrites { return (429, ["Retry-After": "30"], Data()) }
        var body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        let id = (body["entityId"] as! String) + ":" + (body["pageIndex"].map { String(describing: $0) } ?? "entity")
        let old = states.first { $0["id"] as? String == id }
        if Int(r.value(forHTTPHeaderField: "If-Match") ?? "") != (old?["revision"] as? Int ?? 0) { return (409, [:], Data()) }
        body["id"] = id; body["revision"] = (old?["revision"] as? Int ?? 0) + 1; body["updatedAt"] = "fixture"
        states.removeAll { $0["id"] as? String == id }; states.append(body); generation += 1
        return (200, [:], try json(body))
      }
      return (404, [:], Data())
    }
  }
}
@MainActor enum SyncTrafficChecks {
  static func check(_ value: @autoclosure () -> Bool, _ reason: String) throws {
    if !value() { throw LoginError.server("Sync traffic: " + reason) }
  }
  static func until(_ condition: () -> Bool) async throws {
    for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(30)) }
    throw LoginError.server("Sync traffic wait timed out")
  }
  static func run(directory: URL) async throws {
    let engine = SyncTrafficEngine(); SyncTrafficProtocol.engine = engine
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SyncTrafficProtocol.self]
    let transport = URLSession(configuration: configuration)
    defer { transport.invalidateAndCancel(); SyncTrafficProtocol.engine = nil }
    let api = APIClient(base: URL(string: "https://sync-traffic.invalid")!, transport: transport) { "fixture" }
    let session = AppSession(cacheRoot: directory.appendingPathComponent("cache"), apiClient: api)
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    defer { session.signOut(); library.reset() }
    engine.records = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.entities)) as! [[String: Any]]
    session.entities = []; session.states = []
    async let one: Void = session.synchronize()
    async let two: Void = session.synchronize()
    _ = try await (one, two)
    try check(engine.manifests == 1 && engine.batches == 1, "overlapping sync was not single-flight")
    let generation = session.metadataGeneration
    try await session.synchronize()
    try check(engine.batches == 1 && session.metadataGeneration == generation, "304 must not fetch records or invalidate the UI")
    let id = "c0-0"
    engine.lock.withLock {
      let i = engine.records.firstIndex { $0["id"] as? String == id }!
      engine.records[i]["revision"] = 2; engine.records[i]["title"] = "Only changed chapter"; engine.generation += 1
    }
    try await session.synchronize()
    try check(engine.requestedEntities.last == [id] && engine.requestedStates.last == [], "one chapter update fetched unrelated records")
    try check(session.entities.first { $0.id == id }?.title == "Only changed chapter", "changed chapter not applied")
    engine.lock.withLock {
      engine.states = [["id": id + ":entity", "entityId": id, "favorite": true, "starred": false, "revision": 1, "updatedAt": "fixture"]]
      engine.generation += 1
    }
    try await session.synchronize()
    try check(engine.requestedEntities.last == [] && engine.requestedStates.last == [id + ":entity"], "state change downloaded chapter paths")
    // Force a state conflict, then verify only that state is reloaded.
    engine.lock.withLock { engine.states[0]["revision"] = 2 }
    let initialReads = engine.batches
    for page in 0..<5 {
      library.writeState(.init(entityId: id, favorite: false, starred: false, progress: .init(mediaId: session.entities.first { $0.id == id }!.media[0].id, pageIndex: page, completed: false)), progressOnly: true)
    }
    try await Task.sleep(for: .milliseconds(150))
    try check(engine.writes == 0, "rapid page changes were sent before coalescing")
    library.flushStates()
    try await until { engine.writes >= 2 && session.personalState(id)?.progress?.pageIndex == 4 }
    try check(engine.stateReads == 1 && engine.batches == initialReads, "state conflict fetched the whole library")
    try check(session.personalState(id)?.favorite == true, "progress conflict overwrote remote favorite")
    // A star action must not restore an old favorite value after a conflict.
    engine.lock.withLock { engine.states[0]["favorite"] = false; engine.states[0]["revision"] = 4 }
    library.mark(session.entities.first { $0.id == id }!, starred: true)
    try await until { session.personalState(id)?.starred == true }
    try check(session.personalState(id)?.favorite == false, "star action overwrote remote favorite")
    // Durable progress restored against a fresh revision must merge even without a 409.
    library.writeState(.init(entityId: id, favorite: false, starred: true,
      progress: .init(mediaId: session.entities.first { $0.id == id }!.media[0].id, pageIndex: 5, completed: false)), progressOnly: true)
    await library.persistStatesNow(); library.reset()
    engine.lock.withLock {
      engine.states[0]["favorite"] = true; engine.states[0]["starred"] = false
      engine.states[0]["revision"] = 6; engine.generation += 1
    }
    try await session.synchronize(force: true)
    let beforeRestoreWrites = engine.writes
    await library.restoreStateOutbox(); library.flushStates()
    try await until { session.personalState(id)?.progress?.pageIndex == 5 }
    try check(engine.writes == beforeRestoreWrites + 1, "fresh outbox recovery unnecessarily conflicted")
    try check(session.personalState(id)?.favorite == true && session.personalState(id)?.starred == false,
      "restored progress overwrote another device's flags without a conflict")
    // Rejected/throttled writes survive locally and a flush cannot bypass Retry-After.
    engine.lock.withLock { engine.rejectWrites = true }
    let beforeThrottleWrites = engine.writes
    library.writeState(.init(entityId: id, favorite: true, starred: true), immediate: true)
    try await until { engine.writes == beforeThrottleWrites + 1 }
    try await Task.sleep(for: .milliseconds(100)); library.flushStates()
    try await Task.sleep(for: .milliseconds(100))
    try check(engine.writes == beforeThrottleWrites + 1, "flush bypassed Retry-After")
    library.reset()
    engine.lock.withLock { engine.rejectWrites = false }
    await library.restoreStateOutbox(); library.flushStates()
    try await until { session.personalState(id)?.starred == true }
    // Delete tombstones and eventual physical absence both remove visible entries.
    engine.lock.withLock {
      let i = engine.records.firstIndex { $0["id"] as? String == id }!
      engine.records[i]["deleted"] = true; engine.records[i]["revision"] = 3; engine.generation += 1
    }
    try await session.synchronize(force: true)
    try check(session.entities.first { $0.id == id }?.deleted == true, "tombstone missed")
    engine.lock.withLock { engine.records.removeAll { $0["id"] as? String == id }; engine.generation += 1 }
    try await session.synchronize(force: true)
    try check(!session.entities.contains { $0.id == id }, "manifest absence resurrected a deleted record")
    // More than one page of changed records: failure must not publish a partial result.
    let oldCount = session.entities.count
    engine.lock.withLock {
      let source = engine.records.first { $0["kind"] as? String == "author" }!
      for i in 0..<201 { var value = source; value["id"] = "new-\(i)"; engine.records.append(value) }
      engine.generation += 1; engine.failBatch = engine.batches + 2; engine.batchLimit = 40
    }
    do { try await session.synchronize(force: true); throw LoginError.server("Expected batch rejection") }
    catch let error as APIError { try check(error.status == 503, "unexpected batch error") }
    try check(session.entities.count == oldCount, "failed batch published a partial catalog")
    let manifestsBeforeBackoff = engine.manifests
    do { try await session.synchronize(); throw LoginError.server("Expected cooldown") }
    catch let error as APIError { try check(error.status == 429, "cooldown did not report a retry delay") }
    try check(engine.manifests == manifestsBeforeBackoff, "automatic sync ignored retry backoff")
    engine.failBatch = 0
    try await session.synchronize(force: true)
    try check(session.entities.count == oldCount + 201, "paged retry failed")
    // An idle return schedules one cheap check; active Mac use has no short poll.
    session.startAutomaticRefresh()
    session.noteActivity(now: Date().addingTimeInterval(-601))
    let beforeIdle = engine.manifests
    session.noteActivity()
    try await until { engine.manifests == beforeIdle + 1 }
    try await Task.sleep(for: .milliseconds(100))
    try check(engine.manifests == beforeIdle + 1, "idle refresh repeated")
    // A newer local receipt must win over a response fetched before that write.
    let concurrentID = "c0-1"
    engine.lock.withLock {
      let i = engine.records.firstIndex { $0["id"] as? String == concurrentID }!
      engine.records[i]["revision"] = 2; engine.records[i]["title"] = "Older reply"; engine.generation += 1
    }
    let previousBatches = engine.batches
    let concurrent = Task { try await session.synchronize(force: true) }
    try await until { engine.batches > previousBatches }
    let position = session.entities.firstIndex { $0.id == concurrentID }!
    session.entities[position].revision = 3; session.entities[position].title = "Newer local receipt"
    try await concurrent.value
    try check(session.entities[position].title == "Newer local receipt", "in-flight response rolled back a newer local write")
    let oldManifestCount = engine.manifests
    let replaced = Task { try await session.synchronize(force: true) }
    try await until { engine.manifests > oldManifestCount }
    session.signOut()
    do { try await replaced.value } catch { }
    try check(session.account == nil && session.entities.isEmpty && session.states.isEmpty, "signed-out account was repopulated by an old response")
    print("PASS: single-flight manifest/304; selective chapter/state fetch; no unchanged UI invalidation; progress coalescing; targeted conflict merge; durable outbox/retry-after; tombstones/absence; atomic/deferred multi-batch retry; Mac idle refresh; concurrent-write/sign-out isolation. No production API calls.")
  }
}
