import CryptoKit
import XCTest

@testable import MangaCore

final class CoreTests: XCTestCase {
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
    var media = MediaVersion(language: "zh", kind: "images", storageRootId: "root", relativePaths: ["a.png", "b.png"], pageCount: 2)
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
