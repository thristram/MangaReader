import Foundation
import XCTest
@testable import MangaCore

final class SourceReferenceIndexTests: XCTestCase {
  private func withDirectory(_ work: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try work(root.resolvingSymlinksInPath().standardizedFileURL)
  }
  private func media(_ id: String, root: String = "root", _ paths: [String]) -> MediaVersion {
    .init(id: id, language: "ja", kind: "images", storageRootId: root,
          relativePaths: paths, pageCount: paths.count)
  }
  private func file(_ relative: String, under root: URL) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: url)
    return url
  }

  func testSharedMediaExclusionAndRootBoundaries() throws {
    try withDirectory { root in
      let source = try file("chapter/01.png", under: root)
      let index = SourceReferenceIndex(media: [media("original", ["chapter/01.png"]),
                                             media("translation", ["chapter/01.png"])])
      XCTAssertEqual(index.rootIDs(excluding: "original"), ["root"])
      XCTAssertTrue(try index.containsAny(of: [source.path], under: root, rootID: "root", excluding: "original"))
      let own = SourceReferenceIndex(media: [media("original", ["chapter/01.png"])])
      XCTAssertTrue(own.rootIDs(excluding: "original").isEmpty)
      XCTAssertFalse(try own.containsAny(of: [source.path], under: root, rootID: "root", excluding: "original"))
      var probes = SourceReferenceIndex.Probes()
      XCTAssertFalse(try index.containsAny(of: [root.path + "-sibling/chapter/01.png"],
        under: root, rootID: "root", excluding: "new", probes: &probes))
      XCTAssertEqual(probes.directoriesResolved + probes.directoriesListed + probes.filesResolved, 0)
    }
  }

  func testNestedRootsAndDifferentlyNamedSymlinksMatchLegacyResolver() throws {
    try withDirectory { root in
      let source = try file("real/chapter/01.png", under: root)
      try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path,
                                                 withDestinationPath: "real")
      try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("renamed.png").path,
                                                 withDestinationPath: "real/chapter/01.png")
      try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("root-alias").path,
                                                 withDestinationPath: "real/chapter")
      let variants: [(URL, String)] = [(root, "alias/chapter/01.png"), (root, "renamed.png"),
        (root.appendingPathComponent("real"), "chapter/01.png"),
        (root.appendingPathComponent("root-alias"), "01.png")]
      for (bound, path) in variants {
        let index = SourceReferenceIndex(media: [media("other", [path])])
        let old = try PathPolicy.resolve(path, under: bound).path == source.path
        XCTAssertTrue(old)
        XCTAssertEqual(try index.containsAny(of: [source.path], under: bound,
          rootID: "root", excluding: "new"), old, path)
      }
    }
  }

  func testFilesystemAliasesAreRecheckedAndEscapesAreRejected() throws {
    try withDirectory { root in
      let first = try file("chapter/01.png", under: root)
      let second = try file("chapter/02.png", under: root)
      let link = root.appendingPathComponent("alias.png")
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "chapter/01.png")
      let index = SourceReferenceIndex(media: [media("other", ["alias.png"])])
      XCTAssertTrue(try index.containsAny(of: [first.path], under: root, rootID: "root", excluding: "new"))
      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "chapter/02.png")
      XCTAssertFalse(try index.containsAny(of: [first.path], under: root, rootID: "root", excluding: "new"))
      XCTAssertTrue(try index.containsAny(of: [second.path], under: root, rootID: "root", excluding: "new"))
      let inner = root.appendingPathComponent("inner")
      try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(atPath: inner.appendingPathComponent("escape").path,
        withDestinationPath: "../chapter")
      let unsafe = SourceReferenceIndex(media: [media("other", ["escape/01.png", "../chapter/01.png", "/chapter/01.png"])])
      XCTAssertFalse(try unsafe.containsAny(of: [first.path], under: inner, rootID: "root", excluding: "new"))
    }
  }

  func testLargeLibraryNeedsDirectoryProbesRatherThanPerPageResolution() throws {
    try withDirectory { root in
      let source = try file("incoming/unique.png", under: root)
      var versions: [MediaVersion] = []
      for chapter in 0..<20 {
        let directory = root.appendingPathComponent("author/chapter-\(chapter)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Metadata can list unavailable pages; checking sharing does not read their bytes.
        let paths = (0..<1000).map { "author/chapter-\(chapter)/\($0).png" }
        versions.append(media("media-\(chapter)", paths))
      }
      let index = SourceReferenceIndex(media: versions)
      var probes = SourceReferenceIndex.Probes()
      XCTAssertFalse(try index.containsAny(of: [source.path], under: root,
        rootID: "root", excluding: "new", probes: &probes))
      XCTAssertEqual(probes.directoriesResolved, 21) // shared author prefix resolved once
      XCTAssertEqual(probes.directoriesListed, 20)
      XCTAssertEqual(probes.filesResolved, 0)
      probes = .init()
      XCTAssertFalse(try index.containsAny(of: [source.path], under: root.appendingPathComponent("archive"),
        rootID: "root", excluding: "new", probes: &probes))
      XCTAssertEqual(probes.directoriesResolved + probes.directoriesListed + probes.filesResolved, 0)
    }
  }

  func testPDFVideoAndUnicodeReferences() throws {
    try withDirectory { root in
      for (kind, path) in [("pdf", "作者/章节/书.pdf"), ("video", "作者/章节/映像.webm")] {
        let source = try file(path, under: root)
        var version = media("other", [path]); version.kind = kind
        XCTAssertTrue(try SourceReferenceIndex(media: [version]).containsAny(of: [source.path],
          under: root, rootID: "root", excluding: "new"))
      }
    }
  }
}
