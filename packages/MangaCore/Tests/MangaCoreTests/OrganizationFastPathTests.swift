import Foundation
import XCTest
@testable import MangaCore

final class OrganizationFastPathTests: XCTestCase {
  private func fixture(_ run: (URL, URL, URL, URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    let source = dir.appendingPathComponent("page.png")
    try Data("original page".utf8).write(to: source)
    try run(root, source, root.appendingPathComponent("Chapter/zh/page.png"), dir.appendingPathComponent("journals"))
  }
  private func plan(_ root: URL, _ source: URL, _ journals: URL,
    keep: Bool = false, rename: Bool = false, links: Bool = true) throws -> OrganizationJournal {
    let input = MetadataInput(kind: .chapter, title: "Chapter")
    var desired = input
    desired.media = [.init(language: "zh", kind: "images", storageRootId: "root",
      relativePaths: ["Chapter/zh/page.png"], pageCount: 1)]
    return try FileOrganization.prepare(entityId: "chapter", revision: 1, metadata: desired,
      libraryId: "owner", rootId: "root", root: root, sourceRootIds: [],
      files: [.init(source: source, relativePath: "Chapter/zh/page.png", keepSource: keep)],
      directory: journals, originalMetadata: input, preferLinks: links, allowRename: rename)
  }
  private static let unsupported: @Sendable (URL, URL) throws -> Void = { _, _ in
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
  }
  func testLinkStagesWithoutReadingBytesAndKeepsOriginalUntilCommit() throws {
    try fixture { root, source, target, journals in
      let prepared = try plan(root, source, journals)
      XCTAssertNotNil(prepared.files[0].identity)
      XCTAssertTrue(prepared.files[0].digest.isEmpty)
      let staged = try FileOrganization.stage(prepared, in: journals)
      XCTAssertEqual(try FileIdentity.read(source), try FileIdentity.read(target))
      try FileOrganization.finish(staged, in: journals)
      try FileOrganization.finish(staged, in: journals)
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
      XCTAssertEqual(try Data(contentsOf: target), Data("original page".utf8))
    }
  }
  func testSupplementalEmptyFoldersArePersistedAndRecreatedOnResume() throws {
    try fixture { root, source, _, journals in
      var prepared = try plan(root, source, journals)
      prepared.destinationFolders = ["Chapter/zh/empty-subfolder"]
      try JSONEncoder().encode(prepared).write(to: journals.appendingPathComponent(prepared.id + ".json"))
      let staged = try FileOrganization.stage(prepared, in: journals)
      let empty = root.appendingPathComponent("Chapter/zh/empty-subfolder")
      XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
      try FileManager.default.removeItem(at: empty)
      _ = try FileOrganization.stage(staged, in: journals)
      XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
      try FileOrganization.finish(staged, in: journals)
    }
  }
  func testUnsupportedLinksUseJournalledRenameAndResumeAfterLostCheckpoint() throws {
    try fixture { root, source, target, journals in
      let prepared = try plan(root, source, journals, rename: true)
      let staged = try FileOrganization.stage(prepared, in: journals, link: Self.unsupported)
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
      XCTAssertEqual(try FileIdentity.read(target), prepared.files[0].identity)
      // Simulate termination after rename, before the batched checkpoint or metadata write.
      var interrupted = prepared
      interrupted.phase = "copying"; interrupted.files[0].phase = "copying"
      try JSONEncoder().encode(interrupted).write(to: journals.appendingPathComponent(prepared.id + ".json"))
      let resumed = try FileOrganization.stage(interrupted, in: journals, link: Self.unsupported)
      XCTAssertEqual(resumed.phase, staged.phase)
      guard case .update = try resumed.recovery(current: prepared.originalMetadata!, revision: 1)
      else { return XCTFail("rename metadata could not recover") }
      try FileOrganization.finish(resumed, in: journals)
      XCTAssertEqual(try Data(contentsOf: target), Data("original page".utf8))
    }
  }
  func testRenameNeverOverwritesUnrelatedTargetOrDeletesReplacedSource() throws {
    try fixture { root, source, target, journals in
      let prepared = try plan(root, source, journals, rename: true)
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("unrelated".utf8).write(to: target)
      XCTAssertThrowsError(try FileOrganization.stage(prepared, in: journals, link: Self.unsupported))
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
      try FileManager.default.removeItem(at: target)
      let staged = try FileOrganization.stage(prepared, in: journals, link: Self.unsupported)
      try Data("replacement".utf8).write(to: source)
      XCTAssertThrowsError(try FileOrganization.finish(staged, in: journals))
      XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
    }
  }
  func testRenameMovesSameObjectWhenOnlySourceTimestampChangesBeforeStaging() throws {
    try fixture { root, source, target, journals in
      let prepared = try plan(root, source, journals, rename: true)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 30)],
        ofItemAtPath: source.path)
      let staged = try FileOrganization.stage(prepared, in: journals, link: Self.unsupported)
      XCTAssertEqual(staged.files[0].identity, try FileIdentity.read(target))
      try FileOrganization.finish(staged, in: journals)
      XCTAssertEqual(try Data(contentsOf: target), Data("original page".utf8))
    }
  }
  func testSharedFilesAndUnsupportedLinkWithoutRenameStayIndependentVerifiedCopies() throws {
    for keep in [true, false] {
      try fixture { root, source, target, journals in
        let prepared = try plan(root, source, journals, keep: keep)
        if keep { XCTAssertNil(prepared.files[0].identity) }
        let staged = try FileOrganization.stage(prepared, in: journals, link: Self.unsupported)
        XCTAssertNil(staged.files[0].identity)
        XCTAssertFalse(staged.files[0].digest.isEmpty)
        XCTAssertNotEqual(try FileIdentity.read(source).inode, try FileIdentity.read(target).inode)
        try FileOrganization.finish(staged, in: journals)
        XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), keep)
      }
    }
  }
  func testChangedLinkedFileAndSameBytesDifferentInodeAreRejected() throws {
    try fixture { root, source, target, journals in
      let prepared = try plan(root, source, journals)
      let staged = try FileOrganization.stage(prepared, in: journals)
      try Data("changed page".utf8).write(to: target, options: .atomic)
      XCTAssertThrowsError(try FileOrganization.finish(staged, in: journals))
      try Data("original page".utf8).write(to: target, options: .atomic)
      XCTAssertThrowsError(try FileOrganization.stage(prepared, in: journals))
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
  }
  func testIndependentCopiesRecordBothObjectGuardsAndRejectChangedBytes() throws {
    try fixture { root, source, target, journals in
      let prepared = try plan(root, source, journals, keep: true)
      XCTAssertNil(prepared.files[0].identity)
      XCTAssertNotNil(prepared.files[0].copySourceIdentity)
      let staged = try FileOrganization.stage(prepared, in: journals)
      XCTAssertNotNil(staged.files[0].publishedCopyIdentity)
      XCTAssertEqual(staged.files[0].digest, try FileInventory.digest(target))
      XCTAssertNotEqual(try FileIdentity.read(source).inode, try FileIdentity.read(target).inode)
      _ = try FileOrganization.stage(staged, in: journals)
      try Data("unexpected target data".utf8).write(to: target, options: .atomic)
      XCTAssertThrowsError(try FileOrganization.finish(staged, in: journals))
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
  }

  func testCopyFingerprintRechecksBytesWhenNASReadAdvancesTimestamp() throws {
    try fixture { _, source, _, _ in
      var reads = 0
      let result = try FileOrganization.copyFingerprint(source) { url in
        let value = try FileInventory.read(url)
        reads += 1
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(reads + 100))], ofItemAtPath: url.path)
        return value
      }
      XCTAssertEqual(reads, 2)
      XCTAssertEqual(result.digest, try FileInventory.digest(source))
      XCTAssertEqual(result.identity, try FileIdentity.read(source))
      reads = 0
      XCTAssertThrowsError(try FileOrganization.copyFingerprint(source) { url in
        let value = try FileInventory.read(url)
        if reads == 0 { try Data("different now".utf8).write(to: url) }
        reads += 1
        return value
      })
    }
  }

  func testRecycleUsesSameVolumeIdentityAndLegacySHARemainsRecoverable() throws {
    try fixture { root, source, _, journals in
      let page = root.appendingPathComponent("Chapter/page.png")
      try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: source, to: page)
      let before = try FileIdentity.read(page)
      let files = [ArchiveFile(root: root, rootId: "root", libraryId: "owner", relativePath: "Chapter/page.png")]
      let recycled = try FileRecycle.begin(entityId: "chapter", revision: 1, files: files, journalDirectory: journals)
      XCTAssertTrue(recycled.entries[0].digest.isEmpty, "same-volume Recycle must never hash media")
      XCTAssertEqual(recycled.entries[0].identity, before)
      let destination = root.appendingPathComponent(recycled.entries[0].destination)
      XCTAssertEqual(recycled.entries[0].publishedIdentity, try FileIdentity.read(destination))
      _ = try FileRecycle.resume(recycled, in: journals)
      var legacy = recycled
      legacy.entries[0].digest = try FileInventory.digest(destination)
      legacy.entries[0].identity = nil; legacy.entries[0].publishedIdentity = nil
      // Old journal keys really are absent, not merely nil values in memory.
      let decoded = try JSONDecoder().decode(RecycleJournal.self, from: JSONEncoder().encode(legacy))
      _ = try FileRecycle.resume(decoded, in: journals)
      try Data("foreign file".utf8).write(to: destination, options: .atomic)
      XCTAssertThrowsError(try FileRecycle.rollback(recycled, in: journals))
      try Data("original page".utf8).write(to: destination)
      try FileRecycle.rollback(decoded, in: journals)
      XCTAssertEqual(try Data(contentsOf: page), Data("original page".utf8))
    }
  }

  func testMutationWalkRejectsInteriorSymlinksAndValidatesMissingSuffixes() throws {
    try fixture { root, _, _, _ in
      let real = root.appendingPathComponent("real")
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: real)
      XCTAssertThrowsError(try PathPolicy.mutationPath("alias/new.png", under: root))
      XCTAssertThrowsError(try PathPolicy.mutationPath("new/../escape.png", under: root))
      XCTAssertThrowsError(try PathPolicy.mutationPath("new//page.png", under: root))
      XCTAssertEqual(try PathPolicy.mutationPath("new/deeper/page.png", under: root),
        root.resolvingSymlinksInPath().appendingPathComponent("new/deeper/page.png"))
    }
  }

  func testOldCopyJournalWithoutIdentityStillDecodesAndFinishes() throws {
    try fixture { root, source, target, journals in
      let prepared = try plan(root, source, journals, links: false)
      let url = journals.appendingPathComponent(prepared.id + ".json")
      var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
      var files = json["files"] as! [[String: Any]]
      for key in ["identity", "allowRename", "copySourceIdentity", "publishedCopyIdentity"] {
        files[0].removeValue(forKey: key)
      }
      json["files"] = files
      try JSONSerialization.data(withJSONObject: json).write(to: url)
      let staged = try FileOrganization.stage(prepared, in: journals)
      try FileOrganization.finish(staged, in: journals)
      XCTAssertEqual(try Data(contentsOf: target), Data("original page".utf8))
    }
  }
}
