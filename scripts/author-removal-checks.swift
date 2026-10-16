import Foundation
import MangaCore

@MainActor enum AuthorRemovalChecks {
  static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw LoginError.server("Author removal check: " + message) }
  }
  static func run(directory: URL) async throws {
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    NativeUIFixtures.validateHierarchy = true
    defer {
      NativeUIFixtures.validateHierarchy = false
      NativeUIFixtures.rejectedUpdateIds = []
    }
    let empty = try await session.create(.init(kind: .author, title: "Empty author"))
    try await session.deleteAuthor(empty)
    try expect(!session.entities.contains { $0.id == empty.id }, "empty author survives deletion")
    try expect(
      !session.entities.contains { $0.kind == .author && $0.title == "other author" },
      "empty author deletion creates an unnecessary fallback")
    var input = MetadataInput(kind: .author, title: "Remove this author")
    input.nsfw = true
    let author = try await session.create(input)
    let series = try await session.create(
      .init(kind: .series, title: "Keep series", authorId: author.id))
    let work = try await session.create(
      .init(kind: .work, title: "Keep comic", authorId: author.id, seriesId: series.id))
    var media = session.entities.first { $0.id == "c0-0" }!.media[0]
    media.id = UUID().uuidString
    let first = try await session.create(
      .init(
        kind: .chapter, title: "Keep chapter", description: "Keep text",
        authorId: author.id, seriesId: series.id, workId: work.id, media: [media]))
    let second = try await session.create(
      .init(
        kind: .chapter, title: "Retry chapter",
        authorId: author.id, seriesId: series.id, workId: work.id))
    try await session.saveState(.init(entityId: first.id, pageIndex: 0, starred: true))
    let urls = try library.local.urls(for: media)
    let bytes = try Data(contentsOf: urls[0])
    NativeUIFixtures.rejectedUpdateIds.insert(second.id)
    do {
      try await session.deleteAuthor(author)
      throw LoginError.server("Rejected child update succeeded")
    } catch let error as APIError { try expect(error.status == 409, "unexpected child failure") }
    try expect(
      session.entities.contains { $0.id == author.id },
      "author deleted before reassignment finished")
    let fallback = session.entities.first { $0.kind == .author && $0.title == "other author" }!
    try expect(
      session.entities.first { $0.id == work.id }?.authorId == fallback.id,
      "successful parent reassignment is not retained after failure")
    NativeUIFixtures.rejectedUpdateIds = []
    try await session.deleteAuthor(author)
    try expect(!session.entities.contains { $0.id == author.id }, "retry did not delete author")
    for id in [series.id, work.id, first.id, second.id] {
      let current = session.entities.first { $0.id == id }
      try expect(
        current?.authorId == fallback.id && current?.nsfw == true,
        "item is orphaned or loses inherited hidden state")
    }
    let chapter = session.entities.first { $0.id == first.id }!
    try expect(
      chapter.workId == work.id && chapter.seriesId == series.id
        && chapter.description == first.description,
      "hierarchy or description changed")
    try expect(
      chapter.media[0].relativePaths == media.relativePaths && chapter.media[0].id == media.id,
      "media location or identity changed")
    try expect(session.personalState(first.id, page: 0)?.starred == true, "page marks lost")
    let after = try Data(contentsOf: urls[0])
    try expect(after == bytes, "original file changed")
    do {
      try await session.deleteAuthor(fallback)
      throw LoginError.invalidToken
    } catch let error as LoginError {
      try expect(
        error.localizedDescription.contains("default author"),
        "referenced fallback was not protected")
    }
    let unprivileged = try await session.create(.init(kind: .author, title: "No permission"))
    session.account?.scopes = ["manga:read"]
    do {
      try await session.deleteAuthor(unprivileged)
      throw LoginError.server("Missing manage scope accepted")
    } catch LoginError.invalidToken {}
    try expect(
      session.entities.contains { $0.id == unprivileged.id }, "read-only account deleted author")
    print(
      "PASS: author removal; strict parent-first reassignment; hidden items; child failure/retry; preserved paths/bytes/text/state; fallback protection; manage scope."
    )
  }
}
