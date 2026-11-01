import Foundation
import XCTest
@testable import MangaCore

private final class PatchProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  nonisolated(unsafe) static var requests: [URLRequest] = []
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sync.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var captured = request
    if captured.httpBody == nil, let stream = captured.httpBodyStream {
      stream.open(); defer { stream.close() }
      var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
      while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
      captured.httpBody = data
    }
    Self.lock.lock(); Self.requests.append(captured); Self.lock.unlock()
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("{\"id\":\"chapter\",\"revision\":8,\"updatedAt\":\"new\",\"title\":\"Changed\"}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class SyncAPITests: XCTestCase {
  func testPatchAndReceiptDoNotTransferUnchangedMedia() async throws {
    var input = MetadataInput(kind: .chapter, title: "Before", media: [.init(language: "ja", kind: "images", storageRootId: "root", relativePaths: (0..<1000).map { "Author/Comic/Chapter/\($0).png" }, pageCount: 1000)])
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
    json.merge(["id": "chapter", "revision": 7, "updatedAt": "old", "deleted": false]) { _, v in v }
    let entity = try JSONDecoder().decode(LibraryEntity.self, from: JSONSerialization.data(withJSONObject: json))
    input.title = "Changed"
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PatchProtocol.self]
    let transport = URLSession(configuration: config); defer { transport.invalidateAndCancel() }
    let api = APIClient(base: URL(string: "https://sync.test")!, transport: transport) { "token" }
    let updated = try await api.update(entity, input: input)
    XCTAssertEqual(updated.revision, 8); XCTAssertEqual(updated.media[0].relativePaths.count, 1000)
    let request = PatchProtocol.lock.withLock { PatchProtocol.requests.last }
    XCTAssertEqual(request?.httpMethod, "PATCH"); XCTAssertEqual(request?.value(forHTTPHeaderField: "If-Match"), "7")
    XCTAssertLessThan(request?.httpBody?.count ?? Int.max, 100)
  }
  func testAppendTranslationPageIsBoundedAndUsesSparseAlignmentChanges() throws {
    var input = MetadataInput(kind: .chapter, title: "Chapter", media: [.init(language: "zh", kind: "images", storageRootId: "root", relativePaths: (0..<1000).map { "Folder/\($0).png" }, pageCount: 1000)])
    input.media[0].pageAlignment = Array(0..<1000).map { Optional($0) }
    var after = input
    after.media[0].relativePaths.append("Folder/new.png"); after.media[0].pageCount += 1
    after.media[0].pageAlignment![50] = 1000
    let data = try MetadataPatch.data(from: input, to: after)
    XCTAssertLessThan(data.count, 350)
    let operations = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    XCTAssertTrue(operations.contains { $0["path"] as? String == "/media/0/relativePaths/-" })
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Folder/999.png"))
    XCTAssertEqual(try MetadataPatch.data(from: input, to: input), Data("[]".utf8))
  }
  func testCompactMediaDecodeExpandsPathsAndCachesLegacyFormat() throws {
    let data = Data("{\"id\":\"m\",\"language\":\"zh\",\"kind\":\"images\",\"storageRootId\":\"r\",\"pathDirectory\":\"作者/Chapter\",\"pathFiles\":[\"1.png\",\"nested/2.png\"],\"pageCount\":2,\"pageAlignment\":[0,null,1]}".utf8)
    let media = try JSONDecoder().decode(MediaVersion.self, from: data)
    XCTAssertEqual(media.relativePaths, ["作者/Chapter/1.png", "作者/Chapter/nested/2.png"])
    let cached = try JSONSerialization.jsonObject(with: JSONEncoder().encode(media)) as! [String: Any]
    XCTAssertNotNil(cached["relativePaths"]); XCTAssertNil(cached["pathFiles"])
    XCTAssertEqual(media.pageAlignment!, [0, nil, 1])
  }
}
