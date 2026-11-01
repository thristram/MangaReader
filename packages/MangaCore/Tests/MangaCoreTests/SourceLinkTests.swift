import XCTest
@testable import MangaCore

final class SourceLinkTests: XCTestCase {
  func testAuthorIDsUseProfileRoutesWhileChapterIDsUsePostRoutes() {
    let pixiv = SourceLink(site: "pixiv", value: " 12345 ")
    XCTAssertEqual(pixiv.destinationURL(author: true)?.absoluteString, "https://www.pixiv.net/users/12345")
    XCTAssertEqual(pixiv.destinationURL()?.absoluteString, "https://www.pixiv.net/artworks/12345")
    let fanbox = SourceLink(site: "fanbox", value: "my-creator")
    XCTAssertEqual(fanbox.destinationURL(author: true)?.absoluteString, "https://my-creator.fanbox.cc")
    XCTAssertEqual(SourceLink(site: "fanbox", value: "678").destinationURL()?.absoluteString,
      "https://www.fanbox.cc/posts/678")
    XCTAssertEqual(SourceLink(site: "patreon", value: "creator").destinationURL(author: true)?.absoluteString,
      "https://www.patreon.com/creator")
    XCTAssertEqual(SourceLink(site: "ehentai", value: "12345/token").destinationURL(author: true)?.absoluteString,
      "https://e-hentai.org/g/12345/token")
  }
  func testExplicitHTTPSLinksKeepTheirFullPathAndQuery() {
    let value = "https://creator.fanbox.cc/posts/123?locale=en#content"
    XCTAssertEqual(SourceLink(site: "fanbox", value: value).destinationURL(author: true)?.absoluteString, value)
    XCTAssertNil(SourceLink(site: "fanbox", value: "not/a/profile").destinationURL(author: true))
    XCTAssertNil(SourceLink(site: "pixiv", value: "http://example.invalid").destinationURL(author: true))
    XCTAssertNil(SourceLink(site: "pixiv", value: "file:///tmp/file").destinationURL(author: true))
    XCTAssertNil(SourceLink(site: "pixiv", value: " ").destinationURL(author: true))
    XCTAssertNil(SourceLink(site: "unknown", value: "id").destinationURL(author: true))
    XCTAssertEqual(SourceLink(site: "fanbox", value: "id").displayName, "FANBOX")
  }
}
