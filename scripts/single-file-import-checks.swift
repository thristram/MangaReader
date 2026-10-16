import Foundation
import MangaCore

@MainActor enum SingleFileImportChecks {
  static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw LoginError.server("Single-file import check: " + message) }
  }
  static func run(directory: URL) async throws {
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
    print(
      "PASS: direct MP4/WebM/PDF import; exact file bookmarks; independent sibling-file grants; add-only readback after releasing scopes; single-file commit/cleanup preserves bytes and siblings."
    )
  }
}
