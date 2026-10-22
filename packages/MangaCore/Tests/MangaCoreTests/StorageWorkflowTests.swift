import Foundation
import XCTest

@testable import MangaCore

final class StorageWorkflowTests: XCTestCase {
  func testStaleTranslationPlanPreservesPriorSuccessAndPersistsRebase() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    let cache = directory.appendingPathComponent("3.png")
    try Data("translated third page".utf8).write(to: cache)
    let original = MediaVersion(id: "original", language: "ja", kind: "images", storageRootId: "root",
      relativePaths: ["Chapter/ja/1.png", "Chapter/ja/2.png", "Chapter/ja/3.png"], pageCount: 3)
    var target = MediaVersion(id: "target", language: "zh", kind: "images", storageRootId: "root",
      relativePaths: ["Chapter/zh/1.png", "Chapter/zh/3.png"], pageCount: 2)
    target.pageAlignment = [0, nil, 1]
    let desired = MetadataInput(kind: .chapter, title: "Chapter", originalLanguage: "ja", media: [original, target])
    let journals = directory.appendingPathComponent("journals")
    let prepared = try FileOrganization.prepare(entityId: "chapter", revision: 2, metadata: desired,
      libraryId: "owner", rootId: "root", root: root, sourceRootIds: ["root"],
      files: [.init(source: cache, relativePath: "Chapter/zh/3.png", keepSource: true)], directory: journals)
    let stale = try FileOrganization.stage(prepared, in: journals)
    var current = desired
    current.description = "Newer metadata"
    current.media[1].relativePaths = ["Chapter/zh/1.png", "Chapter/zh/2.png"]
    current.media[1].pageAlignment = [0, 1, nil]
    let recovered = try XCTUnwrap(stale.recoveringLegacyImageAddition(current: current, mediaId: "target",
      language: "zh", canonical: 2, count: 3, cachedSource: cache, roots: ["root": root]))
    let saved = try FileOrganization.recordRecovery(stale, recovered: recovered, in: journals)
    XCTAssertNotNil(saved.originalMetadata)
    XCTAssertEqual(saved.priorMetadata?.media[1].relativePaths, desired.media[1].relativePaths)
    let restored = try FileOrganization.read(saved.id, in: journals)
    guard case .update(let merged) = try restored.recovery(current: current, revision: 3) else {
      return XCTFail("Interrupted rebase did not retain a recoverable metadata payload")
    }
    XCTAssertEqual(merged.description, current.description)
    XCTAssertEqual(merged.media[1].relativePaths, ["Chapter/zh/1.png", "Chapter/zh/2.png", "Chapter/zh/3.png"])
    XCTAssertEqual(merged.media[1].pageAlignment, [0, 1, 2])
    XCTAssertThrowsError(try FileOrganization.recordRecovery(stale, recovered: recovered, in: journals))
    let staged = try FileOrganization.stage(restored, in: journals)
    try FileOrganization.finish(staged, in: journals)
    XCTAssertEqual(try FileOrganization.read(staged.id, in: journals).phase, "complete")
    XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
  }

  func testLegacyTranslationRecoveryProvesOriginalMovesAndKeepsNewText() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let archive = directory.appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("Chapter"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let first = source.appendingPathComponent("Chapter/1.png")
    let second = source.appendingPathComponent("Chapter/2.png")
    let cached = directory.appendingPathComponent("translated.png")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    try Data("translated".utf8).write(to: cached)
    let original = MetadataInput(kind: .chapter, title: "Chapter", originalLanguage: "ja",
      media: [.init(id: "original", language: "ja", kind: "images", storageRootId: "source",
        relativePaths: ["Chapter/1.png", "Chapter/2.png"], pageCount: 2)])
    var desired = original
    desired.media[0].storageRootId = "archive"
    desired.media[0].relativePaths = ["Chapter/ja/1.png", "Chapter/ja/2.png"]
    var translation = MediaVersion(id: "translation", language: "en", kind: "images", storageRootId: "archive",
      relativePaths: ["Chapter/en/translated.png"], pageCount: 1)
    translation.pageAlignment = [0, nil]
    desired.media.append(translation)
    let files = try [
      OrganizationFile(source: first, relativePath: "Chapter/ja/1.png", keepSource: false),
      OrganizationFile(source: second, relativePath: "Chapter/ja/2.png", keepSource: true),
      OrganizationFile(source: cached, relativePath: "Chapter/en/translated.png", keepSource: true),
    ].map { file in
      var file = file
      file.digest = try FileInventory.digest(URL(fileURLWithPath: file.source))
      return file
    }
    let plan = OrganizationJournal(id: "job", libraryId: "owner", entityId: "chapter", revision: 1,
      rootId: "archive", root: archive.path, sourceRootIds: ["source"], metadata: desired,
      files: files, phase: "filesReady_metadataPending")
    let roots = ["source": source, "archive": archive]
    func recover(_ current: MetadataInput, plan: OrganizationJournal = plan) throws -> OrganizationJournal? {
      try plan.recoveringLegacyImageAddition(current: current, mediaId: "translation", language: "en",
        canonical: 0, count: 2, cachedSource: cached, roots: roots)
    }
    var edited = original
    edited.description = "New description"
    edited.localizations["fr"] = .init(title: "New title translation")
    let proven = try XCTUnwrap(recover(edited))
    guard case .update(let merged) = try proven.recovery(current: edited, revision: 2) else {
      return XCTFail("Proven legacy translation did not merge")
    }
    XCTAssertEqual(merged.description, edited.description)
    XCTAssertEqual(merged.localizations, edited.localizations)
    XCTAssertEqual(merged.media[0].relativePaths, desired.media[0].relativePaths)
    for field in ["path", "alignment", "language", "title", "author"] {
      var conflict = edited
      switch field {
      case "path": conflict.media[0].relativePaths.reverse()
      case "alignment": conflict.media[0].pageAlignment = [1, 0]
      case "language": conflict.media[0].language = "fr"
      case "title": conflict.title = "Renamed"
      default: conflict.authorId = "another-author"
      }
      XCTAssertNil(try recover(conflict), "Unexpected legacy merge: " + field)
    }
    var unexplained = plan
    unexplained.files.append(OrganizationFile(source: cached, relativePath: "unrelated.png", keepSource: false))
    XCTAssertNil(try recover(edited, plan: unexplained))
    // Shared originals must also match the digest; keepSource must not bypass verification.
    try Data("modified shared source".utf8).write(to: second)
    XCTAssertThrowsError(try recover(edited))
  }

  func testLegacyTranslationRecoveryKeepsExistingPagesAndAlignment() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cached = directory.appendingPathComponent("translated.png")
    try Data("translated".utf8).write(to: cached)
    var existing = MediaVersion(id: "translation", language: "en", kind: "images", storageRootId: "archive",
      relativePaths: ["Chapter/en/existing.png"], pageCount: 1)
    let original = MediaVersion(id: "original", language: "ja", kind: "images", storageRootId: "archive",
      relativePaths: ["Chapter/ja/1.png", "Chapter/ja/2.png"], pageCount: 2)
    for sparse in [false, true] {
      let canonical = sparse ? 0 : 1
      existing.pageAlignment = sparse ? [nil, 0] : nil
      var current = MetadataInput(kind: .chapter, title: "Chapter", originalLanguage: "ja", media: [original, existing])
      var desired = current
      desired.media[1].relativePaths.append("Chapter/en/translated.png")
      desired.media[1].pageCount = 2
      desired.media[1].pageAlignment = sparse ? [1, 0] : [0, 1]
      var file = OrganizationFile(source: cached, relativePath: "Chapter/en/translated.png", keepSource: true)
      file.digest = try FileInventory.digest(cached)
      let plan = OrganizationJournal(id: "job", libraryId: "owner", entityId: "chapter", revision: 1,
        rootId: "archive", root: directory.path, sourceRootIds: ["archive"], metadata: desired,
        files: [file], phase: "filesReady_metadataPending")
      current.description = "New description"
      let recovered = try XCTUnwrap(plan.recoveringLegacyImageAddition(current: current, mediaId: "translation",
        language: "en", canonical: canonical, count: 2, cachedSource: cached, roots: ["archive": directory]))
      guard case .update(let merged) = try recovered.recovery(current: current, revision: 2) else {
        return XCTFail("Existing target pages blocked legacy recovery")
      }
      XCTAssertEqual(merged.media[1].relativePaths.first, existing.relativePaths.first)
      XCTAssertEqual(merged.media[1].pageAlignment, desired.media[1].pageAlignment)
      var competing = current
      competing.media[1].pageAlignment = sparse ? [0, nil] : [nil, 0]
      XCTAssertNil(try plan.recoveringLegacyImageAddition(current: competing, mediaId: "translation",
        language: "en", canonical: canonical, count: 2, cachedSource: cached, roots: ["archive": directory]))
    }
  }

  func testOrganizationRecoveryPreservesTextEditsAndRejectsFileConflicts() throws {
    let original = MetadataInput(kind: .chapter, title: "Chapter", originalLanguage: "ja",
      media: [.init(id: "original", language: "ja", kind: "images", storageRootId: "root",
        relativePaths: ["Chapter/1.png", "Chapter/2.png"], pageCount: 2)])
    var desired = original
    desired.media[0].relativePaths = ["Chapter/ja/1.png", "Chapter/ja/2.png"]
    desired.media.append(.init(id: "translation", language: "en", kind: "images",
      storageRootId: "root", relativePaths: ["Chapter/en/1.png"], pageCount: 1))
    var journal = OrganizationJournal(id: "job", libraryId: "owner", entityId: "chapter",
      revision: 1, rootId: "root", root: "/archive", sourceRootIds: ["root"],
      metadata: desired, originalMetadata: original, files: [], phase: "filesReady_metadataPending")
    var edited = original
    edited.description = "New description"
    edited.localizations["fr"] = .init(title: "Translated title")
    edited.tagIds = ["new-tag"]
    edited.sources = [.init(site: "pixiv", value: "123")]
    edited.nsfw = true
    guard case .update(let merged) = try journal.recovery(current: edited, revision: 2) else {
      return XCTFail("Unrelated metadata edits should merge")
    }
    XCTAssertEqual(merged.description, edited.description)
    XCTAssertEqual(merged.localizations, edited.localizations)
    XCTAssertEqual(merged.tagIds, edited.tagIds)
    XCTAssertEqual(merged.sources.first?.value, "123")
    XCTAssertTrue(merged.nsfw)
    XCTAssertEqual(merged.media[0].relativePaths, desired.media[0].relativePaths)
    XCTAssertEqual(merged.media.last?.id, "translation")
    for field in ["path", "root", "alignment", "language", "title", "author", "work"] {
      var conflict = edited
      switch field {
      case "path": conflict.media[0].relativePaths.reverse()
      case "root": conflict.media[0].storageRootId = "elsewhere"
      case "alignment": conflict.media[0].pageAlignment = [1, 0]
      case "language": conflict.media[0].language = "zh"
      case "title": conflict.title = "Renamed chapter"
      case "author": conflict.authorId = "new-author"
      default: conflict.workId = "new-work"
      }
      guard case .conflict = try journal.recovery(current: conflict, revision: 2) else {
        return XCTFail("Unsafe recovery accepted: " + field)
      }
    }
    // Old journals have no baseline. Already-committed references can finish without a write;
    // an uncommitted journal cannot infer what changed and must still stop.
    journal.originalMetadata = nil
    let legacy = try JSONDecoder().decode(OrganizationJournal.self, from: JSONEncoder().encode(journal))
    XCTAssertNil(legacy.originalMetadata)
    guard case .conflict = try legacy.recovery(current: edited, revision: 2) else {
      return XCTFail("Legacy journal merged without a baseline")
    }
    edited.media = desired.media
    guard case .committed = try legacy.recovery(current: edited, revision: 3) else {
      return XCTFail("Committed media with newer text was not recognized")
    }
  }

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

  func testFolderCleanupIsBoundedEmptyOnlyAndRejectsSymlinks() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let chapter = root.appendingPathComponent("Author/Chapter")
    let ja = chapter.appendingPathComponent("ja")
    let en = chapter.appendingPathComponent("en")
    try fm.createDirectory(at: ja, withIntermediateDirectories: true)
    try fm.createDirectory(at: en, withIntermediateDirectories: true)
    let media = MediaVersion(language: "ja", kind: "images", storageRootId: "root",
      relativePaths: ["Author/Chapter/ja/1.png"], pageCount: 1)
    let plan = EmptyMediaFolder.plan(media: [media], roots: ["root": root], chapterTitle: "Chapter")
    try EmptyMediaFolder.removeEmpty(plan)
    XCTAssertFalse(fm.fileExists(atPath: ja.path))
    XCTAssertTrue(fm.fileExists(atPath: en.path))
    try Data("unrelated".utf8).write(to: en.appendingPathComponent("notes.txt"))
    try EmptyMediaFolder.removeEmpty([EmptyMediaFolder(root: root, relativePath: "Author/Chapter/en")])
    XCTAssertTrue(fm.fileExists(atPath: en.appendingPathComponent("notes.txt").path))
    try fm.removeItem(at: en)
    try EmptyMediaFolder.removeEmpty(plan)
    XCTAssertFalse(fm.fileExists(atPath: chapter.path))
    XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Author").path))
    try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("Author"))
    XCTAssertThrowsError(try EmptyMediaFolder.removeEmpty([EmptyMediaFolder(root: root, relativePath: "link")]))
    XCTAssertThrowsError(try EmptyMediaFolder.removeEmpty([EmptyMediaFolder(root: root, relativePath: ".")]))
  }
  func testRecycleCleanupWaitsForCommitAndSurvivesJournalReload() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    try LibraryDestinationIdentity.bind(folder: root, libraryId: "owner", destinationId: "root")
    let source = root.appendingPathComponent("Author/Chapter/ja/1.png")
    try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("page".utf8).write(to: source)
    let media = MediaVersion(language: "ja", kind: "images", storageRootId: "root",
      relativePaths: ["Author/Chapter/ja/1.png"], pageCount: 1)
    let journals = root.appendingPathComponent("journals")
    let journal = try FileRecycle.begin(entityId: "chapter", revision: 1,
      files: [ArchiveFile(root: root, rootId: "root", libraryId: "owner", relativePath: media.relativePaths[0])],
      journalDirectory: journals, cleanupFolders: EmptyMediaFolder.plan(media: [media], roots: ["root": root], chapterTitle: "Chapter"))
    XCTAssertTrue(fm.fileExists(atPath: source.deletingLastPathComponent().path))
    let reloaded = try JSONDecoder().decode(RecycleJournal.self,
      from: Data(contentsOf: journals.appendingPathComponent(journal.id + ".json")))
    try FileRecycle.rollback(reloaded, in: journals)
    XCTAssertEqual(try Data(contentsOf: source), Data("page".utf8))
    let committed = try FileRecycle.begin(entityId: "chapter", revision: 1,
      files: [ArchiveFile(root: root, rootId: "root", libraryId: "owner", relativePath: media.relativePaths[0])],
      journalDirectory: journals, cleanupFolders: reloaded.cleanupFolders ?? [])
    try FileRecycle.finish(committed, in: journals)
    XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Author/Chapter").path))
    XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Recycle/" + committed.id + "/" + media.relativePaths[0]).path))
  }

  func testSingleChapterNamedAfterLanguageNeverPrunesAuthor() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Author/en"), withIntermediateDirectories: true)
    let media = MediaVersion(language: "en", kind: "images", storageRootId: "root",
      relativePaths: ["Author/en/1.png"], pageCount: 1)
    let cleanup = EmptyMediaFolder.plan(media: [media], roots: ["root": root], chapterTitle: "en")
    XCTAssertEqual(cleanup.map(\.relativePath), ["Author/en"])
    try EmptyMediaFolder.removeEmpty(cleanup)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Author").path))
  }

}
