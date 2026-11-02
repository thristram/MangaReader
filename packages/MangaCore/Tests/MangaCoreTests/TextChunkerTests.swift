import XCTest
@testable import MangaCore

final class TextChunkerTests: XCTestCase {
  func testNovelIsLosslessBoundedAndNeverCrossesChapterMarkers() throws {
    let source = "前書き。\n\n" + (1...4).map { "[chapter:第\($0)章]\n" + String(repeating: "「雨が降っている。」彼女は空を見た。\n\n", count: 450) }.joined()
    let chunks = try TextChunker.chunks(source, maximum: 1500)
    XCTAssertGreaterThan(source.count, 34592)
    XCTAssertEqual(chunks.joined(), source)
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 1500 })
    for chunk in chunks {
      let count = chunk.components(separatedBy: "[chapter:").count - 1
      XCTAssertLessThanOrEqual(count, 1)
      if count == 1 { XCTAssertTrue(chunk.hasPrefix("[chapter:")) }
    }
  }
  func testParagraphAndSentenceBoundariesKeepQuotesAndWhitespace() throws {
    let source = "「こんにちは。」\n\n次の段落です。終わりです。\n"
    let chunks = try TextChunker.chunks(source, maximum: 13)
    XCTAssertEqual(chunks.joined(), source)
    XCTAssertFalse(chunks.contains { $0.hasPrefix("」") })
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 13 })
    XCTAssertEqual(try TextChunker.chunks("短い段落。\n", maximum: 100), ["短い段落。\n"])
    let decimal = try TextChunker.chunks("先。価格は3.14円です。次です。", maximum: 12)
    XCTAssertFalse(decimal.contains { $0.hasSuffix("3.") })
    XCTAssertEqual(decimal.joined(), "先。価格は3.14円です。次です。")
  }
  func testOversizedSentenceFailsInsteadOfTruncatingOrSplittingWords() throws {
    XCTAssertThrowsError(try TextChunker.chunks(String(repeating: "あ", count: 1501), maximum: 1500))
    XCTAssertEqual(try TextChunker.chunks("", maximum: 100), [])
  }
  func testUnicodeDisplayBlocksReconstructExactly() {
    let source = String(repeating: "👨‍👩‍👧‍👦が\r\n", count: 10000)
    let blocks = TextChunker.displayBlocks(source)
    XCTAssertEqual(blocks.joined(), source)
    XCTAssertTrue(blocks.allSatisfy { $0.count <= 1200 })
  }
  func testCacheReuseInvalidationBudgetAndAccountSeparation() async {
    let cache = DescriptionTextCache(budget: 12000)
    let source = String(repeating: "雨。\n", count: 500)
    let first = await cache.blocks(source, owner: "a")
    let second = await cache.blocks(source, owner: "a")
    XCTAssertEqual(first, second)
    var count = await cache.entryCount; XCTAssertEqual(count, 1)
    _ = await cache.blocks(source + "新", owner: "a")
    _ = await cache.blocks(source, owner: "b")
    count = await cache.entryCount; XCTAssertEqual(count, 3)
    let huge = String(repeating: "文", count: 10000)
    let uncached = await cache.blocks(huge, owner: "b")
    XCTAssertEqual(uncached.joined(), huge)
    count = await cache.entryCount; XCTAssertEqual(count, 3)
    await cache.removeAll()
    count = await cache.entryCount; XCTAssertEqual(count, 0)
  }
}
