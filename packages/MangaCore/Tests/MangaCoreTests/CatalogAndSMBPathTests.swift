import XCTest

@testable import MangaCore

final class CatalogAndSMBPathTests: XCTestCase {
  private func entity(_ id: String, _ input: MetadataInput, deleted: Bool = false) throws
    -> LibraryEntity
  {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
    json["id"] = id
    json["revision"] = 1
    json["updatedAt"] = "fixture"
    json["deleted"] = deleted
    return try JSONDecoder().decode(
      LibraryEntity.self, from: JSONSerialization.data(withJSONObject: json))
  }
  func testCatalogKeepsEveryChapterInOrderAndPropagatesHiddenCycles() throws {
    let work = try entity("work", .init(kind: .work, title: "Long work"))
    var source = [work]
    for index in 0..<2000 {
      source.append(
        try entity("chapter-\(index)", .init(kind: .chapter, title: "\(index)", workId: work.id)))
    }
    var a = MetadataInput(kind: .work, title: "A", seriesId: "b")
    a.nsfw = true
    source += [try entity("a", a), try entity("b", .init(kind: .series, title: "B", workId: "a"))]
    source.append(try entity("child", .init(kind: .chapter, title: "Hidden", workId: "b")))
    var removed = MetadataInput(kind: .tag, title: "Removed")
    removed.nsfw = true
    source.append(try entity("removed", removed, deleted: true))
    var clean = MetadataInput(kind: .chapter, title: "Visible")
    clean.tagIds = ["removed"]
    source.append(try entity("clean", clean))
    let catalog = LibraryCatalog(source)
    let chapters = catalog.chapters(for: work, showNSFW: false)
    XCTAssertEqual(chapters.count, 2000)
    XCTAssertEqual(chapters.last?.id, "chapter-1999")
    XCTAssertEqual(catalog.search(kind: .chapter, query: "", limit: 7, showNSFW: false).count, 7)
    XCTAssertEqual(catalog.search(kind: .chapter, query: "1999", limit: 7, showNSFW: false).first?.id, "chapter-1999")
    XCTAssertTrue(catalog.search(kind: .chapter, query: "", limit: 0, showNSFW: true).isEmpty)
    for id in ["a", "b", "child"] { XCTAssertNil(catalog.entity(id, showNSFW: false)) }
    XCTAssertNotNil(catalog.entity("clean", showNSFW: false))
    XCTAssertNil(catalog.entity("removed", showNSFW: true))
    XCTAssertNotNil(catalog.entity("a", showNSFW: true))
    for entity in source {
      XCTAssertEqual(
        catalog.entity(entity.id, showNSFW: false) != nil,
        Visibility.visible(entity, in: source, showNSFW: false), entity.id)
    }
  }
  func testSMBWalkResolvesDecomposedJapaneseAtEveryLevelWithoutChangingMetadata() async throws {
    let chapter = "7. 敵の蟲が体に巻付くが洗脳されてるので喜ぶ美雪"
    let original = "Personal/作家/\(chapter)/07-01.jpg".decomposedStringWithCanonicalMapping
    let namespace: [Data: [SMBReadPath.Entry]] = [
      Data("/".utf8): [.init(name: "Personal", directory: true)],
      Data("Personal".utf8): [.init(name: "作家", directory: true)],
      Data("Personal/作家".utf8): [.init(name: chapter, directory: true)],
      Data("Personal/作家/\(chapter)".utf8): [.init(name: "07-01.jpg", directory: false)],
    ]
    let resolved = try await SMBReadPath.resolve(original) { path in
      namespace[Data(path.utf8)] ?? []
    }
    XCTAssertEqual(Data(resolved.utf8), Data("Personal/作家/\(chapter)/07-01.jpg".utf8))
    XCTAssertNotEqual(Data(original.utf8), Data(resolved.utf8))
  }
  func testSMBExactBytesWinOverCanonicalEquivalent() async throws {
    let nfc = "が.jpg"
    let nfd = nfc.decomposedStringWithCanonicalMapping
    let resolved = try await SMBReadPath.resolve(nfd) { _ in
      [.init(name: nfc, directory: false), .init(name: nfd, directory: false)]
    }
    XCTAssertEqual(Data(resolved.utf8), Data(nfd.utf8))
  }
  func testSMBDoesNotListOutsideTheConfiguredBaseFolder() async throws {
    let resolved = try await SMBReadPath.resolve("か\u{3099}.jpg", under: "private/library") {
      path in
      guard path == "private/library" else { throw POSIXError(.EACCES) }
      return [.init(name: "が.jpg", directory: false)]
    }
    XCTAssertEqual(Data(resolved.utf8), Data("private/library/が.jpg".utf8))
  }
  func testSMBRefusesAmbiguousCanonicalNamesMissingPathsAndTraversal() async throws {
    // Three distinct combining-mark arrangements with the same canonical form.
    let request = "a\u{301}\u{323}.jpg"
    do {
      _ = try await SMBReadPath.resolve(request) { _ in
        [
          .init(name: "ạ\u{301}.jpg", directory: false),
          .init(name: "á\u{323}.jpg", directory: false),
        ]
      }
      XCTFail("Ambiguous names must not select an arbitrary image")
    } catch SMBReadPath.Failure.ambiguous {} catch { XCTFail("\(error)") }
    do {
      _ = try await SMBReadPath.resolve("missing.jpg") { _ in
        [.init(name: "similar.jpg", directory: false)]
      }
      XCTFail("No fuzzy filename matching")
    } catch SMBReadPath.Failure.missing {} catch { XCTFail("\(error)") }
    for path in [
      "../file", "base/../file", "/absolute", "base//file", "a\\b", "a\0b", "file:stream",
    ] {
      XCTAssertThrowsError(try SMBReadPath.components(path))
    }
  }
  func testSMBPermissionErrorIsPreserved() async throws {
    do {
      _ = try await SMBReadPath.resolve("folder/file") { _ in throw POSIXError(.EACCES) }
      XCTFail("Permission errors must propagate")
    } catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
  }
  func testPermitCancellationDoesNotLeakOrStartQueuedWork() async throws {
    let pool = AsyncPermitPool(limit: 1)
    try await pool.acquire()
    let cancelled = Task { try await pool.acquire() }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()
    do {
      try await cancelled.value
      XCTFail("Cancelled waiter ran")
    } catch is CancellationError {}
    await pool.release()
    try await pool.acquire()
    await pool.release()
    let alreadyCancelled = Task {
      try await Task.sleep(for: .seconds(10))
      try await pool.acquire()
    }
    alreadyCancelled.cancel()
    do {
      try await alreadyCancelled.value
      XCTFail()
    } catch is CancellationError {}
    try await pool.acquire()
    await pool.release()
  }
}
