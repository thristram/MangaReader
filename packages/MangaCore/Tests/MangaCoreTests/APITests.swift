import Foundation
import XCTest

@testable import MangaCore

private final class DeleteResponseProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "delete.test"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let isValid =
      request.httpMethod == "DELETE" && request.value(forHTTPHeaderField: "If-Match") == "7"
      && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
    let code = isValid && request.url?.lastPathComponent == "tag" ? 204 : 409
    let response = HTTPURLResponse(
      url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if code != 204 {
      client?.urlProtocol(
        self, didLoad: Data("{\"error\":{\"message\":\"Entity is referenced\"}}".utf8))
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class APITests: XCTestCase {
  private func fixture(_ id: String) throws -> LibraryEntity {
    var json =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(MetadataInput(kind: .tag, title: "Tag"))) as! [String: Any]
    json["id"] = id
    json["revision"] = 7
    json["deleted"] = false
    json["updatedAt"] = "fixture"
    return try JSONDecoder().decode(
      LibraryEntity.self, from: JSONSerialization.data(withJSONObject: json))
  }
  func testDeleteAcceptsEmpty204AndPreservesRevisionAndReferenceConflicts() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeleteResponseProtocol.self]
    let transport = URLSession(configuration: configuration)
    defer { transport.invalidateAndCancel() }
    let client = APIClient(base: URL(string: "https://delete.test")!, transport: transport) {
      "fixture-token"
    }
    try await client.delete(fixture("tag"))
    do {
      try await client.delete(fixture("referenced"))
      XCTFail("Referenced entity must not be deleted")
    } catch let error as APIError {
      XCTAssertEqual(error.status, 409)
      XCTAssertEqual(error.message, "Entity is referenced")
    }
  }
}
