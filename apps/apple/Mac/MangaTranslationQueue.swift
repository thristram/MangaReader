import AppKit
import Foundation
import ImageIO
import MangaCore
import PDFKit
import UniformTypeIdentifiers

struct MangaTranslationPage: Codable, Identifiable, Sendable {
  var id: Int { canonical }
  let canonical: Int
  let sourceMediaId: String
  let sourceIndex: Int
  let sourceName: String
  var status = "pending"
  var error = ""
  var cachedName: String?
}
struct MangaTranslationJob: Codable, Identifiable, Sendable {
  let id: String
  let ownerId: String
  let chapterId: String
  let title: String
  let description: String
  let addedAt: Date
  let baseURL: String
  let options: MangaImageTranslationOptions
  let destinationId: String
  let sourceMedia: MediaVersion
  let targetMediaId: String
  var pages: [MangaTranslationPage]
  var status = "queued"
  var detail = "Queued"
  var error = ""
  var finishedCount: Int { pages.filter { ["committed", "existing"].contains($0.status) }.count }
  var progress: Double { Double(finishedCount) / Double(max(1, pages.count)) }
}
struct LegacyTranslationRecovery: Sendable {
  let mediaId: String
  let language: String
  let canonical: Int
  let count: Int
  let cachedSource: URL
}
private actor MangaTranslationJobStore {
  private var revisions: [String: Int] = [:]
  func save(_ jobs: [MangaTranslationJob], at directory: URL, revision: Int) throws {
    guard revision >= (revisions[directory.path] ?? 0) else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(jobs).write(to: directory.appendingPathComponent("queue.json"), options: .atomic)
    revisions[directory.path] = revision
  }
}

@MainActor final class MangaTranslationQueue: ObservableObject {
  unowned let library: LibraryUIModel
  @Published private(set) var jobs: [MangaTranslationJob] = []
  var serviceSession: URLSession = .shared
  private var task: Task<Void, Never>?
  private var epoch = UUID()
  private var loadedDirectory: URL?
  private var restoring: Task<Void, Never>?
  private let store = MangaTranslationJobStore()
  private var saveRevision = 0
  init(library: LibraryUIModel) { self.library = library }
  var pendingCount: Int { jobs.filter { ["queued", "running"].contains($0.status) }.count }
  var hasErrors: Bool { jobs.contains { $0.status == "failed" } }
  var directory: URL? { library.session.cacheDirectory?.appendingPathComponent("image-translations", isDirectory: true) }
  func outputURL(job: MangaTranslationJob, page: MangaTranslationPage) -> URL? {
    guard let directory, let name = page.cachedName else { return nil }
    return try? PathPolicy.resolve(job.id + "/" + name, under: directory)
  }
  func reset() {
    epoch = UUID()
    task?.cancel()
    task = nil
    restoring?.cancel()
    restoring = nil
    jobs = []
    loadedDirectory = nil
  }
  func restore() async {
    if let restoring { await restoring.value; return }
    guard loadedDirectory != directory else { return }
    let token = epoch
    let operation = Task { await load() }
    restoring = operation
    await operation.value
    if token == epoch { restoring = nil }
  }
  private func load() async {
    guard let directory, loadedDirectory != directory else { return }
    let owner = library.session.account?.ownerId
    let token = epoch
    loadedDirectory = directory
    do {
      let restored = try await FileTasks.perform { () -> [MangaTranslationJob] in
        let file = directory.appendingPathComponent("queue.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([MangaTranslationJob].self, from: Data(contentsOf: file))
      }
      guard token == epoch, owner == library.session.account?.ownerId else { return }
      jobs = restored.filter { $0.ownerId == owner }.map { item in
        var item = item
        if item.status == "running" {
          item.status = "failed"
          item.error = "Translation was interrupted. Retry to continue from cached and committed pages."
          item.detail = "Interrupted"
        }
        return item
      }.sorted { $0.addedAt > $1.addedAt }
      try await save()
      start()
    } catch {
      guard token == epoch else { return }
      // Do not overwrite an unreadable queue with an empty file.
      loadedDirectory = nil
      library.show(LoginError.server("Could not restore the translation queue: " + error.localizedDescription))
    }
  }
  private func save() async throws {
    guard let directory else { throw LoginError.invalidToken }
    saveRevision += 1
    try await store.save(jobs, at: directory, revision: saveRevision)
  }
  @discardableResult func enqueue(chapter: LibraryEntity, source: MediaVersion,
    options: MangaImageTranslationOptions, baseURL: String, destinationId: String) async throws -> String {
    await restore()
    guard loadedDirectory == directory, library.canManage, let owner = library.session.account?.ownerId,
      let current = library.entity(chapter.id), current.revision == chapter.revision,
      current.media.contains(where: { $0.id == source.id }), source.kind != "video",
      let destination = library.entity(destinationId), destination.isArchiveDestination,
      !jobs.contains(where: { $0.chapterId == chapter.id && ["queued", "running"].contains($0.status) })
    else { throw LoginError.server("This chapter changed or already has a queued translation. Review its queue first.") }
    try options.validate()
    guard options.mediaLanguage != source.language else { throw LoginError.server("Choose a target language different from the source media language.") }
    let client = try MangaImageTranslationService(baseURL: baseURL, session: serviceSession)
    try await client.testConnection()
    _ = try await library.local.validateDestinationAsync(destination)
    guard owner == library.session.account?.ownerId,
      library.entity(chapter.id)?.revision == current.revision,
      !jobs.contains(where: { $0.chapterId == chapter.id && ["queued", "running"].contains($0.status) }) else { throw LoginError.server("The chapter changed while connecting. Open Translate Manga again.") }
    let target = current.media.first { $0.language == options.mediaLanguage }
    guard target == nil || target?.kind == "images" else {
      throw LoginError.server("The target language is a PDF or video version. Choose another language.")
    }
    let original = current.media.first { $0.language == current.originalLanguage } ?? current.media[0]
    let count = max(original.pageAlignment?.count ?? original.pageCount, source.pageAlignment?.count ?? source.pageCount)
    var pages: [MangaTranslationPage] = []
    for canonical in 0..<count {
      guard let page = library.pageMedia(current, preferred: source, page: canonical), page.media.kind != "video" else {
        throw LoginError.server("A source page is unavailable. Review the chapter's page alignment first.")
      }
      let fileIndex = page.media.kind == "pdf" ? 0 : page.index
      guard page.media.relativePaths.indices.contains(fileIndex) else { throw StorageError.emptyChapter }
      let file = page.media.relativePaths[fileIndex]
      var item = MangaTranslationPage(canonical: canonical, sourceMediaId: page.media.id,
        sourceIndex: page.index, sourceName: (file as NSString).lastPathComponent)
      if target?.sourcePage(at: canonical) != nil { item.status = "existing" }
      pages.append(item)
    }
    guard pages.contains(where: { $0.status == "pending" }) else {
      throw LoginError.server("This language already has every page. Existing translations were kept.")
    }
    let job = MangaTranslationJob(id: UUID().uuidString.lowercased(), ownerId: owner, chapterId: current.id,
      title: library.title(current), description: current.description(in: AppConfiguration.preferredLanguage), addedAt: Date(), baseURL: baseURL,
      options: options, destinationId: destinationId, sourceMedia: source,
      targetMediaId: target?.id ?? UUID().uuidString.lowercased(), pages: pages)
    jobs.insert(job, at: 0)
    do { try await save() } catch { jobs.removeAll { $0.id == job.id }; throw error }
    try options.save()
    start()
    return job.id
  }
  func retry(_ id: String) {
    guard let index = jobs.firstIndex(where: { $0.id == id && $0.status == "failed" }), library.canManage else { return }
    jobs[index].status = "queued"
    jobs[index].error = ""
    jobs[index].detail = "Queued · continue unfinished pages"
    let token = epoch
    Task {
      do { try await save(); if token == epoch { start() } }
      catch { if token == epoch { fail(id, error: error) } }
    }
  }
  private func change(_ id: String, _ body: (inout MangaTranslationJob) -> Void) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    body(&jobs[index])
  }
  private func fail(_ id: String, error: Error) {
    change(id) { $0.status = "failed"; $0.error = error.localizedDescription; $0.detail = "Translation needs attention" }
  }
  private func start() {
    guard task == nil, let job = jobs.last(where: { $0.status == "queued" }), library.canManage else { return }
    let token = epoch
    task = Task {
      defer { if token == epoch { task = nil; start() } }
      do { try await run(job.id, token: token) }
      catch {
        guard token == epoch else { return }
        fail(job.id, error: error)
        try? await save()
      }
    }
  }
  private func currentJob(_ id: String, token: UUID) throws -> MangaTranslationJob {
    try Task.checkCancellation()
    guard token == epoch, let job = jobs.first(where: { $0.id == id }),
      job.ownerId == library.session.account?.ownerId, library.canManage else { throw LoginError.invalidToken }
    return job
  }
  private func source(_ job: MangaTranslationJob, page: MangaTranslationPage) throws -> (LibraryEntity, MediaVersion, Int) {
    guard let chapter = library.entity(job.chapterId),
      let preferred = chapter.media.first(where: { $0.id == job.sourceMedia.id }),
      preferred.kind == job.sourceMedia.kind, preferred.pageCount == job.sourceMedia.pageCount,
      preferred.pageAlignment == job.sourceMedia.pageAlignment,
      let source = library.pageMedia(chapter, preferred: preferred, page: page.canonical),
      source.media.id == page.sourceMediaId, source.index == page.sourceIndex,
      source.media.relativePaths.indices.contains(source.media.kind == "pdf" ? 0 : source.index),
      (source.media.relativePaths[source.media.kind == "pdf" ? 0 : source.index] as NSString).lastPathComponent == page.sourceName
    else { throw LoginError.server("The source chapter or page order changed. Cached translations are retained; review the chapter before continuing.") }
    return (chapter, source.media, source.index)
  }
  private func run(_ id: String, token: UUID) async throws {
    var job = try currentJob(id, token: token)
    let client = try MangaImageTranslationService(baseURL: job.baseURL, session: serviceSession)
    change(id) { $0.status = "running"; $0.detail = "Connecting to image translator…"; $0.error = "" }
    try await save()
    let imageAPI = try await client.testConnection()
    for offset in job.pages.indices {
      job = try currentJob(id, token: token)
      if ["committed", "existing"].contains(job.pages[offset].status) { continue }
      var page = job.pages[offset]
      do {
        let (_, media, index) = try source(job, page: page)
        guard let cacheDirectory = directory else { throw LoginError.invalidToken }
        let name = job.id + "-" + String(format: "%06d", page.canonical + 1) + ".png"
        let output = try PathPolicy.resolve(job.id + "/" + name, under: cacheDirectory)
        if page.cachedName == nil || !FileManager.default.fileExists(atPath: output.path) {
          change(id) { $0.detail = "Translating page \(offset + 1) of \(job.pages.count)…" }
          let url = try await library.mediaURL(media, index: media.kind == "pdf" ? 0 : index)
          let input = try await Self.png(url: url, pdfPage: media.kind == "pdf" ? index : nil)
          _ = try currentJob(id, token: token)
          let result = try await client.translate(image: input, options: job.options, api: imageAPI)
          _ = try currentJob(id, token: token)
          _ = try source(job, page: page)
          try await FileTasks.perform {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.write(to: output, options: .atomic)
          }
          page.cachedName = name
          page.status = "translated"
          page.error = ""
          let resultPage = page
          change(id) { $0.pages[offset] = resultPage; $0.detail = "Organizing page \(offset + 1)…" }
          try await save()
        } else {
          // Older clients cached valid PNG placeholders. Do not publish one
          // while resuming an unfinished file commit, or discard real output.
          let cached = try await FileTasks.perform { try Data(contentsOf: output) }
          try await MangaImageTranslationService.validateResult(cached)
        }
        _ = try currentJob(id, token: token)
        if try await recoverCommit(job: job, page: page, output: output) == false {
          let (chapter, _, _) = try source(job, page: page)
          let request = AddImagesRequest(chapter: chapter, files: [try ImportSourceAccess(output)])
          _ = try await library.commitAddedImages(request, language: job.options.mediaLanguage,
            destinationId: job.destinationId, placement: TranslationPagePlacement(mediaId: job.targetMediaId,
              canonical: page.canonical, count: job.pages.count), progress: { [weak self] detail in
                guard let self, token == self.epoch else { return }
                self.change(id) { $0.detail = detail + " · Page \(offset + 1) of \(job.pages.count)" }
              })
        }
        _ = try currentJob(id, token: token)
        change(id) { $0.pages[offset].status = "committed"; $0.pages[offset].error = "" }
        try await save()
      } catch {
        guard token == epoch else { throw error }
        change(id) { $0.pages[offset].error = error.localizedDescription; $0.pages[offset].status = "failed" }
        throw error
      }
    }
    _ = try currentJob(id, token: token)
    change(id) { $0.status = "completed"; $0.detail = "All translated pages are organized."; $0.error = "" }
    try await save()
  }
  private func recoverCommit(job: MangaTranslationJob, page: MangaTranslationPage, output: URL) async throws -> Bool {
    guard let journals = library.session.cacheDirectory?.appendingPathComponent("organization-journals") else { throw LoginError.invalidToken }
    let plans = try await FileTasks.perform { () -> [OrganizationJournal] in
      guard FileManager.default.fileExists(atPath: journals.path) else { return [] }
      return try FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .compactMap { try? JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: $0)) }
        .filter { $0.entityId == job.chapterId && $0.files.contains { $0.source == output.path }
          && $0.metadata.media.contains { $0.id == job.targetMediaId } }
    }
    guard let plan = plans.first else { return false }
    guard plans.count == 1 else {
      throw LoginError.server("More than one file commit references this translated page. Review File Management Queue before retrying. Cached translations are retained.")
    }
    if plan.phase != "complete" { try await library.resumeOrganizationPlan(plan) }
    guard let current = library.entity(job.chapterId),
      let actual = current.media.first(where: { $0.id == job.targetMediaId }),
      let expected = plan.metadata.media.first(where: { $0.id == job.targetMediaId }),
      let position = actual.sourcePage(at: page.canonical), let prior = expected.sourcePage(at: page.canonical),
      actual.relativePaths.indices.contains(position), expected.relativePaths.indices.contains(prior),
      actual.relativePaths[position] == expected.relativePaths[prior], actual.storageRootId == expected.storageRootId
    else { throw LoginError.server("This translated page changed after its file commit. Review Commit History before retrying.") }
    return true
  }
  /// Used by both Translation Queue Retry and the file journal's recovery action.
  func legacyRecovery(for plan: OrganizationJournal) -> LegacyTranslationRecovery? {
    let matches = jobs.filter { $0.ownerId == library.session.account?.ownerId
      && $0.ownerId == plan.libraryId && $0.chapterId == plan.entityId && $0.destinationId == plan.rootId }
      .flatMap { job in
        job.pages.compactMap { page -> LegacyTranslationRecovery? in
          guard let output = outputURL(job: job, page: page),
            plan.files.contains(where: { $0.source == output.path }),
            plan.metadata.media.contains(where: { $0.id == job.targetMediaId }) else { return nil }
          return LegacyTranslationRecovery(mediaId: job.targetMediaId, language: job.options.mediaLanguage,
            canonical: page.canonical, count: job.pages.count, cachedSource: output)
        }
      }
    return matches.count == 1 ? matches[0] : nil
  }
  func recordRecoveredCommit(_ plan: OrganizationJournal) async throws {
    guard let context = legacyRecovery(for: plan), let chapter = library.entity(plan.entityId),
      let actual = chapter.media.first(where: { $0.id == context.mediaId }),
      let expected = plan.metadata.media.first(where: { $0.id == context.mediaId }),
      let position = actual.sourcePage(at: context.canonical),
      let prior = expected.sourcePage(at: context.canonical),
      actual.relativePaths.indices.contains(position), expected.relativePaths.indices.contains(prior),
      actual.relativePaths[position] == expected.relativePaths[prior],
      actual.storageRootId == expected.storageRootId,
      let job = jobs.first(where: { job in job.targetMediaId == context.mediaId
        && job.pages.contains { $0.canonical == context.canonical
          && outputURL(job: job, page: $0) == context.cachedSource } }) else { return }
    change(job.id) { value in
      guard let index = value.pages.firstIndex(where: { $0.canonical == context.canonical }) else { return }
      value.pages[index].status = "committed"
      value.pages[index].error = ""
      if value.finishedCount == value.pages.count {
        value.status = "completed"
        value.error = ""
        value.detail = "All translated pages are organized."
      } else if value.status == "failed" {
        value.error = ""
        value.detail = "File commit recovered. Retry to continue the remaining pages."
      }
    }
    try await save()
  }
  nonisolated static func png(url: URL, pdfPage: Int?) async throws -> Data {
    let decoded = pdfPage == nil ? try await ReadingPageDecoder.load(url: url, pdfPage: nil) : nil
    return try await FileTasks.perform {
      try autoreleasepool {
        let image: CGImage
        if let pdfPage {
          guard let document = PDFDocument(url: url), let page = document.page(at: pdfPage) else { throw ReadingPageDecodingError.invalidPDF }
          let bounds = page.bounds(for: .mediaBox)
          guard bounds.width > 0, bounds.height > 0 else { throw ReadingPageDecodingError.invalidPDF }
          let scale = min(2, 2400 / max(bounds.width, bounds.height))
          var rect = CGRect(origin: .zero, size: CGSize(width: bounds.width * scale, height: bounds.height * scale))
          guard let result = page.thumbnail(of: rect.size, for: .mediaBox).cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw ReadingPageDecodingError.invalidPDF
          }
          image = result
        } else {
          guard case .image(let result) = decoded else { throw ReadingPageDecodingError.invalidImage }
          image = result
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
          throw ReadingPageDecodingError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReadingPageDecodingError.invalidImage }
        return data as Data
      }
    }
  }
}
