import Foundation
import MangaCore

@MainActor enum SingleFileImportChecks {
  static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw LoginError.server("Single-file import check: " + message) }
  }
  static func run(directory: URL) async throws {
    try await sharedSourceChecks(directory: directory.appendingPathComponent("shared-source-index"))
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    defer { library.reset() }
    let work = session.entities.first { $0.id == "w0" }!
    let pdf = session.entities.flatMap(\.media).first { $0.kind == "pdf" }!
    let pdfBytes = try Data(contentsOf: try await library.mediaURL(pdf, index: 0))
    let incoming = directory.appendingPathComponent("Single Files")
    let archive = directory.appendingPathComponent("Archive")
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let destination = try await session.create(
      .init(kind: .storageRoot, title: "File destination", storageKind: "local"))
    try library.local.bind(destination, to: archive)
    var kept: [(URL, MediaVersion, Data)] = []
    for ext in ["mp4", "webm", "pdf"] {
      // Import tests exercise exact bytes and source grants, not video decoding.
      let bytes = ext == "pdf" ? pdfBytes : Data("synthetic \(ext) media".utf8)
      let file = incoming.appendingPathComponent("001 Regal's shower 日本語.\(ext)")
      try bytes.write(to: file)
      let model = ImportWorkspaceModel(library: library)
      model.append([file])
      model.input.authorId = work.authorId
      model.input.workId = work.id
      model.input.title = "Keep \(ext)"
      model.input.originalLanguage = "ja"
      await model.process(move: false)?.value
      try expect(model.queue.isEmpty, "add-only \(ext) failed: \(model.status)")
      model.close()
      let chapter = session.entities.first { $0.kind == .chapter && $0.title == "Keep \(ext)" }!
      let media = chapter.media[0]
      let bound = try await library.local.boundSourceURL(media.storageRootId)
      try expect(bound == file, "standalone \(ext) bookmarked its unselected parent")
      try expect(media.relativePaths == [file.lastPathComponent], "standalone file path changed")
      try expect(media.kind == (ext == "pdf" ? "pdf" : "video"), "media kind changed")
      kept.append((file, media, bytes))
    }
    try expect(
      Set(kept.map { $0.1.storageRootId }).count == 3,
      "different file grants in one parent overwrite a shared root binding")
    library.local.release()
    let reopened = LocalMedia(session: session)
    defer { reopened.release() }
    for (file, media, bytes) in kept {
      let resource = try await reopened.boundSourceURL(media.storageRootId)
      let read = try await reopened.url(for: media, file: 0)
      try expect(
        resource.resolvingSymlinksInPath() == file.resolvingSymlinksInPath()
          && read.resolvingSymlinksInPath() == file.resolvingSymlinksInPath(),
        "persisted file bookmark did not reopen its file")
      let actual = try Data(contentsOf: read)
      try expect(actual == bytes, "add-only file bytes changed")
    }
    // Each independently granted file can be committed without parent access.
    for (file, _, bytes) in kept {
      let copy = incoming.appendingPathComponent("Move \(file.lastPathComponent)")
      try bytes.write(to: copy)
      let model = ImportWorkspaceModel(library: library)
      model.append([copy])
      model.input.authorId = work.authorId
      model.input.workId = work.id
      model.input.title = "Move \(file.pathExtension)"
      model.destinationId = destination.id
      await model.process(move: true)?.value
      try expect(model.queue.isEmpty, "move \(file.pathExtension) failed: \(model.status)")
      model.close()
      let chapter = session.entities.first {
        $0.kind == .chapter && $0.title == "Move \(file.pathExtension)"
      }!
      try expect(
        chapter.media[0].storageRootId == destination.id, "commit retained the source root")
      let archived = try await library.local.url(for: chapter.media[0], file: 0)
      let actual = try Data(contentsOf: archived)
      try expect(
        actual == bytes && !FileManager.default.fileExists(atPath: copy.path),
        "commit failed to preserve bytes or finish source cleanup")
      try expect(FileManager.default.fileExists(atPath: file.path), "commit removed a sibling file")
    }
    // Add-only imports remain discoverable after their import workspace closes.
    let pending = library.temporaryOrganizationRows().first { $0.id == work.id }!
    try expect(pending.chapters.count == 3, "add-only chapters must share one comic row")
    var sharedMedia = kept[0].1
    sharedMedia.id = UUID().uuidString.lowercased()
    let shared = try await session.create(.init(
      kind: .chapter, title: "Shared original", media: [sharedMedia]))
    try expect(library.temporaryOrganizationRows().contains { $0.id == shared.id },
               "standalone add-only chapter has no organization row")
    let translated = incoming.appendingPathComponent("translated.webm")
    let translatedBytes = Data("translated bytes".utf8)
    try translatedBytes.write(to: translated)
    let translatedChapter = pending.chapters.first { $0.title == "Keep mp4" }!
    let translation = ImportWorkspaceModel(library: library)
    translation.append([translated])
    translation.translationOf = translatedChapter.id
    translation.input.originalLanguage = "zh"
    translation.input.description = "translated description"
    await translation.process(move: false)?.value
    try expect(translation.queue.isEmpty, "add-only translation failed: " + translation.status)
    translation.close()
    let count = try await library.moveTemporaryFiles(rowId: work.id, destinationId: destination.id)
    try expect(count == 3 && !library.temporaryOrganizationRows().contains { $0.id == work.id },
               "one-click comic move did not archive every pending chapter")
    for (_, old, bytes) in kept {
      let chapter = session.entities.first { $0.media.contains { $0.id == old.id } && $0.workId == work.id }!
      let media = chapter.media.first { $0.id == old.id }!
      try expect(media.storageRootId == destination.id && media.pageCount == old.pageCount,
                 "organization lost media identity/page count or root")
      let url = try await library.local.url(for: media, file: 0)
      let actual = try Data(contentsOf: url)
      try expect(actual == bytes, "one-click move changed file contents")
    }
    let updatedTranslation = session.entities.first { $0.id == translatedChapter.id }!
    try expect(updatedTranslation.media.count == 2
      && updatedTranslation.localizations["zh"]?.description == "translated description"
      && updatedTranslation.media.allSatisfy { $0.storageRootId == destination.id
        && $0.relativePaths[0].contains("/" + $0.language + "/") },
      "multi-language organization lost translation text or language folders")
    try expect(!FileManager.default.fileExists(atPath: translated.path), "translated source was not cleaned up")
    try expect(FileManager.default.fileExists(atPath: kept[0].0.path), "shared original was removed")
    _ = try await library.moveTemporaryFiles(rowId: shared.id, destinationId: destination.id)
    try expect(!FileManager.default.fileExists(atPath: kept[0].0.path), "last source reference was not cleaned up")

    // Reject metadata after staging: source stays readable and the row must not start a second move.
    let failureFile = incoming.appendingPathComponent("metadata-failure.mp4")
    try Data("recoverable original".utf8).write(to: failureFile)
    let failed = ImportWorkspaceModel(library: library)
    failed.append([failureFile]); failed.input.title = "Pending failure"
    await failed.process(move: false)?.value
    try expect(failed.queue.isEmpty, "failure fixture add-only import failed")
    failed.close()
    let failedChapter = session.entities.first { $0.title == "Pending failure" }!
    NativeUIFixtures.rejectedUpdateIds.insert(failedChapter.id)
    defer { NativeUIFixtures.rejectedUpdateIds.remove(failedChapter.id) }
    do {
      _ = try await library.moveTemporaryFiles(rowId: failedChapter.id, destinationId: destination.id)
      throw LoginError.server("expected organization metadata rejection")
    } catch {
      try expect(FileManager.default.fileExists(atPath: failureFile.path), "metadata failure removed original")
      let ids = try await library.pendingFileOrganizationIds()
      try expect(ids.contains(failedChapter.id), "failed organization has no recovery record")
    }
    let journals = session.cacheDirectory!.appendingPathComponent("organization-journals")
    let beforeRetry = try FileManager.default.contentsOfDirectory(atPath: journals.path).count
    do { try await library.organizeChapterFiles(failedChapter, destination: destination) }
    catch { /* Recovery is required, without staging a second journal. */ }
    let afterRetry = try FileManager.default.contentsOfDirectory(atPath: journals.path).count
    try expect(beforeRetry == afterRetry && library.organizingChapterIds.isEmpty,
               "retry duplicated file work or left the chapter locked")
    let collisionFile = incoming.appendingPathComponent("collision.webm")
    let originalBytes = Data("untouched source".utf8)
    try originalBytes.write(to: collisionFile)
    let collisionImport = ImportWorkspaceModel(library: library)
    collisionImport.append([collisionFile]); collisionImport.input.title = "Collision pending"
    await collisionImport.process(move: false)?.value
    try expect(collisionImport.queue.isEmpty, "collision fixture import failed")
    collisionImport.close()
    let collisionChapter = session.entities.first { $0.title == "Collision pending" }!
    let targetPath = try PathPolicy.chapterPath(author: "other author", series: nil, work: nil,
      chapter: collisionChapter.title, language: nil, mediaLanguageCount: 1)
    let collisionTarget = archive.appendingPathComponent(targetPath).appendingPathComponent(collisionFile.lastPathComponent)
    try FileManager.default.createDirectory(at: collisionTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
    let unrelated = Data("existing unrelated target".utf8)
    try unrelated.write(to: collisionTarget)
    do {
      _ = try await library.moveTemporaryFiles(rowId: collisionChapter.id, destinationId: destination.id)
      throw LoginError.server("collision unexpectedly succeeded")
    } catch StorageError.collision {}
    let sourceAfterCollision = try Data(contentsOf: collisionFile)
    let targetAfterCollision = try Data(contentsOf: collisionTarget)
    try expect(sourceAfterCollision == originalBytes && targetAfterCollision == unrelated,
               "collision changed source or overwrote destination")
    print("PASS: Pending Organization groups source-only comic/standalone references; one-click MP4/WebM/PDF moves; mixed translations; stable media/text; shared-source retention; failed metadata keeps originals and blocks duplicate moves.")
    print(
      "PASS: direct MP4/WebM/PDF import; exact file bookmarks; independent sibling-file grants; add-only readback after releasing scopes; single-file commit/cleanup preserves bytes and siblings."
    )
  }

  private static func sharedSourceChecks(directory: URL) async throws {
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    defer { library.reset() }
    let root = directory.appendingPathComponent("sources")
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("original.webm")
    try Data("shared original bytes".utf8).write(to: file)
    let broad = try await session.create(.init(kind: .storageRoot, title: "Broad source",
      description: LibraryDestinationIdentity.sourceOnlyDescription, storageKind: "local"))
    let narrow = try await session.create(.init(kind: .storageRoot, title: "Nested source",
      description: LibraryDestinationIdentity.sourceOnlyDescription, storageKind: "local"))
    try library.local.bind(broad, to: root)
    try library.local.bind(narrow, to: nested)
    let original = MediaVersion(id: "new-import", language: "ja", kind: "video",
      storageRootId: narrow.id, relativePaths: ["original.webm"], pageCount: 1)
    _ = try await session.create(.init(kind: .chapter, title: "Current import", media: [original]))
    let initial = try await library.local.sourceIsShared([file], excluding: original.id)
    try expect(!initial, "current import must not keep itself as a shared reference")
    var other = original; other.id = "existing-reference"; other.storageRootId = broad.id
    other.relativePaths = ["nested/original.webm"]
    let chapter = try await session.create(.init(kind: .chapter, title: "Existing reference", media: [other]))
    let added = try await library.local.sourceIsShared([file], excluding: original.id)
    try expect(added, "new reference must invalidate the cached index and match across nested roots")
    var detached = chapter.input; detached.media = []
    try await session.update(chapter, input: detached)
    let removed = try await library.local.sourceIsShared([file], excluding: original.id)
    try expect(!removed, "removed reference remains in the cached index")
    // A binding changes without changing metadata. No physical-path answer may be cached.
    var narrowReference = original; narrowReference.id = "rebound-reference"
    _ = try await session.create(.init(kind: .chapter, title: "Rebound reference", media: [narrowReference]))
    let beforeRebind = try await library.local.sourceIsShared([file], excluding: original.id)
    try expect(beforeRebind, "same-folder reference not protected")
    let elsewhere = directory.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try library.local.bind(narrow, to: elsewhere)
    let afterRebind = try await library.local.sourceIsShared([file], excluding: original.id)
    try expect(!afterRebind, "rebound root reused stale filesystem answers")
    // Exercise the actual import/move path, not just the lookup helper.
    let alias = root.appendingPathComponent("renamed.webm")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "nested/original.webm")
    other.relativePaths = ["renamed.webm"]
    _ = try await session.create(.init(kind: .chapter, title: "Alias reference", media: [other]))
    let archive = directory.appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let destination = try await session.create(.init(kind: .storageRoot, title: "Archive", storageKind: "local"))
    try library.local.bind(destination, to: archive)
    let model = ImportWorkspaceModel(library: library)
    model.append([file]); model.input.title = "Keep aliased original"; model.destinationId = destination.id
    await model.process(move: true)?.value
    try expect(model.queue.isEmpty, "shared-source commit failed: " + model.status)
    try expect(FileManager.default.fileExists(atPath: file.path), "move removed another chapter's aliased source")
    let archived = session.entities.first { $0.title == "Keep aliased original" }!.media[0]
    let result = try await library.local.url(for: archived, file: 0)
    let actual = try Data(contentsOf: result)
    try expect(actual == Data("shared original bytes".utf8), "archived shared file bytes changed")
    model.close()
    print("PASS: shared-source index invalidates on metadata and root rebinding; nested roots and renamed symlinks retain originals during actual import commit.")
  }
}
