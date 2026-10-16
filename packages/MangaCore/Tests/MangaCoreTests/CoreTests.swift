import CryptoKit
import XCTest

@testable import MangaCore

final class CoreTests: XCTestCase {
  func testDestinationMarkerMatchesAcrossTransportsAndRefusesOtherLibraries() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try LibraryDestinationIdentity.bind(
      folder: directory, libraryId: "library-a", destinationId: "root-a")
    let marker = directory.appendingPathComponent(LibraryDestinationIdentity.filename)
    let bytes = try Data(contentsOf: marker)
    let remoteMarker = try JSONDecoder().decode(LibraryDestinationIdentity.self, from: bytes)
    try remoteMarker.validate(libraryId: "library-a", destinationId: "root-a")
    try LibraryDestinationIdentity.bind(
      folder: directory, libraryId: "library-a", destinationId: "root-a")
    XCTAssertThrowsError(
      try LibraryDestinationIdentity.bind(
        folder: directory, libraryId: "library-b", destinationId: "root-a"))
    XCTAssertThrowsError(
      try LibraryDestinationIdentity.bind(
        folder: directory, libraryId: "library-a", destinationId: "root-b"))
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
    var newer = remoteMarker
    newer.version = 2
    XCTAssertThrowsError(try newer.validate(libraryId: "library-a", destinationId: "root-a"))
    try Data("invalid".utf8).write(to: marker)
    XCTAssertThrowsError(
      try LibraryDestinationIdentity.bind(
        folder: directory, libraryId: "library-a", destinationId: "root-a"))
    XCTAssertEqual(try Data(contentsOf: marker), Data("invalid".utf8))
  }
  func testMousePagingIgnoresVerticalAndDebouncesMomentum() {
    var gesture = HorizontalPageGesture()
    XCTAssertNil(gesture.consume(dx: 10, dy: 50, time: 0))
    XCTAssertNil(gesture.consume(dx: -20, dy: 0, time: 0))
    XCTAssertEqual(gesture.consume(dx: -30, dy: 0, time: 0.05), 1)
    XCTAssertNil(gesture.consume(dx: -90, dy: 0, time: 0.15))
    XCTAssertEqual(gesture.consume(dx: 50, dy: 0, time: 0.6), -1)
    XCTAssertNil(gesture.consume(dx: -30, dy: 0, time: 1.1))
    XCTAssertNil(gesture.consume(dx: 0, dy: 0, time: 1.2, ended: true))
    XCTAssertNil(gesture.consume(dx: -20, dy: 0, time: 1.3))
  }
  func testNewSourcesChooseUnusedProvider() {
    XCTAssertEqual(SourceLink.nextUnusedSite(in: []), "pixiv")
    XCTAssertEqual(SourceLink.nextUnusedSite(in: [.init(site: "pixiv", value: "")]), "fanbox")
    XCTAssertEqual(
      SourceLink.nextUnusedSite(in: [
        .init(site: "pixiv", value: "1"), .init(site: "fanbox", value: "2"),
      ]), "patreon")
  }
  private func fixture(_ id: String, _ input: MetadataInput, deleted: Bool = false) throws
    -> LibraryEntity
  {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
    json["id"] = id
    json["revision"] = 4
    json["deleted"] = deleted
    json["updatedAt"] = "fixture"
    return try JSONDecoder().decode(
      LibraryEntity.self, from: JSONSerialization.data(withJSONObject: json))
  }
  func testAuthorRemovalReassignsParentsFirstAndPreservesContentAndHiddenState() throws {
    var authorInput = MetadataInput(kind: .author, title: "Old author")
    authorInput.nsfw = true
    authorInput.tagIds = ["inherited"]
    let author = try fixture("author", authorInput)
    let series = try fixture("series", .init(kind: .series, title: "Series", authorId: author.id))
    let work = try fixture(
      "work", .init(kind: .work, title: "Comic", authorId: author.id, seriesId: series.id))
    var input = MetadataInput(
      kind: .chapter, title: "Chapter", description: "Keep description",
      authorId: author.id, seriesId: series.id, workId: work.id,
      media: [
        .init(
          language: "ja", kind: "images", storageRootId: "root",
          relativePaths: ["Old author/Chapter/1.png"], pageCount: 1)
      ])
    input.localizations["zh"] = .init(title: "Translated", description: "Localized text")
    input.tagIds = ["own", "inherited"]
    let chapter = try fixture("chapter", input)
    let deleted = try fixture("deleted", input, deleted: true)
    let changes = AuthorRemovalPlan.updates(
      for: author, replacement: "fallback",
      entities: [chapter, work, deleted, series])
    XCTAssertEqual(changes.map { $0.0.id }, ["series", "work", "chapter"])
    for (_, changed) in changes {
      XCTAssertEqual(changed.authorId, "fallback")
      XCTAssertTrue(changed.nsfw)
    }
    let changed = changes.last!.1
    XCTAssertEqual(changed.workId, work.id)
    XCTAssertEqual(changed.seriesId, series.id)
    XCTAssertEqual(changed.description, input.description)
    XCTAssertEqual(changed.localizations, input.localizations)
    XCTAssertEqual(changed.tagIds, input.tagIds)
    XCTAssertEqual(changed.media[0].relativePaths, input.media[0].relativePaths)
    XCTAssertEqual(changed.media[0].id, input.media[0].id)
    XCTAssertTrue(
      AuthorRemovalPlan.updates(for: author, replacement: author.id, entities: [chapter]).isEmpty)
  }
  func testDeletingTagOnlyDetachesReferencesIncludingHiddenComics() throws {
    var input = MetadataInput(
      kind: .chapter, title: "Keep comic", description: "Preserve description")
    input.nsfw = true
    input.tagIds = ["remove", "keep"]
    input.media = [
      .init(
        language: "ja", kind: "images", storageRootId: "root", relativePaths: ["1.jpg"],
        pageCount: 1)
    ]
    let chapter = try fixture("chapter", input)
    let deleted = try fixture("deleted", input, deleted: true)
    let plan = TagRemovalPlan.updates(for: "remove", entities: [chapter, deleted])
    XCTAssertEqual(plan.count, 1)
    XCTAssertEqual(plan[0].0.id, "chapter")
    var expected = input
    expected.tagIds = ["keep"]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    XCTAssertEqual(try encoder.encode(plan[0].1), try encoder.encode(expected))
    XCTAssertFalse(
      try fixture(
        "source",
        .init(
          kind: .storageRoot, title: "Import",
          description: LibraryDestinationIdentity.sourceOnlyDescription, storageKind: "local")
      ).isArchiveDestination)
    XCTAssertTrue(
      try fixture("destination", .init(kind: .storageRoot, title: "Archive", storageKind: "local"))
        .isArchiveDestination)
  }
  func testOptionalPathAndMediaLanguageIndependence() throws {
    XCTAssertEqual(
      try PathPolicy.chapterPath(
        author: nil, series: nil, work: nil, chapter: "Chapter 1", language: "zh",
        mediaLanguageCount: 1), "other author/Chapter 1")
    XCTAssertEqual(
      try PathPolicy.chapterPath(
        author: "A", series: "S", work: nil, chapter: "C", language: "ja", mediaLanguageCount: 2),
      "A/S/C/ja")
    XCTAssertThrowsError(
      try PathPolicy.chapterPath(
        author: "../A", series: nil, work: nil, chapter: "C", language: nil, mediaLanguageCount: 1))
  }
  func testTraversalAndSymlinkEscape() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertThrowsError(try PathPolicy.resolve("../escape", under: dir))
    XCTAssertThrowsError(try PathPolicy.resolve("/escape", under: dir))
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
    XCTAssertThrowsError(try PathPolicy.resolve("outside/page.jpg", under: dir))
  }
  func testNaturalImportAndNestedFolders() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["10.jpg", "2.jpg", "1.png"] {
      try Data().write(to: dir.appendingPathComponent(name))
    }
    let results = try ImportScanner.scan(dir)
    XCTAssertEqual(results[0].pages.map(\.lastPathComponent), ["1.png", "2.jpg", "10.jpg"])
  }
  func testMoveRefusesOverwriteAndJournals() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = dir.appendingPathComponent("library")
    let source = dir.appendingPathComponent("incoming")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("original".utf8).write(to: source.appendingPathComponent("1.jpg"))
    let journals = dir.appendingPathComponent("journals")
    let journal = try FileCommit.move(
      source: source, destinationRelativePath: "A/C", root: root, journalDirectory: journals)
    XCTAssertEqual(journal.phase, "filesMoved_metadataPending")
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("A/C/1.jpg"), encoding: .utf8), "original")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try FileCommit.move(
        source: source, destinationRelativePath: "A/C", root: root, journalDirectory: journals))
  }
  func testIdentitySignatureNonceAndAudience() throws {
    let key = Curve25519.Signing.PrivateKey()
    let header = Base64URL.encode(
      try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "kid": "test"]))
    let payload = Base64URL.encode(
      try JSONSerialization.data(withJSONObject: [
        "iss": "https://auth.test/api/auth", "sub": "user", "aud": "mac", "nonce": "nonce",
        "exp": Date().timeIntervalSince1970 + 300, "iat": Date().timeIntervalSince1970,
      ]))
    let signing = "\(header).\(payload)"
    let token = signing + "." + Base64URL.encode(try key.signature(for: Data(signing.utf8)))
    let jwks = try JSONSerialization.data(withJSONObject: [
      "keys": [
        [
          "kid": "test", "kty": "OKP", "crv": "Ed25519",
          "x": Base64URL.encode(key.publicKey.rawRepresentation),
        ]
      ]
    ])
    XCTAssertEqual(
      try IDTokenValidator.validate(
        token, jwks: jwks, issuer: "https://auth.test/api/auth", clientId: "mac", nonce: "nonce"),
      "user")
    XCTAssertThrowsError(
      try IDTokenValidator.validate(
        token, jwks: jwks, issuer: "https://auth.test/api/auth", clientId: "phone", nonce: "nonce"))
    XCTAssertThrowsError(
      try IDTokenValidator.validate(
        token, jwks: jwks, issuer: "https://auth.test/api/auth", clientId: "mac", nonce: "wrong"))
    XCTAssertThrowsError(
      try IDTokenValidator.validate(
        token + "x", jwks: jwks, issuer: "https://auth.test/api/auth", clientId: "mac",
        nonce: "nonce"))
  }
}

extension CoreTests {
  func testFormEncodingAndOwnerNamespace() {
    let body = String(
      data: OAuthForm.encode(["refresh_token": "a+b&c=", "scope": "manga:read manga:state:write"]),
      encoding: .utf8)!
    XCTAssertTrue(body.contains("refresh_token=a%2Bb%26c%3D"))
    XCTAssertTrue(body.contains("scope=manga%3Aread%20manga%3Astate%3Awrite"))
    XCTAssertNotEqual(
      AccountIdentity.ownerId(issuer: "https://one.test", subject: "alice"),
      AccountIdentity.ownerId(issuer: "https://two.test", subject: "alice"))
    XCTAssertEqual(AccountIdentity.ownerId(issuer: "https://one.test", subject: "alice").count, 64)
  }
  func testIndependentTextFallbackAndInheritedVisibility() throws {
    let original = """
      {"id":"c","kind":"chapter","title":"Original","originalLanguage":"ja","description":"Original description","localizations":{"zh":{"title":"中文标题"}},"authorId":"a","tagIds":[],"nsfw":false,"sources":[],"media":[],"revision":1,"updatedAt":"2026-10-13T00:00:00Z","deleted":false}
      """
    var chapter = try JSONDecoder().decode(LibraryEntity.self, from: Data(original.utf8))
    XCTAssertEqual(chapter.title(in: "zh"), "中文标题")
    XCTAssertEqual(chapter.description(in: "zh"), "Original description")
    var author = chapter
    author.id = "a"
    author.kind = .author
    author.authorId = nil
    author.nsfw = true
    XCTAssertFalse(Visibility.visible(chapter, in: [chapter, author], showNSFW: false))
    XCTAssertTrue(Visibility.visible(chapter, in: [chapter, author], showNSFW: true))
    chapter.deleted = true
    XCTAssertFalse(Visibility.visible(chapter, in: [chapter, author], showNSFW: true))
  }
}

// Missing aligned translations must never silently reuse the same numeric page.
extension CoreTests {
  func testCanonicalMediaAlignment() {
    var media = MediaVersion(
      language: "zh", kind: "images", storageRootId: "root", relativePaths: ["a.png", "b.png"],
      pageCount: 2)
    XCTAssertEqual(media.sourcePage(at: 1), 1)
    XCTAssertNil(media.sourcePage(at: 2))
    media.pageAlignment = [1, nil, 0, 99, -1]
    XCTAssertEqual(media.sourcePage(at: 0), 1)
    XCTAssertNil(media.sourcePage(at: 1))
    XCTAssertEqual(media.sourcePage(at: 2), 0)
    XCTAssertNil(media.sourcePage(at: 3))
    XCTAssertNil(media.sourcePage(at: 4))
    XCTAssertNil(media.sourcePage(at: 5))
    XCTAssertNil(media.sourcePage(at: -1))
  }
}
