import Combine
import Foundation
import MangaCore
import SwiftUI

enum LibraryPage: String, CaseIterable, Identifiable, Hashable {
  case search, library, continuing, favorites, starred, savedPages, authors, series, tags
  case history, statistics, downloads, importing, organization, storage
  case settings, reading, translation, connections, sync, files
  var id: String { rawValue }
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
  static let activityPages: [Self] = [.history, .statistics, .downloads]
  static let settingsPages: [Self] = [
    .settings, .reading, .translation, .connections, .sync, .files,
  ]
}
enum LibraryRoute: Hashable {
  case page(LibraryPage)
  case entity(String)
}
enum LibrarySort: String, CaseIterable {
  case updated = "Recently Updated"
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
}

@MainActor final class LibraryUIModel: ObservableObject {
  let session: AppSession
  let local: LocalMedia
  let smb: SMBMedia
  @Published var selection: LibraryPage? = .library
  @Published var path: [LibraryRoute] = []
  @Published var forwardPath: [LibraryRoute] = []
  private var restoringForward = false
  @Published var query = ""
  @Published var sort: LibrarySort = .updated
  @Published var unreadOnly = false
  @Published var selectedTag: String?
  @Published var editor: EditorRequest?
  @Published var reader: ReadingContext?
  @Published var message: UIMessage?
  @Published var activities: [DownloadActivity] = []
  @Published var opening = false
  @Published var revision = 0
  private var downloadTask: Task<Void, Never>?
  private var downloadEpoch = UUID()
  private var stateTask: Task<Void, Never>?
  private var pendingStates: [String: StateInput] = [:]
  private var desiredStates: [String: StateInput] = [:]
  private var stateEpoch = UUID()
  init(session: AppSession) {
    self.session = session
    local = LocalMedia(session: session)
    smb = SMBMedia(session: session)
    smb.progress = { [weak self] text in
      guard let self, let index = activities.firstIndex(where: { !$0.completed && !$0.failed })
      else { return }
      activities[index].detail = text
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
    downloadEpoch = UUID()
    downloadTask?.cancel()
    downloadTask = nil
    stateEpoch = UUID()
    stateTask?.cancel()
    stateTask = nil
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
    guard let id else { return nil }
    return session.visibleEntities().first { $0.id == id }
  }
  func title(_ entity: LibraryEntity) -> String {
    entity.title(in: AppConfiguration.preferredLanguage)
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
    case .tag:
      return visible.filter {
        [.work, .chapter, .series].contains($0.kind) && effectiveTags($0).contains(parent.id)
      }
    default: return []
    }
  }
  func authorPreviews(_ author: LibraryEntity) -> [LibraryEntity] {
    session.visibleEntities().filter {
      $0.authorId == author.id && ($0.kind == .work || ($0.kind == .chapter && $0.workId == nil))
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
    session.states.first { $0.entityId == id && $0.pageIndex == page }
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
          $0.kind == .chapter && $0.media.contains { smb.downloadedURLs($0) != nil }
        })
    default:
      return filtered(
        visible.filter { $0.kind == .work || ($0.kind == .chapter && $0.workId == nil) })
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
    return rows.sorted {
      if lastRead || sort == .read {
        return (state($0.id)?.updatedAt ?? "") > (state($1.id)?.updatedAt ?? "")
      }
      if sort == .title {
        return title($0).localizedStandardCompare(title($1)) == .orderedAscending
      }
      if sort == .author {
        let a = entity($0.authorId).map(title) ?? "other author"
        let b = entity($1.authorId).map(title) ?? "other author"
        if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
      }
      return $0.updatedAt > $1.updatedAt
    }
  }
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
  func coverURL(_ entity: LibraryEntity) -> URL? {
    let chapter = entity.kind == .chapter ? entity : chapters(entity).first
    guard let version = chapter?.preferredMedia(AppConfiguration.preferredLanguage) else {
      return nil
    }
    let urls = cachedURLs(version) ?? []
    return zip(version.relativePaths, urls).min {
      URL(fileURLWithPath: $0.0).lastPathComponent.localizedStandardCompare(
        URL(fileURLWithPath: $1.0).lastPathComponent) == .orderedAscending
    }?.1
  }
  func pageSource(_ chapter: LibraryEntity, page: Int) -> (url: URL?, kind: String, index: Int) {
    guard let preferred = chapter.preferredMedia(AppConfiguration.preferredLanguage) else {
      return (nil, "images", page)
    }
    let original =
      chapter.media.first { $0.language == chapter.originalLanguage } ?? chapter.media.first
      ?? preferred
    let media = preferred.sourcePage(at: page) == nil ? original : preferred
    guard let source = media.sourcePage(at: page) else { return (nil, media.kind, page) }
    let urls = cachedURLs(media) ?? []
    return (
      media.kind == "images" ? (source < urls.count ? urls[source] : nil) : urls.first, media.kind,
      source
    )
  }
  func open(_ chapter: LibraryEntity, page: Int? = nil) {
    guard !opening else { return }
    opening = true
    let owner = session.account?.ownerId
    Task {
      defer { opening = false }
      do {
        guard let current = entity(chapter.id),
          let version = current.preferredMedia(AppConfiguration.preferredLanguage),
          version.pageCount > 0
        else { throw StorageError.emptyChapter }
        let urls: [URL]
        if let cached = cachedURLs(version) {
          urls = cached
        } else {
          urls = try await smb.download(version)
        }
        guard owner == session.account?.ownerId, entity(chapter.id) != nil else { return }
        reader = ReadingContext(
          chapter: current, version: version, urls: urls,
          page: min(
            max(0, page ?? state(chapter.id)?.progress?.pageIndex ?? 0),
            max(version.pageCount, version.pageAlignment?.count ?? 0) - 1))
      } catch { if owner == session.account?.ownerId { show(error) } }
    }
  }
  func download(_ entity: LibraryEntity) {
    guard downloadTask == nil else {
      message = UIMessage(text: "A download is already running. You can cancel it from Downloads.")
      return
    }
    let owner = session.account?.ownerId
    activities.removeAll { $0.id == entity.id }
    activities.append(.init(id: entity.id, title: title(entity), detail: "Preparing download…"))
    let epoch = downloadEpoch
    downloadTask = Task {
      defer { if downloadEpoch == epoch { downloadTask = nil } }
      do {
        try await smb.download(entity)
        guard owner == session.account?.ownerId else { return }
        if let index = activities.firstIndex(where: { $0.id == entity.id }) {
          activities[index].completed = true
          activities[index].detail = "Available offline"
        }
        revision += 1
      } catch {
        guard owner == session.account?.ownerId else { return }
        if let index = activities.firstIndex(where: { $0.id == entity.id }) {
          activities[index].failed = true
          activities[index].detail =
            error is CancellationError ? "Download cancelled" : error.localizedDescription
        }
      }
    }
  }
  func cancelDownload() { downloadTask?.cancel() }
  func removeDownload(_ entity: LibraryEntity) {
    do {
      for version in entity.media { try smb.deleteDownload(version) }
      revision += 1
    } catch { show(error) }
  }
  func mark(_ entity: LibraryEntity, starred: Bool, page: Int? = nil) {
    let old = stateInput(entity.id, page: page)
    writeState(
      .init(
        entityId: entity.id, pageIndex: page,
        favorite: starred ? old?.favorite ?? false : !(old?.favorite ?? false),
        starred: starred ? !(old?.starred ?? false) : old?.starred ?? false, progress: old?.progress
      ))
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
  func writeState(_ input: StateInput) {
    let key = input.entityId + ":" + (input.pageIndex.map(String.init) ?? "chapter")
    pendingStates[key] = input
    desiredStates[key] = input
    guard stateTask == nil else { return }
    let epoch = stateEpoch
    stateTask = Task {
      defer { if stateEpoch == epoch { stateTask = nil } }
      while !Task.isCancelled && epoch == stateEpoch, let key = pendingStates.keys.first,
        let input = pendingStates.removeValue(forKey: key)
      {
        do {
          try await session.saveState(input)
          if pendingStates[key] == nil { desiredStates.removeValue(forKey: key) }
        } catch {
          if epoch != stateEpoch { return }
          if let error = error as? APIError, error.status == 409 {
            do {
              try await session.synchronize()
              try await session.saveState(input)
            } catch { show(error) }
          } else {
            show(error)
          }
        }
      }
    }
  }
  func synchronize() { Task { do { try await session.synchronize() } catch { show(error) } } }
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
    if activities.contains(where: { !$0.completed && !$0.failed && entity($0.id) == nil }) {
      cancelDownload()
    }
    activities.removeAll { entity($0.id) == nil }
  }
}
