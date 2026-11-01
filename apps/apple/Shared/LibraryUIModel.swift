import Combine
import Foundation
import MangaCore
import SwiftUI

enum LibraryPage: String, CaseIterable, Identifiable, Hashable {
  case search, library, continuing, favorites, starred, savedPages, authors, series, tags
  case history, statistics, downloads, importing, organization, storage
  case settings, reading, translation, imageTranslation, connections, sync, files
  case unorganized, fileManagement, translationQueue, commitHistory
  var id: String { rawValue }
  var hasCollectionFilters: Bool {
    [.search, .library, .continuing, .favorites, .starred, .savedPages,
     .authors, .series, .history, .downloads].contains(self)
  }
  var title: String {
    switch self {
    case .search: "Search"
    case .library: "All Comics"
    case .continuing: "Continue Reading"
    case .favorites: "Favorites"
    case .starred: "Starred"
    case .savedPages: "Saved Pages"
    case .authors: "Authors"
    case .series: "Series"
    case .tags: "Tags"
    case .history: "History"
    case .statistics: "Statistics"
    case .downloads: "Downloads"
    case .importing: "Import & Identify"
    case .organization: "Pending Organization"
    case .unorganized: "Not Yet Organized"
    case .fileManagement: "File Management Queue"
    case .translationQueue: "Translation Queue"
    case .commitHistory: "Commit History"
    case .imageTranslation: "Manga Image Translation"
    case .storage: "Storage Locations"
    case .settings: "General"
    case .reading: "Reading & Language"
    case .translation: "Ollama Translation"
    case .connections: "Connections"
    case .sync: "Sync & Account"
    case .files: "Files & Backup"
    }
  }
  var symbol: String {
    switch self {
    case .search: "magnifyingglass"
    case .library: "square.grid.2x2"
    case .continuing: "book"
    case .favorites: "heart"
    case .starred: "star"
    case .savedPages: "photo.on.rectangle"
    case .authors: "person.crop.circle"
    case .series: "square.stack"
    case .tags: "tag"
    case .history: "clock"
    case .statistics: "chart.bar"
    case .downloads: "arrow.down.circle"
    case .importing: "folder.badge.plus"
    case .organization: "folder.badge.gearshape"
    case .unorganized: "folder.badge.questionmark"
    case .fileManagement: "list.bullet.rectangle"
    case .translationQueue: "character.bubble"
    case .commitHistory: "clock.arrow.circlepath"
    case .imageTranslation: "photo.badge.checkmark"
    case .storage: "externaldrive"
    case .settings: "gearshape"
    case .reading: "text.book.closed"
    case .translation: "character.bubble"
    case .connections: "network"
    case .sync: "arrow.triangle.2.circlepath"
    case .files: "archivebox"
    }
  }
  static let libraryPages: [Self] = [
    .library, .continuing, .favorites, .starred, .savedPages, .authors, .series, .tags,
  ]
  static let organizationPages: [Self] = [.unorganized, .fileManagement, .translationQueue, .commitHistory]
  static let activityPages: [Self] = [.history, .statistics, .downloads]
  static var settingsPages: [Self] {
    #if os(macOS)
      [.settings, .reading, .translation, .imageTranslation, .connections, .sync, .files]
    #else
      [.settings, .reading, .translation, .connections, .sync, .files]
    #endif
  }
}
enum LibraryRoute: Hashable {
  case page(LibraryPage)
  case entity(String)
  case pages(String)
}
enum LibrarySort: String, CaseIterable {
  case updated = "Update Time"
  case title = "Title"
  case author = "Author"
  case read = "Last Read"
}
struct UIMessage: Identifiable {
  let id = UUID()
  var text: String
}
struct EditorRequest: Identifiable {
  var entity: LibraryEntity?
  var kind: EntityKind
  var initialTitle = ""
  var id: String { entity?.id ?? "new-" + kind.rawValue }
}
struct ReadingContext: Identifiable {
  var chapter: LibraryEntity
  var version: MediaVersion
  var urls: [URL]
  var page: Int
  var id: String { chapter.id }
}
struct DownloadActivity: Identifiable {
  let id: String
  var title: String
  var detail: String
  var completed = false
  var failed = false
  var progress = 0.0
}

@MainActor final class LibraryUIModel: ObservableObject {
  let session: AppSession
  let local: LocalMedia
  let smb: SMBMedia
  @Published var selection: LibraryPage? = .library
  @Published var path: [LibraryRoute] = []
  @Published var forwardPath: [LibraryRoute] = []
  private var restoringForward = false
  private struct MediaRequest {
    let id = UUID()
    let task: Task<URL, Error>
    var waiters: Set<UUID>
  }
  private var mediaRequests: [String: MediaRequest] = [:]
  private let coverPermits = AsyncPermitPool(limit: 2)
  private var availabilityUpdate: Task<Void, Never>?
  #if os(macOS)
    lazy var pendingJournalIndex = PendingFileJournalIndex()
    lazy var fileQueue = ImportFileQueue(library: self)
    lazy var translationQueue = MangaTranslationQueue(library: self)
    @Published var organizingChapterIds = Set<String>()
  #endif
  @Published var query = ""
  @Published var sort: LibrarySort = .updated {
    didSet {
      if sort != oldValue { sortAscending = sort == .title || sort == .author }
    }
  }
  @Published var sortAscending = false
  @Published var unreadOnly = false
  @Published var selectedTag: String?
  @Published var editor: EditorRequest?
  @Published var reader: ReadingContext?
  @Published var message: UIMessage?
  @Published var deletionRequest: LibraryEntity?
  @Published var deletingComic = false
  private var deletionTask: Task<Void, Never>?
  private var deletionEpoch = UUID()
  @Published var activities: [DownloadActivity] = []
  @Published var opening = false
  @Published var revision = 0
  private var downloadTask: Task<Void, Never>?
  private var downloadEpoch = UUID()
  private var downloadQueue: [String] = []
  private var activeDownload: String?
  private var stateTask: Task<Void, Never>?
  private var stateDelayTask: Task<Void, Never>?
  private var nextStateAttempt = Date.distantPast
  private var urgentStateKeys = Set<String>()
  private var progressOnlyKeys = Set<String>()
  private var pendingStateFields: [String: Set<String>] = [:]
  private var desiredStateFields: [String: Set<String>] = [:]
  private let stateOutbox = ReadingStateOutbox()
  private var outboxSequence: UInt64 = 0
  private var pendingStates: [String: StateInput] = [:]
  @Published private var desiredStates: [String: StateInput] = [:]
  private var stateEpoch = UUID()
  init(session: AppSession) {
    self.session = session
    local = LocalMedia(session: session)
    smb = SMBMedia(session: session)
    session.flushReadingState = { [weak self] in self?.flushStates() }
    session.persistReadingState = { [weak self] in await self?.persistStatesNow() }
    smb.availabilityChanged = { [weak self] in
      guard let self, self.availabilityUpdate == nil else { return }
      self.availabilityUpdate = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(120))
        guard let self, !Task.isCancelled else { return }
        self.availabilityUpdate = nil
        self.revision += 1
      }
    }

  }
  var canManage: Bool {
    #if os(macOS)
      return session.account?.scopes.contains("manga:manage") == true
    #else
      return false
    #endif
  }
  func reset() {
    availabilityUpdate?.cancel()
    availabilityUpdate = nil
    mediaRequests.values.forEach { $0.task.cancel() }
    mediaRequests = [:]
    smb.resetAvailability()
    #if os(macOS)
      fileQueue.cancel()
      translationQueue.reset()
      organizingChapterIds.removeAll()
    #endif
    deletionEpoch = UUID()
    deletionTask?.cancel()
    deletionTask = nil
    deletionRequest = nil
    deletingComic = false
    downloadEpoch = UUID()
    downloadTask?.cancel()
    downloadTask = nil
    downloadQueue = []
    activeDownload = nil
    stateEpoch = UUID()
    stateTask?.cancel()
    stateTask = nil
    stateDelayTask?.cancel(); stateDelayTask = nil
    urgentStateKeys = []; progressOnlyKeys = []; nextStateAttempt = .distantPast
    pendingStateFields = [:]; desiredStateFields = [:]
    pendingStates = [:]
    desiredStates = [:]
    reader = nil
    editor = nil
    message = nil
    path = []
    forwardPath = []
    restoringForward = true
    query = ""
    selectedTag = nil
    activities = []
    opening = false
    selection = .library
    local.release()
  }
  func clearNavigation() {
    restoringForward = true
    path = []
    forwardPath = []
  }
  func navigationChanged(from old: [LibraryRoute], to new: [LibraryRoute]) {
    if restoringForward {
      restoringForward = false
      return
    }
    if new.count < old.count && Array(old.prefix(new.count)) == new {
      forwardPath = Array(old.dropFirst(new.count).reversed())
    } else {
      forwardPath = []
    }
  }
  func navigateBack() { if !path.isEmpty { withAnimation { _ = path.removeLast() } } }
  func navigateForward() {
    guard let route = forwardPath.popLast() else { return }
    restoringForward = true
    withAnimation { path.append(route) }
  }
  func show(_ error: Error) { message = UIMessage(text: error.localizedDescription) }
  func entity(_ id: String?) -> LibraryEntity? {
    session.catalog.entity(id, showNSFW: AppConfiguration.showNSFW)
  }
  func title(_ entity: LibraryEntity) -> String {
    entity.kind == .author ? entity.title : entity.title(in: AppConfiguration.preferredLanguage)
  }
  func author(for item: LibraryEntity) -> LibraryEntity? {
    guard let current = entity(item.id) else { return nil }
    if current.kind == .author { return entity(current.id) }
    let work = entity(current.workId)
    let series = entity(current.seriesId ?? work?.seriesId)
    return [current.authorId, work?.authorId, series?.authorId]
      .compactMap { entity($0) }.first { $0.kind == .author }
  }
  func chapters(_ entity: LibraryEntity) -> [LibraryEntity] { smb.chapters(for: entity) }
  func children(_ parent: LibraryEntity) -> [LibraryEntity] {
    let visible = session.visibleEntities()
    switch parent.kind {
    case .author:
      return visible.filter {
        $0.authorId == parent.id
          && ($0.kind == .series || ($0.kind == .work && $0.seriesId == nil)
            || ($0.kind == .chapter && $0.workId == nil && $0.seriesId == nil))
      }
    case .series:
      return visible.filter {
        $0.seriesId == parent.id && ($0.kind == .work || ($0.kind == .chapter && $0.workId == nil))
      }
    case .work: return visible.filter { $0.kind == .chapter && $0.workId == parent.id }
    case .tag: return taggedComics(parent)
    default: return []
    }
  }
  func authorPreviews(_ author: LibraryEntity) -> [LibraryEntity] {
    session.visibleEntities().filter {
      $0.authorId == author.id && ($0.kind == .work || ($0.kind == .chapter && $0.workId == nil))
    }
  }
  func taggedComics(_ tag: LibraryEntity) -> [LibraryEntity] {
    session.visibleEntities().filter { entity in
      guard entity.kind == .work || (entity.kind == .chapter && entity.workId == nil) else {
        return false
      }
      return effectiveTags(entity).contains(tag.id)
        || chapters(entity).contains { effectiveTags($0).contains(tag.id) }
    }
  }
  func effectiveTags(_ entity: LibraryEntity) -> Set<String> {
    var result = Set(entity.tagIds)
    for id in [entity.authorId, entity.seriesId, entity.workId].compactMap({ $0 }) {
      if let parent = self.entity(id) { result.formUnion(parent.tagIds) }
    }
    if let seriesId = self.entity(entity.workId)?.seriesId, let series = self.entity(seriesId) {
      result.formUnion(series.tagIds)
    }
    return result
  }
  func state(_ id: String, page: Int? = nil) -> PersonalState? {
    session.personalState(id, page: page)
  }
  var latestChapter: LibraryEntity? {
    session.states.filter {
      $0.pageIndex == nil && $0.progress != nil && $0.progress?.completed != true
    }
    .sorted { $0.updatedAt > $1.updatedAt }.compactMap { entity($0.entityId) }.first
  }
  func collection(_ page: LibraryPage) -> [LibraryEntity] {
    let visible = session.visibleEntities()
    let marks = session.states.filter { $0.pageIndex == nil }
    switch page {
    case .authors: return filtered(visible.filter { $0.kind == .author })
    case .series: return filtered(visible.filter { $0.kind == .series })
    case .tags: return filtered(session.entities.filter { $0.kind == .tag && !$0.deleted })
    case .favorites, .starred:
      let ids = Set(marks.filter { page == .favorites ? $0.favorite : $0.starred }.map(\.entityId))
      return filtered(visible.filter { ids.contains($0.id) })
    case .history, .continuing:
      let ids = Set(
        marks.filter { $0.progress != nil && (page == .history || $0.progress?.completed != true) }
          .map(\.entityId))
      return filtered(visible.filter { $0.kind == .chapter && ids.contains($0.id) }, lastRead: true)
    case .downloads:
      return filtered(
        visible.filter {
          $0.kind == .chapter && $0.media.contains { smb.isDownloaded($0) }
        })
    default:
      return filtered(
        visible.filter { $0.kind == .work || ($0.kind == .chapter && $0.workId == nil) })
    }
  }
  func savedPages() -> [PersonalState] {
    let bookmarks = session.states.filter {
      $0.pageIndex != nil && ($0.favorite || $0.starred) && entity($0.entityId) != nil
    }
    let chapters = Set(bookmarks.map(\.entityId)).compactMap { entity($0) }.sorted { $0.id < $1.id }
    let ranks = Dictionary(uniqueKeysWithValues: filtered(chapters).enumerated().map {
      ($0.element.id, $0.offset)
    })
    return bookmarks.filter { ranks[$0.entityId] != nil }.sorted {
      if sort == .updated && $0.updatedAt != $1.updatedAt {
        return sortAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt
      }
      let a = ranks[$0.entityId]!, b = ranks[$1.entityId]!
      if a != b { return a < b }
      return ($0.pageIndex ?? 0) < ($1.pageIndex ?? 0)
    }
  }
  func filtered(_ entities: [LibraryEntity], lastRead: Bool = false) -> [LibraryEntity] {
    let rows = entities.filter { e in
      (!unreadOnly || state(e.id)?.progress?.completed != true)
        && (selectedTag == nil || effectiveTags(e).contains(selectedTag!))
        && (query.isEmpty
          || [title(e), e.description, entity(e.authorId).map(title) ?? ""].joined(separator: " ")
            .localizedCaseInsensitiveContains(query))
    }
    // Resolve display values once per row, rather than during every comparison.
    let titles = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, title($0)) })
    let authors = sort == .author
      ? Dictionary(uniqueKeysWithValues: rows.map { ($0.id, author(for: $0).map(title) ?? "other author") })
      : [:]
    return rows.sorted { a, b in
      var order: ComparisonResult
      if lastRead || sort == .read {
        order = (state(a.id)?.updatedAt ?? "").compare(state(b.id)?.updatedAt ?? "")
      } else {
        switch sort {
        case .updated: order = a.updatedAt.compare(b.updatedAt)
        case .title: order = titles[a.id]!.localizedStandardCompare(titles[b.id]!)
        case .author: order = authors[a.id]!.localizedStandardCompare(authors[b.id]!)
        case .read: order = .orderedSame
        }
      }
      if order == .orderedSame {
        order = titles[a.id]!.localizedStandardCompare(titles[b.id]!)
      }
      if order == .orderedSame { order = a.id.compare(b.id) }
      return order == ((lastRead || !sortAscending) ? .orderedDescending : .orderedAscending)
    }
  }
  // Diagnostic full-chapter check; visible views use mediaURL/coverURL instead.
  func cachedURLs(_ version: MediaVersion) -> [URL]? {
    #if os(macOS)
      if let urls = try? local.urls(for: version),
        urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
      {
        return urls
      }
    #endif
    return smb.downloadedURLs(version)
  }
  func coverKey(_ entity: LibraryEntity) -> String {
    let chapter = entity.kind == .chapter ? entity : chapters(entity).first
    return (session.account?.ownerId ?? "") + entity.id + String(entity.revision)
      + (chapter.map { $0.id + String($0.revision) } ?? "") + AppConfiguration.preferredLanguage
  }
  func pageMedia(_ chapter: LibraryEntity, preferred: MediaVersion? = nil, page: Int) -> (
    media: MediaVersion, index: Int
  )? {
    guard let selected = preferred ?? chapter.preferredMedia(AppConfiguration.preferredLanguage)
    else { return nil }
    let original =
      chapter.media.first { $0.language == chapter.originalLanguage } ?? chapter.media.first
      ?? selected
    let media = selected.sourcePage(at: page) == nil ? original : selected
    guard let index = media.sourcePage(at: page) else { return nil }
    return (media, index)
  }
  func coverURL(_ entity: LibraryEntity) async -> URL? {
    do {
      try await coverPermits.acquire()
      do {
        try Task.checkCancellation()
        let chapter = entity.kind == .chapter ? entity : chapters(entity).first
        guard let version = chapter?.preferredMedia(AppConfiguration.preferredLanguage) else {
          await coverPermits.release()
          return nil
        }
        let index = try await FileTasks.perform {
          version.relativePaths.indices.min {
            (version.relativePaths[$0] as NSString).lastPathComponent.localizedStandardCompare(
              (version.relativePaths[$1] as NSString).lastPathComponent) == .orderedAscending
          }
        }
        var url: URL?
        if let index { url = try await mediaURL(version, index: index) }
        await coverPermits.release()
        return url
      } catch {
        await coverPermits.release()
        throw error
      }
    } catch { return nil }
  }
  private func releaseMediaWaiter(_ waiter: UUID, key: String, requestID: UUID) {
    guard var request = mediaRequests[key], request.id == requestID else { return }
    request.waiters.remove(waiter)
    if request.waiters.isEmpty {
      request.task.cancel()
      mediaRequests.removeValue(forKey: key)
    } else {
      mediaRequests[key] = request
    }
  }
  func mediaURL(_ media: MediaVersion, index: Int) async throws -> URL {
    try Task.checkCancellation()
    guard let owner = session.account?.ownerId else { throw LoginError.invalidToken }
    let key =
      owner + media.id + media.storageRootId + media.relativePaths.joined(separator: "\0")
      + String(index)
    let waiter = UUID()
    let request: MediaRequest
    if var existing = mediaRequests[key] {
      existing.waiters.insert(waiter)
      mediaRequests[key] = existing
      request = existing
    } else {
      let task = Task<URL, Error> {
        try Task.checkCancellation()
        if let cached = try await smb.cachedPage(media, index: index) { return cached }
        #if os(macOS)
          do { return try await local.url(for: media, file: index) } catch let error
            as DestinationIdentityError
          { throw error } catch { try Task.checkCancellation() }
        #endif
        guard let url = try await smb.download(media, indices: [index]).first else {
          throw StorageError.emptyChapter
        }
        return url
      }
      request = MediaRequest(task: task, waiters: [waiter])
      mediaRequests[key] = request
    }
    defer { releaseMediaWaiter(waiter, key: key, requestID: request.id) }
    let url = try await withTaskCancellationHandler {
      try await request.task.value
    } onCancel: {
      Task { @MainActor in self.releaseMediaWaiter(waiter, key: key, requestID: request.id) }
    }
    try Task.checkCancellation()
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    return url
  }
  func open(_ chapter: LibraryEntity, page: Int? = nil, mediaId: String? = nil) {
    guard !opening else { return }
    opening = true
    let owner = session.account?.ownerId
    Task {
      defer { opening = false }
      do {
        guard let current = entity(chapter.id),
          let version = current.media.first(where: { $0.id == mediaId })
            ?? current.preferredMedia(AppConfiguration.preferredLanguage),
          version.pageCount > 0
        else { throw StorageError.emptyChapter }
        // File reads happen in the visible page's task, never before opening the reader.
        let urls: [URL] = []
        guard owner == session.account?.ownerId, entity(chapter.id) != nil else { return }
        reader = ReadingContext(
          chapter: current, version: version, urls: urls,
          page: min(
            max(0, page ?? state(chapter.id)?.progress?.pageIndex ?? 0),
            max(version.pageCount, version.pageAlignment?.count ?? 0) - 1))
      } catch { if owner == session.account?.ownerId { show(error) } }
    }
  }
  var activeDownloadCount: Int { activities.filter { !$0.completed && !$0.failed }.count }
  func downloadActivity(_ id: String) -> DownloadActivity? { activities.first { $0.id == id } }
  func isDownloaded(_ entity: LibraryEntity) -> Bool {
    let versions = chapters(entity).compactMap {
      $0.preferredMedia(AppConfiguration.preferredLanguage)
    }
    return !versions.isEmpty && versions.allSatisfy { smb.isDownloaded($0) }
  }
  func download(_ entity: LibraryEntity) {
    guard !activities.contains(where: { $0.id == entity.id && !$0.completed && !$0.failed }) else {
      return
    }
    activities.removeAll { $0.id == entity.id }
    activities.append(.init(id: entity.id, title: title(entity), detail: "Queued"))
    downloadQueue.append(entity.id)
    startNextDownload()
  }
  private func startNextDownload() {
    guard downloadTask == nil, !downloadQueue.isEmpty else { return }
    let id = downloadQueue.removeFirst()
    guard let current = entity(id) else {
      activities.removeAll { $0.id == id }
      startNextDownload()
      return
    }
    activeDownload = id
    let owner = session.account?.ownerId
    let epoch = downloadEpoch
    downloadTask = Task {
      defer {
        if downloadEpoch == epoch {
          downloadTask = nil
          activeDownload = nil
          startNextDownload()
        }
      }
      do {
        let versions = chapters(current).compactMap {
          $0.preferredMedia(AppConfiguration.preferredLanguage)
        }
        guard !versions.isEmpty else { throw StorageError.emptyChapter }
        for (position, version) in versions.enumerated() {
          try Task.checkCancellation()
          guard owner == session.account?.ownerId, entity(id) != nil else {
            throw LoginError.invalidToken
          }
          let available: [URL]?
          do { available = try await local.availableURLs(for: version) } catch let error
            as DestinationIdentityError
          { throw error } catch { available = nil }
          _ = try await smb.download(version, localURLs: available) { [self] value, detail in
            guard self.downloadEpoch == epoch,
              let index = self.activities.firstIndex(where: {
                $0.id == id && !$0.completed && !$0.failed
              })
            else { return }
            self.activities[index].progress = min(
              1,
              max(
                self.activities[index].progress, (Double(position) + value) / Double(versions.count)
              ))
            self.activities[index].detail = detail
          }
        }
        guard owner == session.account?.ownerId, downloadEpoch == epoch else { return }
        if let index = activities.firstIndex(where: { $0.id == id }) {
          activities[index].completed = true
          activities[index].progress = 1
          activities[index].detail = "Available offline"
        }
        revision += 1
      } catch {
        guard owner == session.account?.ownerId, downloadEpoch == epoch else { return }
        if let index = activities.firstIndex(where: { $0.id == id }) {
          activities[index].failed = true
          activities[index].detail =
            error is CancellationError ? "Download cancelled" : error.localizedDescription
        }
      }
    }
  }
  func cancelDownload(_ id: String) {
    if activeDownload == id {
      downloadTask?.cancel()
    } else {
      downloadQueue.removeAll { $0 == id }
      if let index = activities.firstIndex(where: { $0.id == id }) {
        activities[index].failed = true
        activities[index].detail = "Download cancelled"
      }
    }
  }
  func cancelDownload() { if let activeDownload { cancelDownload(activeDownload) } }
  func removeDownload(_ entity: LibraryEntity) {
    do {
      for version in entity.media { try smb.deleteDownload(version) }
      revision += 1
    } catch { show(error) }
  }
  func requestDeletion(_ entity: LibraryEntity) {
    guard canManage, !deletingComic, [.work, .chapter, .author].contains(entity.kind) else {
      return
    }
    #if os(macOS)
      if (entity.kind == .author && fileQueue.managesAuthor(entity.id))
        || chapters(entity).contains(where: { fileQueue.manages($0.id) || organizingChapterIds.contains($0.id) })
      {
        show(
          LoginError.server(
            "This chapter is being organized. Wait for its file queue task to finish before deleting it."
          ))
        return
      }
    #endif
    deletionRequest = entity
  }
  func confirmDeletion() {
    guard let entity = deletionRequest, !deletingComic else { return }
    deletionRequest = nil
    #if os(macOS)
      if (entity.kind == .author && fileQueue.managesAuthor(entity.id))
        || chapters(entity).contains(where: { fileQueue.manages($0.id) || organizingChapterIds.contains($0.id) }) {
        show(
          LoginError.server(
            "This author has an active import. Wait for it to finish before deleting the author."))
        return
      }
    #endif
    deletingComic = true
    let epoch = deletionEpoch
    deletionTask = Task {
      defer {
        if deletionEpoch == epoch {
          deletingComic = false
          deletionTask = nil
        }
      }
      do {
        if entity.kind == .author {
          try await session.deleteAuthor(entity)
        } else {
          try await deleteComic(entity)
        }
        if entity.kind == .author {
          path.removeAll { $0 == .entity(entity.id) }
          forwardPath = []
        }
      } catch { if deletionEpoch == epoch { show(error) } }
    }
  }
  func deleteComic(_ entity: LibraryEntity) async throws {
    guard canManage, let owner = session.account?.ownerId else { throw LoginError.invalidToken }
    let records = ComicDeletionPlan.entities(for: entity, in: session.entities)
    guard !records.isEmpty else { return }
    let ids = Set(records.map(\.id))
    for activity in activities where !activity.completed && !activity.failed {
      if ids.contains(activity.id)
        || self.entity(activity.id).map({ !ids.isDisjoint(with: chapters($0).map(\.id)) }) == true
      {
        cancelDownload(activity.id)
      }
    }

    // Preflight every chapter before changing metadata or moving any files.
    for record in records { _ = try await local.archiveFiles(for: record, deleting: ids) }
    guard let journals = session.cacheDirectory?.appendingPathComponent("delete-journals") else {
      throw LoginError.invalidToken
    }
    for record in records {
      try Task.checkCancellation()
      let files = try await local.archiveFiles(for: record, deleting: [record.id])
      let cleanupRoots = try await local.referenceRoots(for: record.media)
      let cleanup = EmptyMediaFolder.plan(media: record.media, roots: cleanupRoots, chapterTitle: record.title)
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      cancelDownload(record.id)
      pendingStates = pendingStates.filter { $0.value.entityId != record.id }
      desiredStates = desiredStates.filter { $0.value.entityId != record.id }
      let leased = files.map(\.root).filter { $0.startAccessingSecurityScopedResource() }
      defer { leased.forEach { $0.stopAccessingSecurityScopedResource() } }
      var journal: RecycleJournal?
      if !files.isEmpty {
        journal = try await FileTasks.perform {
          try FileRecycle.begin(
            entityId: record.id, revision: record.revision, files: files, journalDirectory: journals,
            cleanupFolders: cleanup
          )
        }
      }
      do {
        try Task.checkCancellation()
        guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
        try await session.delete(record)
      } catch {
        var deletionConfirmed = false
        let status = (error as? APIError)?.status ?? 0
        let uncertainResponse =
          status == 404 || status >= 500 || (error as NSError).domain == NSURLErrorDomain
        if uncertainResponse, owner == session.account?.ownerId {
          do {
            try await session.synchronize()
            guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
            deletionConfirmed = !session.entities.contains { $0.id == record.id && !$0.deleted }
          } catch {
            // The server may have committed before its response failed. Keep
            // the files in Recycle until the result can be reviewed.
            if journal != nil {
              throw LoginError.server(
                "Deletion could not be confirmed. Files remain in Recycle; review Pending Organization after reconnecting."
              )
            }
            throw error
          }
        }
        if !deletionConfirmed {
          if let journal {
            // Restoration is deliberate cleanup even after cancellation/sign-out.
            do {
              try await Task.detached { try FileRecycle.rollback(journal, in: journals) }.value
            } catch { throw StorageError.recycleRecoveryRequired }
          }
          throw error
        }
      }
      if let journal {
        try await FileTasks.perform { try FileRecycle.finish(journal, in: journals) }
      }
      guard owner == session.account?.ownerId else { return }
      // Offline copies are retained; deletion must not purge a surviving copy
      // when an original archive file is already missing.
    }
    guard owner == session.account?.ownerId else { return }
    if let index = path.firstIndex(where: { route in
      switch route {
      case .entity(let id), .pages(let id): return ids.contains(id)
      case .page: return false
      }
    }) {
      path = Array(path.prefix(index))
      forwardPath = []
    }
    revision += 1
  }
  func mark(_ entity: LibraryEntity, starred: Bool, page: Int? = nil) {
    let old = stateInput(entity.id, page: page)
    writeState(
      .init(
        entityId: entity.id, pageIndex: page,
        favorite: starred ? old?.favorite ?? false : !(old?.favorite ?? false),
        starred: starred ? !(old?.starred ?? false) : old?.starred ?? false, progress: old?.progress
      ), immediate: true, fields: [starred ? "starred" : "favorite"])
  }
  func stateInput(_ id: String, page: Int? = nil) -> StateInput? {
    if let desired = desiredStates[id + ":" + (page.map(String.init) ?? "chapter")] {
      return desired
    }
    guard let saved = state(id, page: page) else { return nil }
    return .init(
      entityId: id, pageIndex: page, favorite: saved.favorite, starred: saved.starred,
      progress: saved.progress)
  }
  private func persistStates() {
    guard let directory = session.cacheDirectory else { return }
    outboxSequence &+= 1
    let sequence = outboxSequence
    let values = desiredStates
    let progress = progressOnlyKeys
    let fields = desiredStateFields
    Task { do { try await stateOutbox.save(values, progress: progress, fields: fields, directory: directory, sequence: sequence) }
      catch { show(error) } }
  }
  func persistStatesNow() async {
    guard let directory = session.cacheDirectory else { return }
    outboxSequence &+= 1
    do { try await stateOutbox.save(desiredStates, progress: progressOnlyKeys, fields: desiredStateFields, directory: directory, sequence: outboxSequence) }
    catch { show(error) }
  }
  func restoreStateOutbox() async {
    guard let owner = session.account?.ownerId, let directory = session.cacheDirectory else { return }
    do {
      let entries = try await stateOutbox.load(directory: directory)
      guard session.account?.ownerId == owner else { return }
      for entry in entries { writeState(entry.input, immediate: false, progressOnly: entry.progressOnly, fields: entry.fields.map(Set.init)) }
    } catch { show(error) }
  }
  func flushStates() {
    if Date() >= nextStateAttempt { stateDelayTask?.cancel() }
    urgentStateKeys.formUnion(pendingStates.keys)
  }
  func writeState(_ input: StateInput, immediate: Bool = false, progressOnly: Bool = false, fields: Set<String>? = nil) {
    let key = input.entityId + ":" + (input.pageIndex.map(String.init) ?? "chapter")
    let changed = fields ?? (progressOnly ? ["progress"] : ["favorite", "starred", "progress"])
    pendingStateFields[key, default: []].formUnion(changed)
    desiredStateFields[key, default: []].formUnion(changed)
    if progressOnly, desiredStates[key] == nil { progressOnlyKeys.insert(key) }
    if !progressOnly { progressOnlyKeys.remove(key) }
    pendingStates[key] = input; desiredStates[key] = input
    persistStates()
    if immediate {
      urgentStateKeys.insert(key)
      if Date() >= nextStateAttempt { stateDelayTask?.cancel() }
    }
    guard stateTask == nil else { return }
    let epoch = stateEpoch
    stateTask = Task {
      defer { if stateEpoch == epoch { stateTask = nil; stateDelayTask = nil } }
      var failures = 0
      while !Task.isCancelled && epoch == stateEpoch && !pendingStates.isEmpty {
        let backoff = nextStateAttempt.timeIntervalSinceNow
        if backoff > 0 || urgentStateKeys.isEmpty {
          let delay = Task<Void, Never> { try? await Task.sleep(for: .seconds(backoff > 0 ? backoff : 5)) }
          stateDelayTask = delay; await delay.value; stateDelayTask = nil
        }
        if Date() < nextStateAttempt { continue }
        guard !Task.isCancelled, epoch == stateEpoch,
          let key = urgentStateKeys.first(where: { pendingStates[$0] != nil }) ?? pendingStates.keys.first,
          let input = pendingStates.removeValue(forKey: key) else { return }
        urgentStateKeys.remove(key)
        let changed = pendingStateFields.removeValue(forKey: key) ?? ["favorite", "starred", "progress"]
        @MainActor func mergingIntent() -> StateInput {
          let remote = session.personalState(input.entityId, page: input.pageIndex)
          return StateInput(entityId: input.entityId, pageIndex: input.pageIndex,
            favorite: changed.contains("favorite") ? input.favorite : remote?.favorite ?? false,
            starred: changed.contains("starred") ? input.starred : remote?.starred ?? false,
            progress: changed.contains("progress") ? input.progress : remote?.progress)
        }
        guard entity(input.entityId) != nil else {
          desiredStates.removeValue(forKey: key); progressOnlyKeys.remove(key)
          desiredStateFields.removeValue(forKey: key); persistStates(); continue
        }
        do {
          do { try await session.saveState(mergingIntent()) }
          catch let error as APIError where error.status == 409 {
            try await session.reloadState(entity: input.entityId, page: input.pageIndex)
            try await session.saveState(mergingIntent())
          }
          failures = 0; nextStateAttempt = .distantPast
          if pendingStates[key] == nil {
            desiredStates.removeValue(forKey: key); progressOnlyKeys.remove(key); desiredStateFields.removeValue(forKey: key)
          } else { desiredStateFields[key] = pendingStateFields[key] }
          persistStates()
        } catch {
          guard epoch == stateEpoch else { return }
          if entity(input.entityId) == nil {
            desiredStates.removeValue(forKey: key); progressOnlyKeys.remove(key)
            desiredStateFields.removeValue(forKey: key); persistStates(); continue
          }
          if let api = error as? APIError, [400,401,402,403,404,409,422].contains(api.status) {
            // Keep the durable intent for deliberate retry; never spin on a rejected write.
            pendingStateFields[key, default: []].formUnion(changed)
            show(error); return
          }
          if pendingStates[key] == nil { pendingStates[key] = input }
          pendingStateFields[key, default: []].formUnion(changed)
          failures += 1
          if failures == 1 { show(error) }
          let delay = max((error as? APIError)?.retryAfter ?? 0, min(300, 5 * pow(2, Double(min(failures, 6)))))
          nextStateAttempt = Date().addingTimeInterval(delay)
        }
      }
    }
  }
  func synchronize() { Task { do { try await session.synchronize(force: true) } catch { show(error) } } }
  func edit(_ entity: LibraryEntity) {
    guard canManage else { return }
    editor = .init(entity: entity, kind: entity.kind)
  }
  func create(_ kind: EntityKind, title: String = "") {
    guard canManage else { return }
    editor = .init(kind: kind, initialTitle: title)
  }
  func visibilityChanged() {
    revision += 1
    if let reader, entity(reader.chapter.id) == nil { self.reader = nil }
    if let editor, editor.kind != .tag, let id = editor.entity?.id, entity(id) == nil {
      self.editor = nil
    }
    for activity in activities
    where !activity.completed && !activity.failed && entity(activity.id) == nil {
      cancelDownload(activity.id)
    }
    activities.removeAll { entity($0.id) == nil }
  }
}

// Owner-local durable latest intentions; no credentials or other accounts' data.
private actor ReadingStateOutbox {
  struct Entry: Codable, Sendable { let input: StateInput; let progressOnly: Bool; var fields: [String]? = nil }
  private var sequences: [String: UInt64] = [:]
  func save(_ values: [String: StateInput], progress: Set<String>, fields: [String: Set<String>], directory: URL, sequence: UInt64) throws {
    guard sequence >= sequences[directory.path, default: 0] else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let entries = values.map { Entry(input: $0.value, progressOnly: progress.contains($0.key), fields: fields[$0.key]?.sorted()) }
    try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("reading-outbox.json"), options: .atomic)
    sequences[directory.path] = sequence
  }
  func load(directory: URL) throws -> [Entry] {
    let file = directory.appendingPathComponent("reading-outbox.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
  }
}
