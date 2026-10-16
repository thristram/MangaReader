import Foundation
import XCTest

@testable import MangaCore

final class StorageWorkflowTests: XCTestCase {
  func testMediaLanguageCorrectionChangesOnlyMediaIdentityLanguageAndFolder() throws {
    var original = MediaVersion(
      id: "original", language: "ja", kind: "images", storageRootId: "root",
      relativePaths: ["Author/Chapter/ja/1.png"], pageCount: 1)
    original.pageAlignment = [0]
    var translation = MediaVersion(
      id: "translation", language: "en", kind: "pdf", storageRootId: "root",
      relativePaths: ["Author/Chapter/en/pages.pdf"], pageCount: 3)
    translation.pageAlignment = [2, nil, 0]
    var input = MetadataInput(
      kind: .chapter, title: "Chapter", originalLanguage: "ja", description: "Original",
      media: [original, translation])
    input.localizations["en"] = .init(title: "English title", description: "English text")
    let plan = try MediaLanguageChangePlan(metadata: input, mediaId: "translation", language: "zh")
    XCTAssertEqual(plan.sourceDirectory, "Author/Chapter/en")
    XCTAssertEqual(plan.destinationDirectory, "Author/Chapter/zh")
    XCTAssertEqual(plan.metadata.media[1].relativePaths, ["Author/Chapter/zh/pages.pdf"])
    XCTAssertEqual(plan.metadata.media[1].language, "zh")
    XCTAssertEqual(plan.metadata.media[1].id, "translation")
    XCTAssertEqual(plan.metadata.media[1].pageAlignment, [2, nil, 0])
    XCTAssertEqual(plan.metadata.media[0].relativePaths, original.relativePaths)
    XCTAssertEqual(plan.metadata.originalLanguage, "ja")
    XCTAssertEqual(plan.metadata.localizations, input.localizations)
    XCTAssertThrowsError(
      try MediaLanguageChangePlan(metadata: input, mediaId: "translation", language: "ja"))
    XCTAssertThrowsError(
      try MediaLanguageChangePlan(metadata: input, mediaId: "translation", language: "../zh"))
    input.media[1].relativePaths = ["Author/Chapter/en/1.png", "Other/en/2.png"]
    XCTAssertThrowsError(
      try MediaLanguageChangePlan(metadata: input, mediaId: "translation", language: "zh"))
  }
  func testSingleMediaLanguageCorrectionKeepsFolderAndTextLanguage() throws {
    let input = MetadataInput(
      kind: .chapter, title: "Chapter", originalLanguage: "ja",
      media: [
        .init(
          language: "ja", kind: "video", storageRootId: "root",
          relativePaths: ["Author/Chapter/video.mp4"], pageCount: 1)
      ])
    let plan = try MediaLanguageChangePlan(
      metadata: input, mediaId: input.media[0].id, language: "en")
    XCTAssertNil(plan.sourceDirectory)
    XCTAssertNil(plan.destinationDirectory)
    XCTAssertEqual(plan.metadata.media[0].relativePaths, input.media[0].relativePaths)
    XCTAssertEqual(plan.metadata.media[0].language, "en")
    XCTAssertEqual(plan.metadata.originalLanguage, "ja")
  }
  func testImportNamesRecognizePixivIDsWithoutStrippingUnrelatedNumbers() {
    for (name, title, id) in [
      ("134675894_お帰りなさい", "お帰りなさい", "134675894"),
      ("86583518_1-7", "1-7", "86583518"),
      ("129126566", "", "129126566"),
      ("123_名前_続き", "名前_続き", "123"),
    ] {
      XCTAssertEqual(ImportName.parse(name).title, title)
      XCTAssertEqual(ImportName.parse(name).pixivID, id)
    }
    for name in ["", "Chapter 12", "2026 summer", "Artist_123", "１２３_name"] {
      XCTAssertEqual(ImportName.parse(name).title, name)
      XCTAssertNil(ImportName.parse(name).pixivID)
    }
  }
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func testVerifiedCopyKeepsSourceUntilMetadataCommitsAndFinishIsIdempotent() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("incoming")
    let root = dir.appendingPathComponent("library")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("exact contents".utf8).write(to: source.appendingPathComponent("page.png"))
    let journals = dir.appendingPathComponent("journals")
    let receipt = try FileCommit.move(
      source: source, destinationRelativePath: "Author/Chapter", root: root,
      journalDirectory: journals, copyBeforeCommit: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertTrue(receipt.removeSourceAfterCommit == true)
    XCTAssertEqual(
      try FileInventory.read(source),
      try FileInventory.read(URL(fileURLWithPath: receipt.destination)))
    try FileCommit.finish(receipt, in: journals)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("unrelated new files".utf8).write(to: source.appendingPathComponent("new.txt"))
    try FileCommit.finish(receipt, in: journals)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: source.appendingPathComponent("new.txt").path))
  }
  func testChangedSourceIsNeverDeletedDuringCopyCompletion() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("original.pdf")
    let root = dir.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source)
    let journals = dir.appendingPathComponent("journals")
    let receipt = try FileCommit.move(
      source: source, destinationRelativePath: "Chapter/page.pdf", root: root,
      journalDirectory: journals, copyBeforeCommit: true)
    try Data("edited by someone else".utf8).write(to: source)
    XCTAssertThrowsError(try FileCommit.finish(receipt, in: journals))
    XCTAssertEqual(try Data(contentsOf: source), Data("edited by someone else".utf8))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: receipt.destination)), Data("original".utf8))
  }
  func testSharedSourceCanBeArchivedWithoutRemovingOtherComicsFiles() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.pdf")
    let root = dir.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("shared original".utf8).write(to: source)
    let journals = dir.appendingPathComponent("journals")
    let receipt = try FileCommit.move(
      source: source, destinationRelativePath: "Chapter/shared.pdf", root: root,
      journalDirectory: journals, keepSource: true)
    try FileCommit.finish(receipt, in: journals)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(
      try Data(contentsOf: source), try Data(contentsOf: URL(fileURLWithPath: receipt.destination)))
  }
  func testCopyRejectsNestedSymlinksBeforePublishing() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source")
    let root = dir.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: source.appendingPathComponent("escape"), withDestinationURL: dir)
    XCTAssertThrowsError(
      try FileCommit.move(
        source: source, destinationRelativePath: "Chapter", root: root,
        journalDirectory: dir.appendingPathComponent("journals"), copyBeforeCommit: true))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Chapter").path))
  }
  func testRecyclePreservesFilesAndCanRollBackWithoutOverwriting() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    let relative = "Author/Chapter/1.png"
    let original = try PathPolicy.resolve(relative, under: root)
    try FileManager.default.createDirectory(
      at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("archive".utf8).write(to: original)
    let file = ArchiveFile(root: root, rootId: "root", libraryId: "owner", relativePath: relative)
    let journals = root.appendingPathComponent("test-journals")
    let receipt = try FileRecycle.begin(
      entityId: "chapter", revision: 1, files: [file, file], journalDirectory: journals)
    XCTAssertEqual(receipt.entries.count, 1)
    let recycled = try PathPolicy.resolve(receipt.entries[0].destination, under: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    XCTAssertEqual(try Data(contentsOf: recycled), Data("archive".utf8))
    try Data("unrelated".utf8).write(to: original)
    XCTAssertThrowsError(try FileRecycle.rollback(receipt, in: journals))
    XCTAssertEqual(try Data(contentsOf: original), Data("unrelated".utf8))
    XCTAssertEqual(try Data(contentsOf: recycled), Data("archive".utf8))
    try FileManager.default.removeItem(at: original)
    try FileRecycle.rollback(receipt, in: journals)
    XCTAssertEqual(try Data(contentsOf: original), Data("archive".utf8))
    let committed = try FileRecycle.begin(
      entityId: "chapter", revision: 1, files: [file], journalDirectory: journals)
    try FileRecycle.finish(committed, in: journals)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try PathPolicy.resolve(committed.entries[0].destination, under: root).path))
  }
  func testRecycleRefusesWrongLibraryAndTraversal() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    try Data("keep".utf8).write(to: root.appendingPathComponent("1.png"))
    let bad = ArchiveFile(root: root, rootId: "root", libraryId: "other", relativePath: "1.png")
    XCTAssertThrowsError(
      try FileRecycle.begin(
        entityId: "chapter", revision: 1, files: [bad],
        journalDirectory: root.appendingPathComponent("journals")))
    let escape = ArchiveFile(
      root: root, rootId: "root", libraryId: "owner", relativePath: "../escape")
    XCTAssertThrowsError(
      try FileRecycle.begin(
        entityId: "chapter", revision: 1, files: [escape],
        journalDirectory: root.appendingPathComponent("journals")))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("1.png")), Data("keep".utf8))
  }
  func testRealCrossVolumeMoveWhenTestVolumeIsProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["MANGA_TEST_SECOND_VOLUME"] else {
      throw XCTSkip("No isolated second test volume")
    }
    let sourceDir = try directory()
    defer { try? FileManager.default.removeItem(at: sourceDir) }
    let root = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = sourceDir.appendingPathComponent("page.pdf")
    let bytes = Data(repeating: 42, count: 1024 * 1024)
    try bytes.write(to: source)
    let sourceVolume = try source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    let destinationVolume = try root.resourceValues(forKeys: [.volumeIdentifierKey])
      .volumeIdentifier
    XCTAssertNotEqual(String(describing: sourceVolume), String(describing: destinationVolume))
    let journals = sourceDir.appendingPathComponent("journals")
    let receipt = try FileCommit.move(
      source: source, destinationRelativePath: "Author/Chapter/page.pdf", root: root,
      journalDirectory: journals)
    XCTAssertTrue(receipt.removeSourceAfterCommit == true)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.destination)), bytes)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    try FileCommit.finish(receipt, in: journals)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }
  func testRecycleRejectsInternalSymlinksAndResumesAnInterruptedOperation() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    let original = root.appendingPathComponent("page.png")
    try Data("page".utf8).write(to: original)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("alias.png"), withDestinationURL: original)
    let alias = ArchiveFile(
      root: root, rootId: "root", libraryId: "owner", relativePath: "alias.png")
    let journals = root.appendingPathComponent("journals")
    XCTAssertThrowsError(
      try FileRecycle.begin(
        entityId: "chapter", revision: 1, files: [alias], journalDirectory: journals))
    XCTAssertEqual(try Data(contentsOf: original), Data("page".utf8))
    let file = ArchiveFile(root: root, rootId: "root", libraryId: "owner", relativePath: "page.png")
    let receipt = try FileRecycle.begin(
      entityId: "chapter", revision: 1, files: [file], journalDirectory: journals)
    try FileRecycle.rollback(receipt, in: journals)
    let resumed = try FileRecycle.resume(receipt, in: journals)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    XCTAssertEqual(resumed.phase, "filesRecycled_metadataPending")
    try FileRecycle.finish(resumed, in: journals)
  }

  func testLanguageOrganizationStagesAllVersionsBeforeCleaningOriginals() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    let old = root.appendingPathComponent("Author/Chapter/1.png")
    try FileManager.default.createDirectory(
      at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    let incoming = dir.appendingPathComponent("new.png")
    try Data("original".utf8).write(to: old)
    try Data("translation".utf8).write(to: incoming)
    let journals = dir.appendingPathComponent("journals")
    let media = [
      MediaVersion(
        language: "ja", kind: "images", storageRootId: "root",
        relativePaths: ["Author/Chapter/ja/1.png"], pageCount: 1),
      MediaVersion(
        language: "zxx", kind: "images", storageRootId: "root",
        relativePaths: ["Author/Chapter/zxx/new.png"], pageCount: 1),
    ]
    let plan = try FileOrganization.prepare(
      entityId: "chapter", revision: 2,
      metadata: MetadataInput(kind: .chapter, title: "Chapter", media: media), libraryId: "owner",
      rootId: "root", root: root, sourceRootIds: ["root"],
      files: [
        OrganizationFile(source: old, relativePath: media[0].relativePaths[0], keepSource: false),
        OrganizationFile(
          source: incoming, relativePath: media[1].relativePaths[0], keepSource: false),
      ], directory: journals)
    let staged = try FileOrganization.stage(plan, in: journals)
    XCTAssertEqual(try Data(contentsOf: old), Data("original".utf8))
    XCTAssertEqual(try Data(contentsOf: incoming), Data("translation".utf8))
    XCTAssertEqual(staged.phase, "filesReady_metadataPending")
    XCTAssertEqual(media[1].languageLabel, "No text")
    try FileOrganization.finish(staged, in: journals)
    try FileOrganization.finish(staged, in: journals)
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(media[0].relativePaths[0])),
      Data("original".utf8))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(media[1].relativePaths[0])),
      Data("translation".utf8))
  }
  func testLanguageOrganizationResumesPartialCopyAndProtectsSharedSources() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    let first = dir.appendingPathComponent("first.png")
    let second = dir.appendingPathComponent("second.png")
    try Data("one".utf8).write(to: first)
    try Data("two".utf8).write(to: second)
    let journals = dir.appendingPathComponent("journals")
    let plan = try FileOrganization.prepare(
      entityId: "chapter", revision: 1,
      metadata: MetadataInput(kind: .chapter, title: "Chapter"), libraryId: "owner", rootId: "root",
      root: root, sourceRootIds: [],
      files: [
        OrganizationFile(source: first, relativePath: "Chapter/ja/1.png", keepSource: true),
        OrganizationFile(source: second, relativePath: "Chapter/en/1.png", keepSource: false),
      ], directory: journals)
    try Data("edited".utf8).write(to: second)
    XCTAssertThrowsError(try FileOrganization.stage(plan, in: journals))
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    XCTAssertEqual(try FileOrganization.read(plan.id, in: journals).files[0].phase, "copied")
    try Data("two".utf8).write(to: second)
    let staged = try FileOrganization.stage(plan, in: journals)
    try Data("modified after staging".utf8).write(to: second)
    XCTAssertThrowsError(try FileOrganization.finish(staged, in: journals))
    try Data("two".utf8).write(to: second)
    try FileOrganization.finish(staged, in: journals)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
  }

}
