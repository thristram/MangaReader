import AppKit
import Foundation
import MangaCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Capture a durable grant while the picker/drop callback still owns access.
// The workspace, queue and failed-job retry share this lease; none can revoke
// another owner's access by closing its own screen or worker.
final class ImportSourceAccess: @unchecked Sendable {
  let url: URL
  let bookmark: Data
  private let accessing: Bool
  init(_ url: URL) throws {
    self.url = url
    accessing = url.startAccessingSecurityScopedResource()
    do { bookmark = try LocalMedia.bookmark(for: url) } catch {
      if accessing { url.stopAccessingSecurityScopedResource() }
      throw error
    }
  }
  deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}

@MainActor final class ImportWorkspaceModel: ObservableObject {
  let library: LibraryUIModel
  @Published var queue: [ImportCandidate] = []
  @Published var index = 0
  @Published var input = MetadataInput(
    kind: .chapter, title: "", originalLanguage: AppConfiguration.preferredLanguage)
  @Published var translationOf: String?
  @Published var isTranslation = false
  @Published var pageAlignment: [Int?] = []
  private var processing: Task<Void, Never>?
  private var added: [String: (chapterId: String, mediaId: String)] = [:]
  var importedChapterId: String? { added.values.first?.chapterId }
  @Published var busy = false
  @Published var status = ""
  @Published var result = ""
  @Published var progress = 0.0
  @Published var destinationId: String?
  @Published var review = false
  var sources: [ImportSourceAccess] = []
  init(library: LibraryUIModel) { self.library = library }
  var current: ImportCandidate? { queue.indices.contains(index) ? queue[index] : nil }
  var canSubmit: Bool {
    isTranslation
      ? library.entity(translationOf)?.kind == .chapter
      : !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  func managedPath() throws -> String {
    let original = library.entity(translationOf)
    let author = library.session.entities.first { $0.id == (original?.authorId ?? input.authorId) }?
      .title
    let work = library.session.entities.first { $0.id == (original?.workId ?? input.workId) }
    let series = library.session.entities.first {
      $0.id == (original?.seriesId ?? input.seriesId ?? work?.seriesId)
    }?.title
    return try PathPolicy.chapterPath(
      author: author, series: series, work: work?.title, chapter: original?.title ?? input.title,
      language: input.originalLanguage,
      mediaLanguageCount: original == nil ? 1 : (original!.media.count + 1))
  }
  var proposedPath: String {
    (try? managedPath()) ?? "Use names without /, \\, or : before moving files."
  }
  func append(_ urls: [URL]) {
    for url in urls {
      do { append(try ImportSourceAccess(url)) } catch { status = error.localizedDescription }
    }
  }
  func append(_ access: ImportSourceAccess) {
    do {
      let wasEmpty = queue.isEmpty
      let candidates = try ImportScanner.scan(access.url)
      sources.append(access)
      queue.append(contentsOf: candidates)
      if wasEmpty { select(0) }
    } catch { status = error.localizedDescription }
  }
  func select(_ index: Int) {
    guard queue.indices.contains(index) else { return }
    self.index = index
    translationOf = nil
    isTranslation = false
    pageAlignment = []
    result = ""
    let name = ImportName.parse(queue[index].title)
    input = MetadataInput(
      kind: .chapter, title: name.title,
      originalLanguage: AppConfiguration.preferredLanguage)
    if let id = name.pixivID { input.sources = [.init(site: "pixiv", value: id)] }
    status = queue[index].warnings.joined(separator: " ")
  }
  func close() {
    processing?.cancel()
    processing = nil
    sources = []
  }
  // Retain the exact selected resource: a directory grants its descendants,
  // while a standalone PDF/video grants only that file, never its parent.
  private func sourceResource(for candidate: ImportCandidate) -> URL {
    let path = candidate.source.standardizedFileURL.path
    return sources.map(\.url).filter { selected in
      let base = selected.standardizedFileURL.path
      return path == base || path.hasPrefix(base + "/")
    }.max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
      ?? candidate.source
  }
  private func relativeSourcePaths(for candidate: ImportCandidate, under folder: URL) throws
    -> [String]
  {
    let prefix = folder.standardizedFileURL.path + "/"
    return try candidate.pages.map { page in
      let path = page.standardizedFileURL.path
      guard path.hasPrefix(prefix) else { throw StorageError.unsafePath }
      let relative = String(path.dropFirst(prefix.count))
      _ = try relative.split(separator: "/", omittingEmptySubsequences: false).map {
        try PathPolicy.component(String($0))
      }
      return relative
    }
  }
  @discardableResult func process(move: Bool) -> Task<Void, Never>? {
    guard !busy, library.canManage, let candidate = current,
      translationOf != nil || !input.title.trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    busy = true
    status = "Adding chapter…"
    let owner = library.session.account?.ownerId
    processing = Task {
      defer {
        busy = false
        processing = nil
      }
      @MainActor func checkOwner() throws {
        try Task.checkCancellation()
        guard owner != nil, owner == library.session.account?.ownerId else {
          throw LoginError.invalidToken
        }
      }
      var failureContext = move ? "Checking destination" : "Adding chapter"
      var fileWorkStarted = false
      do {
        try checkOwner()
        if move { _ = try managedPath() }
        let managed = library.session.entities.first {
          $0.id == destinationId && $0.isArchiveDestination
        }
        var destination: URL?
        if move, let managed {
          destination = try await library.local.validateDestinationAsync(managed)
        }
        guard !move || (destination != nil && candidate.warnings.isEmpty) else {
          throw LoginError.server(
            "Add and connect a destination in Media Storage, then select it here.")
        }
        let session = library.session
        if let translationOf, library.entity(translationOf) == nil {
          throw LoginError.server(
            "The original chapter is unavailable or hidden. Choose another chapter.")
        }
        var metadata = input
        if let translationOf,
          let original = session.visibleEntities(kind: .chapter).first(where: {
            $0.id == translationOf
          })
        {
          metadata.authorId = original.authorId
          metadata.workId = original.workId
          metadata.seriesId = original.seriesId
        }
        if metadata.authorId == nil {
          let existing = session.entities.first {
            $0.kind == .author && !$0.deleted && $0.title == "other author"
          }
          if let existing {
            metadata.authorId = existing.id
          } else {
            metadata.authorId = try await session.create(
              .init(kind: .author, title: "other author")
            ).id
          }
        }
        if metadata.seriesId == nil {
          metadata.seriesId = session.entities.first { $0.id == metadata.workId }?.seriesId
        }
        try checkOwner()
        let resource = sourceResource(for: candidate)
        let fileGrant = candidate.kind != "images" && resource == candidate.source
        let folder = fileGrant ? resource.deletingLastPathComponent() : resource
        let sourcePaths = try relativeSourcePaths(for: candidate, under: folder)
        failureContext =
          "Connecting source \(fileGrant ? "file" : "folder") “\(resource.lastPathComponent)”"
        let sourceRoots = session.entities.filter { $0.kind == .storageRoot && !$0.deleted }
        var existingRoot: LibraryEntity?
        for root in sourceRoots {
          try checkOwner()
          if (try? await library.local.boundSourceURL(root.id)) == resource {
            existingRoot = root
            break
          }
        }
        let root: LibraryEntity
        if let existingRoot {
          root = existingRoot
        } else {
          root = try await session.create(
            .init(
              kind: .storageRoot, title: resource.lastPathComponent,
              description: LibraryDestinationIdentity.sourceOnlyDescription, storageKind: "local"))
        }
        try checkOwner()
        try library.local.bind(
          root, to: resource, initializeDestination: false,
          sourceBookmark: sources.first { $0.url == resource }?.bookmark)
        failureContext = "Adding chapter metadata"
        let count =
          candidate.kind == "pdf"
          ? PDFDocument(url: candidate.source)?.pageCount ?? 1
          : candidate.kind == "video" ? 1 : candidate.pages.count
        var version = MediaVersion(
          language: metadata.originalLanguage, kind: candidate.kind, storageRootId: root.id,
          relativePaths: sourcePaths, pageCount: count)
        var chapter: LibraryEntity
        if let added = added[candidate.id],
          let existing = session.entities.first(where: { $0.id == added.chapterId && !$0.deleted }),
          let existingMedia = existing.media.first(where: { $0.id == added.mediaId })
        {
          guard existingMedia.storageRootId == root.id else {
            throw LoginError.server(
              "This chapter was already moved. Review Pending Organization to finish the previous operation."
            )
          }
          version = existingMedia
          if translationOf == nil {
            metadata.media = existing.media
            try await session.update(existing, input: metadata)
            chapter = session.entities.first { $0.id == existing.id } ?? existing
          } else {
            chapter = existing
          }
        } else if let translationOf,
          let original = session.entities.first(where: { $0.id == translationOf && !$0.deleted })
        {
          guard !original.media.contains(where: { $0.language == version.language }) else {
            throw LoginError.server(
              "This chapter already has that media language. Choose another language.")
          }
          version.pageAlignment =
            pageAlignment.isEmpty
            ? (0..<(original.media.first?.pageCount ?? 0)).map { $0 < count ? $0 : nil }
            : pageAlignment
          var combined = original.input
          combined.media.append(version)
          if !metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if version.language == original.originalLanguage {
              combined.description = metadata.description
            } else {
              combined.localizations[version.language, default: .init()].description =
                metadata.description
            }
          }
          try await session.update(original, input: combined)
          chapter = session.entities.first { $0.id == original.id } ?? original
        } else {
          metadata.media = [version]
          chapter = try await session.create(metadata)
        }
        added[candidate.id] = (chapter.id, version.id)
        guard owner == session.account?.ownerId else { return }
        var originalsKept = false
        if move, let destination, let managed, translationOf != nil {
          status = "Organizing language folders…"
          failureContext = "Organizing language files"
          fileWorkStarted = true
          try await organizeLanguages(chapter: chapter, destination: managed, folder: destination)
        } else if move, let destination, let managed {
          try checkOwner()
          _ = try await library.local.validateDestinationAsync(managed)
          let path = try managedPath()
          let relative =
            candidate.kind == "images" ? path : path + "/" + candidate.source.lastPathComponent
          guard let journals = session.cacheDirectory?.appendingPathComponent("commit-journals")
          else { throw LoginError.invalidToken }
          var update = chapter.input
          guard let position = update.media.firstIndex(where: { $0.id == version.id }) else {
            throw LoginError.server("The imported media is missing from metadata.")
          }
          update.media[position].storageRootId = managed.id
          update.media[position].relativePaths =
            candidate.kind == "images"
            ? candidate.pages.map { path + "/" + $0.lastPathComponent } : [relative]
          let recovery = try JSONSerialization.data(withJSONObject: [
            "entityId": chapter.id, "revision": chapter.revision,
            "sourceRootId": root.id, "destinationRootId": managed.id,
            "metadata": JSONSerialization.jsonObject(with: JSONEncoder().encode(update)),
          ])
          try checkOwner()
          status = "Checking shared source files…"
          let keepSource = try await library.local.sourceIsShared(
            candidate.pages, excluding: version.id)
          try checkOwner()
          originalsKept = keepSource
          status = "Moving files…"
          failureContext = "Moving “\(candidate.title)”"
          fileWorkStarted = true
          let source = candidate.source
          let journal = try await FileTasks.perform {
            try FileCommit.move(
              source: source, destinationRelativePath: relative, root: destination,
              journalDirectory: journals, recoveryPayload: recovery, keepSource: keepSource)
          }
          try checkOwner()
          failureContext = "Saving moved chapter metadata"
          try await session.update(chapter, input: update)
          try checkOwner()
          _ = try await library.local.validateDestinationAsync(managed)
          failureContext = "Finishing file cleanup"
          try await FileTasks.perform { try FileCommit.finish(journal, in: journals) }
        }
        result =
          "Added “\(candidate.title)”"
          + (move
            ? (originalsKept
              ? ". Archived copies; originals kept because another comic uses them."
              : " and moved its files.") : ". Original files kept in place.")
        added.removeValue(forKey: candidate.id)
        queue.remove(at: index)
        if !queue.isEmpty {
          select(min(index, queue.count - 1))
        } else {
          input.title = ""
          status = "Import complete"
        }
        review = false
      } catch {
        status =
          failureContext + ": " + error.localizedDescription
          + (fileWorkStarted ? " Review Pending Organization before retrying." : "")
      }
    }
    return processing
  }
  func defaultDestination() {
    let roots = library.session.entities.filter { $0.isArchiveDestination }
    let previous = UserDefaults.standard.string(
      forKey: "ArchiveDestination:" + (library.session.account?.ownerId ?? ""))
    let originalRoot = library.entity(translationOf)?.media.first?.storageRootId
    destinationId =
      roots.first { $0.id == previous }?.id
      ?? roots.first { $0.id == originalRoot }?.id ?? roots.first?.id
  }
  func enqueue(move: Bool) {
    guard !busy, let candidate = current, !isTranslation || translationOf != nil else { return }
    library.fileQueue.enqueue(
      candidate: candidate, input: input, translationOf: translationOf,
      alignment: pageAlignment, destinationId: destinationId, move: move, sources: sources)
    if let destinationId {
      UserDefaults.standard.set(
        destinationId, forKey: "ArchiveDestination:" + (library.session.account?.ownerId ?? ""))
    }
    review = false
    result = "Added to the background file queue."
    queue.remove(at: index)
    if queue.isEmpty {
      input.title = ""
      status = "Import queued"
    } else {
      select(min(index, queue.count - 1))
      status = "Previous import is running in the background."
    }
  }
  private func organizeLanguages(chapter: LibraryEntity, destination: LibraryEntity, folder: URL)
    async throws
  {
    let session = library.session
    guard let owner = session.account?.ownerId,
      let directory = session.cacheDirectory?.appendingPathComponent("organization-journals")
    else { throw LoginError.invalidToken }
    let author = library.entity(chapter.authorId)?.title
    let work = library.entity(chapter.workId)
    let series = library.entity(chapter.seriesId ?? work?.seriesId)?.title
    var update = chapter.input
    var plans: [OrganizationFile] = []
    var scoped: [URL] = []
    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
    let sourceRootIds = Array(Set(chapter.media.map(\.storageRootId)))
    // Bookmark access happens on the main actor; all path checks and file work happen off it.
    var sources: [String: URL] = [:]
    for rootId in sourceRootIds {
      let root = try await library.local.readingRootURL(rootId)
      if root.startAccessingSecurityScopedResource() { scoped.append(root) }
      try await FileTasks.perform {
        let marker = try PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root)
        if FileManager.default.fileExists(atPath: marker.path) {
          try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
            .validate(libraryId: owner, destinationId: rootId)
        }
      }
      sources[rootId] = root
    }
    let otherMedia = session.entities.filter { !$0.deleted && $0.id != chapter.id }.flatMap(\.media)
    let referenceRoots = try await library.local.referenceRoots(for: otherMedia)
    let usedElsewhere = try await FileTasks.perform {
      var paths = Set<String>()
      for media in otherMedia {
        try Task.checkCancellation()
        if let root = referenceRoots[media.storageRootId] {
          for path in media.relativePaths {
            paths.insert(root.appendingPathComponent(path).standardizedFileURL.path.lowercased())
          }
        }
      }
      return paths
    }
    for index in update.media.indices {
      let media = update.media[index]
      guard let sourceRoot = sources[media.storageRootId] else { throw LoginError.invalidToken }
      let languagePath = try PathPolicy.chapterPath(
        author: author, series: series, work: work?.title,
        chapter: chapter.title, language: media.language, mediaLanguageCount: update.media.count)
      let paths = media.relativePaths.map {
        languagePath + "/" + URL(fileURLWithPath: $0).lastPathComponent
      }
      for (old, new) in zip(media.relativePaths, paths) {
        let source = try await FileTasks.perform {
          try PathPolicy.mutationPath(old, under: sourceRoot)
        }
        let target = folder.appendingPathComponent(new).standardizedFileURL
        if source.standardizedFileURL != target {
          plans.append(
            OrganizationFile(
              source: source, relativePath: new,
              keepSource: usedElsewhere.contains(source.standardizedFileURL.path.lowercased())))
        }
      }
      update.media[index].storageRootId = destination.id
      update.media[index].relativePaths = paths
    }
    let files = plans
    let metadata = update
    let prepared = try await FileTasks.perform {
      try FileOrganization.prepare(
        entityId: chapter.id, revision: chapter.revision,
        metadata: metadata, libraryId: owner, rootId: destination.id, root: folder,
        sourceRootIds: sourceRootIds, files: files, directory: directory)
    }
    let staged = try await FileTasks.perform { [self] in
      try FileOrganization.stage(prepared, in: directory) { value in
        Task { @MainActor in
          self.progress = value
          self.status = "Organizing language folders · \(Int(value * 100))%"
        }
      }
    }
    try Task.checkCancellation()
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    try await session.update(chapter, input: update)
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    try await FileTasks.perform { try FileOrganization.finish(staged, in: directory) }
  }
}

struct FileQueueItem: Identifiable {
  let id: UUID
  let title: String
  var status: String
  var completed = false
  var failed = false
}
@MainActor final class ImportFileQueue: ObservableObject {
  unowned let library: LibraryUIModel
  @Published var items: [FileQueueItem] = []
  @Published var progress = 0.0
  @Published var detail = ""
  private var waiting: [(UUID, ImportWorkspaceModel, Bool)] = []
  private var task: Task<Void, Never>?
  private var failedWorkers: [UUID: (ImportWorkspaceModel, Bool, [ImportSourceAccess])] = [:]
  private var activeChapter: String?
  private var activeAuthor: String?
  private var epoch = UUID()
  init(library: LibraryUIModel) { self.library = library }
  func enqueue(
    candidate: ImportCandidate, input: MetadataInput, translationOf: String?,
    alignment: [Int?], destinationId: String?, move: Bool, sources: [ImportSourceAccess]
  ) {
    let worker = ImportWorkspaceModel(library: library)
    worker.queue = [candidate]
    worker.input = input
    worker.translationOf = translationOf
    worker.pageAlignment = alignment
    worker.destinationId = destinationId
    worker.sources = sources
    let id = UUID()
    items.append(
      FileQueueItem(
        id: id, title: library.entity(translationOf)?.title ?? input.title, status: "Queued"))
    waiting.append((id, worker, move))
    start()
  }
  private func start() {
    guard task == nil, !waiting.isEmpty else { return }
    let (id, worker, move) = waiting.removeFirst()
    let owner = library.session.account?.ownerId
    let permissions = worker.sources
    activeChapter = worker.translationOf
    activeAuthor =
      worker.translationOf.flatMap {
        library.session.catalog.entity($0, showNSFW: true)?.authorId
      } ?? worker.input.authorId
    let epoch = epoch
    items[items.firstIndex { $0.id == id }!].status = "Running"
    task = Task {
      defer {
        worker.close()
        if self.epoch == epoch {
          task = nil
          activeChapter = nil
          activeAuthor = nil
          start()
        }
      }
      guard let operation = worker.process(move: move) else {
        if let index = items.firstIndex(where: { $0.id == id }) {
          items[index].failed = true
          items[index].status = "Import is unavailable. Check your account and import metadata."
          failedWorkers[id] = (worker, move, permissions)
        }
        return
      }
      while worker.busy && !Task.isCancelled {
        detail = worker.status
        progress = worker.progress
        try? await Task.sleep(for: .milliseconds(100))
      }
      if Task.isCancelled {
        worker.close()
        await operation.value
        return
      }
      await operation.value
      guard owner == library.session.account?.ownerId, self.epoch == epoch,
        let index = items.firstIndex(where: { $0.id == id })
      else { return }
      items[index].completed = worker.queue.isEmpty
      items[index].failed = !worker.queue.isEmpty
      if !worker.queue.isEmpty { failedWorkers[id] = (worker, move, permissions) }
      items[index].status = worker.queue.isEmpty ? worker.result : worker.status
      detail = ""
      progress = 0
    }
  }
  func manages(_ chapter: String) -> Bool {
    activeChapter == chapter || waiting.contains { $0.1.translationOf == chapter }
  }
  func managesAuthor(_ id: String) -> Bool {
    activeAuthor == id
      || waiting.contains { _, worker, _ in
        (worker.translationOf.flatMap {
          library.session.catalog.entity($0, showNSFW: true)?.authorId
        }
          ?? worker.input.authorId) == id
      }
  }
  func retry(_ id: UUID) {
    guard let (worker, move, permissions) = failedWorkers.removeValue(forKey: id),
      let index = items.firstIndex(where: { $0.id == id })
    else { return }
    if worker.destinationId == nil { worker.defaultDestination() }
    worker.sources = permissions
    items[index].failed = false
    items[index].status = "Queued"
    waiting.append((id, worker, move))
    start()
  }
  func finishRecoveredChapter(_ chapter: String) {
    let ids = failedWorkers.filter { $0.value.0.importedChapterId == chapter }.map(\.key)
    for id in ids {
      failedWorkers.removeValue(forKey: id)
      if let index = items.firstIndex(where: { $0.id == id }) {
        items[index].completed = true
        items[index].failed = false
        items[index].status = "Recovered and organized."
      }
    }
  }
  func cancel() {
    epoch = UUID()
    task?.cancel()
    task = nil
    waiting.forEach { $0.1.close() }
    waiting = []
    items = []
    failedWorkers = [:]
    activeChapter = nil
    activeAuthor = nil
  }
}

struct ImportScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View { ImportWorkspace(library: library) }
}
struct ImportWorkspace: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var library: LibraryUIModel
  @StateObject private var model: ImportWorkspaceModel
  @State private var choosing = false
  @State private var dragging = false
  @State private var creating: EditorRequest?
  @State private var alignment = false
  @State private var stacked = false
  @State private var compactActions = false
  @State private var destinationPath = ""
  @State private var previewURL: URL?
  init(library: LibraryUIModel, model: ImportWorkspaceModel? = nil) {
    _model = StateObject(wrappedValue: model ?? ImportWorkspaceModel(library: library))
  }
  var body: some View {
    ImportDropHost(
      enabled: !model.busy, targeted: $dragging,
      receive: { model.append($0) }, failure: { model.status = $0.localizedDescription }
    ) {
      importContent.environmentObject(library).environmentObject(session)
    }
    .onGeometryChange(for: Bool.self) {
      $0.size.width < 650
    } action: {
      compactActions = $0
    }
    .task(id: model.destinationId) {
      let selected = model.destinationId
      let path = selected == nil ? nil : try? await library.local.readingRootURL(selected!)
      guard !Task.isCancelled, selected == model.destinationId else { return }
      destinationPath = path?.path ?? ""
    }
    .fileImporter(
      isPresented: $choosing,
      allowedContentTypes: [.folder, .pdf, .movie, UTType(filenameExtension: "webm") ?? .movie],
      allowsMultipleSelection: true
    ) { result in
      do { model.append(try result.get()) } catch { model.status = error.localizedDescription }
    }
    .sheet(item: $creating) { request in
      MetadataEditor(
        request: request,
        onSave: { created in
          if created.kind == .author {
            model.input.authorId = created.id
          } else if created.kind == .work {
            model.input.workId = created.id
          }
        }
      ).environmentObject(library).environmentObject(session)
    }
    .sheet(isPresented: $alignment) {
      TranslationAlignmentScreen(
        candidate: model.current, original: library.entity(model.translationOf),
        mapping: $model.pageAlignment
      ).environmentObject(library)
    }
    .sheet(isPresented: $model.review) {
      NavigationStack {
        VStack(alignment: .leading, spacing: 22) {
          Label("Archive Comic", systemImage: "folder.badge.gearshape").font(
            .system(size: 23, weight: .semibold))
          Text("Choose a destination and add this import to the background file queue.")
            .foregroundStyle(.secondary)
          Picker("Destination", selection: $model.destinationId) {
            Text("Choose destination").tag(String?.none)
            ForEach(session.entities.filter { $0.isArchiveDestination }) { root in
              Text(root.title).tag(Optional(root.id))
            }
          }.pickerStyle(.menu)
          if model.destinationId == nil {
            Text("Add a destination in Media Storage before archiving.").foregroundStyle(.secondary)
          }
          GroupBox("Source") {
            Text(model.current?.source.path ?? "").frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          Image(systemName: "arrow.down").foregroundStyle(.pink)
          GroupBox("Destination") {
            Text(
              destinationPath + "/" + model.proposedPath
            ).frame(
              maxWidth: .infinity, alignment: .leading
            ).textSelection(.enabled)
          }
          Text(
            "Existing files are never overwritten. Across disks, files are copied and verified before the originals are removed."
          ).font(.caption).foregroundStyle(.secondary)
          if !model.status.isEmpty { Text(model.status).font(.caption) }
          HStack {
            Button("Cancel") { model.review = false }.disabled(model.busy)
            Spacer()
            Button("Commit") {
              model.enqueue(move: true)
            }.buttonStyle(.borderedProminent).disabled(model.destinationId == nil)
          }
        }.padding(28).frame(width: 620)
      }
    }
    .onChange(of: model.input.workId) { _, id in
      if let work = library.entity(id) {
        model.input.authorId = work.authorId
        model.input.seriesId = work.seriesId
      }
    }
    .onChange(of: model.translationOf) { _, _ in
      model.pageAlignment = []
      if model.translationOf != nil { alignment = true }
    }
    .onChange(of: model.isTranslation) { _, enabled in
      if !enabled {
        model.translationOf = nil
        model.pageAlignment = []
      }
    }
    .onChange(of: model.current?.id) { _, _ in previewURL = nil }
    .onDisappear { model.close() }
  }
  private var importContent: some View {
    ZStack {
      if let candidate = model.current {
        VStack(spacing: 0) {
          HStack(alignment: .top, spacing: 0) {
            ScrollView {
              reviewContent(candidate, stacked: stacked)
                .disabled(model.busy)
                .padding(.leading, 28).padding(.trailing, 24).padding(.vertical, 28)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("import-review-scroll")
            .onGeometryChange(for: Bool.self) {
              $0.size.width < 660
            } action: {
              stacked = $0
            }
            Divider()
            folderQueue
          }
          Divider()
          actionBar(candidate)
        }
      } else {
        Button {
          choosing = true
        } label: {
          dropSurface(overlay: false).overlay(alignment: .bottom) {
            if !model.status.isEmpty {
              Label(model.status, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).padding(24)
            } else if !model.result.isEmpty {
              Label(model.result, systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary).padding(24)
            }
          }
        }
        .buttonStyle(.plain).padding(28)
        .accessibilityIdentifier("import-empty-drop")
      }
      if dragging && model.current != nil {
        dropSurface(overlay: true).padding(28)
          .accessibilityElement(children: .combine)
          .allowsHitTesting(false)
          .accessibilityIdentifier("import-drop-overlay")
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.easeInOut(duration: 0.12), value: dragging)
  }
  private func dropSurface(overlay: Bool) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "folder.badge.plus").font(.system(size: 44, weight: .light))
        .foregroundStyle(.pink)
      Text(overlay ? "Drop to Add Files" : "Drop folders, PDFs or videos").font(.title2.bold())
      Text(
        overlay
          ? "Add them to your import queue."
          : "Drop anywhere on this page, or click to choose files."
      )
      .foregroundStyle(.secondary)
      if !overlay {
        Text("Folders become image chapters. Each PDF, WebM or MP4 becomes one chapter.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center).padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      if overlay {
        RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
      } else {
        RoundedRectangle(cornerRadius: 16).fill(dragging ? Color.pink.opacity(0.08) : .clear)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 16).strokeBorder(
        dragging ? Color.pink : Color.secondary.opacity(0.4),
        style: StrokeStyle(lineWidth: dragging ? 2 : 1, dash: [7]))
    }
  }
  private var folderQueue: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Import Queue").font(.headline)
        Spacer(minLength: 0)
        Button("Choose Files", systemImage: "plus") { choosing = true }
          .labelStyle(.iconOnly).buttonStyle(.borderless).help("Add folders or files")
          .disabled(model.busy)
      }.padding(.horizontal, 16).padding(.top, 28)
      Text("\(model.queue.count) pending").font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16)
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
            Button {
              if index != model.index { model.select(index) }
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                FileThumbnail(url: item.pages.first).frame(height: 132)
                  .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                Text("\(index + 1) · " + item.kind.capitalized).font(.caption).foregroundStyle(
                  .secondary)
              }.padding(8)
                .background(
                  index == model.index ? Color.pink.opacity(0.1) : .clear,
                  in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 10).strokeBorder(
                    index == model.index ? Color.pink.opacity(0.7) : .clear, lineWidth: 1)
                }
            }.buttonStyle(.plain).disabled(model.busy)
              .accessibilityLabel("Review " + item.title)
              .accessibilityAddTraits(index == model.index ? [.isSelected] : [])
              .accessibilityIdentifier("import-queue-\(index)")
          }
        }.padding(.horizontal, 12).padding(.bottom, 16)
      }
    }.frame(width: 174).frame(maxHeight: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("import-folder-queue")
  }
  private func actionBar(_ candidate: ImportCandidate) -> some View {
    let layout =
      compactActions
      ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 10))
      : AnyLayout(HStackLayout(spacing: 12))
    return VStack(alignment: .leading, spacing: 10) {
      if !model.status.isEmpty {
        Label(model.status, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
          .lineLimit(2)
      }
      layout {
        HStack {
          Button("Skip for Now") { model.select((model.index + 1) % model.queue.count) }
            .disabled(model.busy)
          Spacer(minLength: 8)
          Button("Add without Moving") { model.enqueue(move: false) }
            .disabled(model.busy || !model.canSubmit)
        }.frame(maxWidth: .infinity)
        Button("Add to Library & Move Files") {
          model.defaultDestination()
          model.review = true
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(model.busy || !model.canSubmit || !candidate.warnings.isEmpty)
      }
    }.padding(.horizontal, 28).padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading).background(.bar)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("import-action-bar")
  }
  private func reviewContent(_ candidate: ImportCandidate, stacked: Bool = false) -> some View {
    let layout =
      stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 30))
    let selected =
      previewURL.flatMap { candidate.pages.contains($0) ? $0 : nil } ?? candidate.pages.first
    return layout {
      VStack(alignment: .leading, spacing: 16) {
        FileThumbnail(
          url: selected,
          symbol: candidate.kind == "video" ? "play.rectangle" : "book.closed", contentMode: .fit
        ).frame(height: 350).clipShape(RoundedRectangle(cornerRadius: 12))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Selected page preview")
          .accessibilityValue(selected?.lastPathComponent ?? "")
          .accessibilityIdentifier("import-large-preview")
        Text(candidate.source.lastPathComponent).font(.headline).lineLimit(2)
        Text("\(candidate.pages.count) media files · naturally sorted").font(.caption)
          .foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: true) {
          LazyHStack(spacing: 8) {
            ForEach(Array(candidate.pages.enumerated()), id: \.element) { index, url in
              Button {
                previewURL = url
              } label: {
                FileThumbnail(url: url).frame(width: 55, height: 74)
                  .clipShape(RoundedRectangle(cornerRadius: 5))
                  .overlay {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(
                      selected == url ? Color.pink : .clear, lineWidth: 2)
                  }
              }.buttonStyle(.plain)
                .accessibilityLabel("Preview page \(index + 1)")
                .accessibilityAddTraits(selected == url ? [.isSelected] : [])
                .accessibilityIdentifier("import-preview-page-\(index)")
            }
          }.padding(.bottom, 6)
        }.frame(height: 86).accessibilityElement(children: .contain)
          .accessibilityIdentifier("import-page-strip")
        Divider()
        Label("After organization", systemImage: "folder").font(.headline)
        Text(model.proposedPath).font(.system(.caption, design: .monospaced)).foregroundStyle(
          .secondary
        ).textSelection(.enabled)
      }.frame(width: stacked ? nil : 260).frame(maxWidth: stacked ? 300 : nil)
      VStack(alignment: .leading, spacing: 18) {
        Text("Chapter \(model.index + 1) of \(model.queue.count)").font(.title2.bold())
        Toggle("Add as a media translation", isOn: $model.isTranslation)
        if model.isTranslation {
          field("Original Chapter") {
            EntitySearchField(
              label: "Search original chapter", kind: .chapter, selected: $model.translationOf)
            if model.translationOf != nil {
              Button("Align Page Order…", systemImage: "square.split.2x1") { alignment = true }
            }
          }
        } else {
          field("Chapter Name") {
            TextField("Chapter name", text: $model.input.title).textFieldStyle(.roundedBorder)
              .fullFieldFocus()
          }
          field("Author") {
            EntitySearchField(
              label: "Search existing authors", kind: .author, selected: $model.input.authorId,
              create: { creating = .init(kind: .author, initialTitle: $0) })
          }
          field("Comic (optional)") {
            EntitySearchField(
              label: "Search or create a comic", kind: .work, selected: $model.input.workId,
              create: { creating = .init(kind: .work, initialTitle: $0) })
          }
        }
        Picker("Media language", selection: $model.input.originalLanguage) {
          ForEach(mediaLanguages, id: \.code) { Text($0.name).tag($0.code) }
        }
        field("Chapter Description") {
          TextEditor(text: $model.input.description).scrollContentBackground(.hidden)
            .fullFieldFocus().frame(
              height: 95
            ).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        if !model.isTranslation {
          field("Tags") { TagTokenPicker(selected: $model.input.tagIds) }
          Toggle("NSFW · hide by default", isOn: $model.input.nsfw)
          field("Source IDs") {
            VStack(spacing: 10) {
              ForEach(["pixiv", "fanbox", "ehentai"], id: \.self) { site in
                TextField(site.capitalized, text: source(site)).fullFieldFocus().textFieldStyle(
                  .roundedBorder)
              }
            }
          }
        }
      }.frame(maxWidth: .infinity)
    }
  }
  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.subheadline.weight(.medium))
      content()
    }
  }
  private func source(_ site: String) -> Binding<String> {
    Binding(
      get: { model.input.sources.first { $0.site == site }?.value ?? "" },
      set: { value in
        model.input.sources.removeAll { $0.site == site }
        if !value.isEmpty { model.input.sources.append(.init(site: site, value: value)) }
      })
  }
}
struct TranslationAlignmentScreen: View {
  var candidate: ImportCandidate?
  var original: LibraryEntity?
  @Binding var mapping: [Int?]
  @EnvironmentObject private var library: LibraryUIModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: [Int?] = []
  private var importedCount: Int {
    guard let candidate else { return 0 }
    return candidate.kind == "pdf"
      ? PDFDocument(url: candidate.source)?.pageCount ?? 0 : candidate.pages.count
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        SheetHeading("Align Translation", inset: 24)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            Text(
              "Match each original page with its translated page. Unmatched pages use the original. Extra import pages stay in the source; only matched pages enter the reading order."
            ).foregroundStyle(.secondary)
            if let original, let media = original.media.first, let candidate {
              ForEach(draft.indices, id: \.self) { index in
                HStack(spacing: 24) {
                  MediaPagePreview(media: media, index: index).frame(width: 115, height: 155)
                  VStack(alignment: .leading, spacing: 10) {
                    Text("Original page \(index + 1)").font(.headline)
                    Picker(
                      "Translation",
                      selection: Binding(
                        get: { draft[index] ?? -1 }, set: { draft[index] = $0 < 0 ? nil : $0 })
                    ) {
                      Text("Use original").tag(-1)
                      ForEach(0..<importedCount, id: \.self) {
                        Text("Imported page \($0 + 1)").tag($0)
                      }
                    }
                  }.frame(maxWidth: .infinity)
                  if let page = draft[index] {
                    PagePreview(
                      url: candidate.kind == "images"
                        ? candidate.pages[page] : candidate.pages.first,
                      kind: candidate.kind, index: page
                    ).frame(width: 115, height: 155)
                  } else {
                    Label("Original", systemImage: "arrow.uturn.backward").frame(
                      width: 115, height: 155
                    ).foregroundStyle(.secondary)
                  }
                }
                Divider()
              }
            }
          }.padding(24)
        }
      }.navigationTitle("")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Use Alignment") {
              mapping = draft
              dismiss()
            }.buttonStyle(.borderedProminent)
          }
        }
    }.frame(width: 650, height: 650)
      .onAppear {
        draft =
          mapping.isEmpty
          ? (0..<(original?.media.first?.pageCount ?? 0)).map { $0 < importedCount ? $0 : nil }
          : mapping
      }
  }
}
