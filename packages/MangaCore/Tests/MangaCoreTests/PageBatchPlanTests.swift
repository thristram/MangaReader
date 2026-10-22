import XCTest
@testable import MangaCore

final class PageBatchPlanTests: XCTestCase {
  func input() -> MetadataInput {
    var original = MediaVersion(id: "ja", language: "ja", kind: "images", storageRootId: "root",
      relativePaths: ["a.png", "b.png", "c.png", "d.png"], pageCount: 4)
    original.pageAlignment = [2, 0, 3, 1]
    var translated = MediaVersion(id: "en", language: "en", kind: "images", storageRootId: "root",
      relativePaths: ["en0.png", "en1.png", "en2.png"], pageCount: 3)
    translated.pageAlignment = [2, nil, 0, 1]
    return MetadataInput(kind: .chapter, title: "Chapter", originalLanguage: "ja", description: "original text",
      authorId: "author", media: [original, translated])
  }
  func testSelectionPreservesReadingOrderAndRemapsRemainingVersions() throws {
    let plan = try PageBatchPlan(metadata: input(), mediaId: "ja", selected: [1, 3])
    XCTAssertEqual(plan.selectedIndices, [3, 1])
    XCTAssertEqual(plan.selectedPaths, ["d.png", "b.png"])
    XCTAssertEqual(plan.metadata.media[0].relativePaths, ["a.png", "c.png"])
    XCTAssertEqual(plan.metadata.media[0].pageAlignment, [1, 0])
    XCTAssertEqual(plan.metadata.media[1].pageAlignment, [2, nil])
    XCTAssertEqual(plan.metadata.media[0].pageCount, 2)
    XCTAssertEqual(plan.metadata.media[0].id, "ja")
  }
  func testTranslationIsAnUncommittedMetadataPlanWithExplicitFallback() throws {
    var plan = try PageBatchPlan(metadata: input(), mediaId: "ja", selected: [1, 3])
    try plan.setTranslation(language: "zh", alignment: [1, nil], id: "new")
    let translation = plan.metadata.media.last!
    XCTAssertEqual(translation.relativePaths, ["d.png", "b.png"])
    XCTAssertEqual(translation.sourcePage(at: 0), 1)
    XCTAssertNil(translation.sourcePage(at: 1))
    XCTAssertEqual(plan.metadata.title, "Chapter")
    XCTAssertEqual(plan.metadata.description, "original text")
    XCTAssertEqual(plan.metadata.originalLanguage, "ja")
  }
  func testEditingTranslatedImagesKeepsCanonicalOriginalAndFallback() throws {
    var plan = try PageBatchPlan(metadata: input(), mediaId: "en", selected: [0, 2])
    XCTAssertEqual(plan.selectedIndices, [2, 0])
    XCTAssertEqual(plan.metadata.media[0].relativePaths, input().media[0].relativePaths)
    XCTAssertEqual(plan.metadata.media[1].pageAlignment, [nil, nil, nil, 0])
    try plan.setTranslation(language: "zh", alignment: [1, nil, 0, nil])
    XCTAssertEqual(plan.metadata.media.last?.pageCount, 2)
  }
  func testDeletingWholeOriginalPreservesTextLocaleAndSurvivingReadingOrder() throws {
    let plan = try PageBatchPlan(metadata: input(), mediaId: "ja", selected: [0, 1, 2, 3])
    XCTAssertEqual(plan.metadata.originalLanguage, "ja")
    XCTAssertEqual(plan.metadata.media.count, 1)
    XCTAssertEqual(plan.metadata.media[0].pageAlignment, [2, 0, 1])
    XCTAssertEqual(plan.metadata.media[0].language, "en")
  }
  func testDeletingAllImagesKeepsChapterMetadataWithNoEmptyMediaVersion() throws {
    var metadata = input(); metadata.media.removeLast()
    let plan = try PageBatchPlan(metadata: metadata, mediaId: "ja", selected: [0, 1, 2, 3])
    XCTAssertTrue(plan.metadata.media.isEmpty)
    XCTAssertEqual(plan.metadata.title, metadata.title)
    var translated = plan
    XCTAssertThrowsError(try translated.setTranslation(language: "zh", alignment: []))
  }
  func testInvalidSelectionLanguageAndMappingAreRejected() throws {
    XCTAssertThrowsError(try PageBatchPlan(metadata: input(), mediaId: "ja", selected: []))
    XCTAssertThrowsError(try PageBatchPlan(metadata: input(), mediaId: "ja", selected: [100]))
    var plan = try PageBatchPlan(metadata: input(), mediaId: "ja", selected: [1, 3])
    XCTAssertThrowsError(try plan.setTranslation(language: "en", alignment: [0, 1]))
    XCTAssertThrowsError(try plan.setTranslation(language: "zh", alignment: [0, 3]))
    XCTAssertThrowsError(try plan.setTranslation(language: "zh", alignment: [0]))
    var pdf = input(); pdf.media[0].kind = "pdf"
    XCTAssertThrowsError(try PageBatchPlan(metadata: pdf, mediaId: "ja", selected: [0]))
  }
  func testWholeVersionDeletionIncludesUnalignedFilesAndNonImageMedia() throws {
    var metadata = input()
    metadata.media[1].pageAlignment = [nil, 0, nil, nil]
    let removed = try PageBatchPlan(metadata: metadata, mediaId: "en", selected: [], removeEntireVersion: true)
    XCTAssertEqual(removed.selectedIndices, [0, 1, 2])
    XCTAssertEqual(removed.metadata.media.map(\.id), ["ja"])
    for kind in ["pdf", "video"] {
      metadata.media = [MediaVersion(id: kind, language: "ja", kind: kind, storageRootId: "root",
        relativePaths: ["Author/Chapter/file." + kind], pageCount: kind == "pdf" ? 10 : 1)]
      let plan = try PageBatchPlan(metadata: metadata, mediaId: kind, selected: [], removeEntireVersion: true)
      XCTAssertTrue(plan.metadata.media.isEmpty)
      XCTAssertEqual(plan.selectedPaths.count, 1)
    }
  }
  func testAppendPreservesReadingOrderAndExtendsFallback() throws {
    let plan = try PageAppendPlan(metadata: input(), language: "ja", rootId: "root", paths: ["e.png", "f.png"])
    XCTAssertEqual(plan.metadata.media[0].pageAlignment, [2, 0, 3, 1, 4, 5])
    XCTAssertEqual(plan.metadata.media[1].pageAlignment, [2, nil, 0, 1, nil, nil])
    XCTAssertEqual(plan.metadata.media[0].pageCount, 6)
    XCTAssertEqual(plan.mediaId, "ja")
    XCTAssertEqual(plan.metadata.description, input().description)
    let translation = try PageAppendPlan(metadata: input(), language: "zh", rootId: "root", paths: ["zh.png"])
    XCTAssertEqual(translation.metadata.media.last?.pageAlignment, [0, nil, nil, nil])
    var empty = input(); empty.media = []
    let recreated = try PageAppendPlan(metadata: empty, language: "zh", rootId: "root", paths: ["zh.png"])
    XCTAssertEqual(recreated.metadata.media.first?.pageCount, 1)
    XCTAssertEqual(recreated.metadata.media.first?.pageAlignment, [0])
  }

}
