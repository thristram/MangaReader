import XCTest
@testable import MangaCore

final class MetadataHierarchyTests: XCTestCase {
  private func entity(_ id: String, _ input: MetadataInput) throws -> LibraryEntity {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
    json.merge(["id": id, "revision": 1, "updatedAt": "fixture", "deleted": false]) { _, new in new }
    return try JSONDecoder().decode(LibraryEntity.self, from: JSONSerialization.data(withJSONObject: json))
  }
  func testReassignChapterInheritsDestinationParentsWithoutChangingMediaOrText() throws {
    let old = try entity("old", .init(kind: .work, title: "Old", authorId: "a", seriesId: "s"))
    let new = try entity("new", .init(kind: .work, title: "New", authorId: "b", seriesId: "t"))
    var chapter = MetadataInput(kind: .chapter, title: "Chapter", description: "Original text",
      authorId: "a", seriesId: "s", workId: "old", media: [
        .init(language: "ja", kind: "images", storageRootId: "root", relativePaths: ["Old/1.png"], pageCount: 1)])
    chapter.localizations["zh"] = .init(title: "译名")
    let result = try MetadataHierarchy.selecting(.work, id: "new", in: chapter, entities: [old, new])
    XCTAssertEqual(result.workId, "new")
    XCTAssertEqual(result.authorId, "b")
    XCTAssertEqual(result.seriesId, "t")
    XCTAssertEqual(result.media[0].relativePaths, chapter.media[0].relativePaths)
    XCTAssertEqual(result.localizations, chapter.localizations)
    XCTAssertEqual(result.description, chapter.description)
    chapter.workId = "new" // Save also normalizes a programmatically changed binding.
    XCTAssertEqual(try MetadataHierarchy.normalized(chapter, entities: [old, new]).authorId, "b")
  }
  func testSeriesAndAuthorSelectionsClearIncompatibleParentsAndAllowStandalone() throws {
    let series = try entity("s", .init(kind: .series, title: "Series", authorId: "b"))
    let work = try entity("w", .init(kind: .work, title: "Comic", authorId: "a"))
    let chapter = MetadataInput(kind: .chapter, title: "Chapter", authorId: "a", workId: "w")
    let selected = try MetadataHierarchy.selecting(.series, id: "s", in: chapter, entities: [series, work])
    XCTAssertEqual(selected.authorId, "b")
    XCTAssertNil(selected.workId)
    let author = try entity("a", .init(kind: .author, title: "Author"))
    let changed = try MetadataHierarchy.selecting(.author, id: "a", in: selected, entities: [series, work, author])
    XCTAssertNil(changed.seriesId)
    let standalone = try MetadataHierarchy.selecting(.work, id: nil, in: chapter, entities: [work])
    XCTAssertNil(standalone.workId)
    XCTAssertEqual(standalone.authorId, "a")
  }
  func testUnavailableOrDeletedDestinationCannotSilentlyReuseOldComic() throws {
    let chapter = MetadataInput(kind: .chapter, title: "Chapter", workId: "gone")
    XCTAssertThrowsError(try MetadataHierarchy.normalized(chapter, entities: []))
    var deleted = try entity("gone", .init(kind: .work, title: "Gone")); deleted.deleted = true
    XCTAssertThrowsError(try MetadataHierarchy.selecting(.work, id: "gone", in: chapter, entities: [deleted]))
  }
}
