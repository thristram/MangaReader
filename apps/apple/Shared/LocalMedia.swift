import Foundation
import MangaCore

@MainActor final class LocalMedia {
  let session: AppSession
  private struct RootAccess: Sendable {
    let resource: URL
    let directory: URL
    let accessing: Bool
    func stop() { if accessing { resource.stopAccessingSecurityScopedResource() } }
  }
  private var activeRoots: [String: RootAccess] = [:]
  private var readingRoots: [String: (id: UUID, task: Task<URL, Error>)] = [:]
  private var readingEpoch = UUID()
  init(session: AppSession) { self.session = session }
  private var bindingsURL: URL? {
    session.cacheDirectory?.appendingPathComponent("storage-bindings.json")
  }
  nonisolated static func bookmark(for url: URL) throws -> Data {
    #if os(macOS)
      return try url.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    #else
      return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    #endif
  }
  nonisolated private static func access(_ resource: URL) throws -> RootAccess {
    let accessing = resource.startAccessingSecurityScopedResource()
    do {
      let isDirectory = try resource.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      return RootAccess(resource: resource,
                        directory: isDirectory ? resource : resource.deletingLastPathComponent(),
                        accessing: accessing)
    } catch {
      if accessing { resource.stopAccessingSecurityScopedResource() }
      throw error
    }
  }
  func bind(
    _ root: LibraryEntity, to url: URL, initializeDestination: Bool = true,
    sourceBookmark: Data? = nil
  ) throws {
    guard let owner = session.account?.ownerId else { throw LoginError.invalidToken }
    let access = try Self.access(url)
    var retained = false
    defer { if !retained { access.stop() } }
    if root.isArchiveDestination && initializeDestination {
      try LibraryDestinationIdentity.bind(folder: url, libraryId: owner, destinationId: root.id)
    }
    let bookmark = try sourceBookmark ?? Self.bookmark(for: url)
    guard let path = bindingsURL else { throw LoginError.invalidToken }
    var all = (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: path))) ?? [:]
    all[root.id] = bookmark
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(all).write(to: path, options: .atomic)
    invalidateReadingRoots()
    activeRoots.removeValue(forKey: root.id)?.stop()
    activeRoots[root.id] = access
    retained = true
  }
  // Bookmark resolution can contact a Finder-mounted network volume. Read paths
  // resolve it off the main actor, without prompting or attempting to mount a NAS.
  func readingRootURL(_ id: String) async throws -> URL {
    if let access = activeRoots[id] { return access.directory }
    if let request = readingRoots[id] { return try await request.task.value }
    guard let path = bindingsURL, let owner = session.account?.ownerId else {
      throw LoginError.invalidToken
    }
    let requestId = UUID()
    let epoch = readingEpoch
    let task = Task<URL, Error> {
      let access = try await FileTasks.perform {
        guard
          let all = try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: path)),
          let bookmark = all[id]
        else { throw LoginError.server("Connect this storage root on this device first.") }
        var stale = false
        #if os(macOS)
          let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        #else
          let url = try URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return try Self.access(url)
      }
      guard !Task.isCancelled, epoch == readingEpoch, owner == session.account?.ownerId else {
        access.stop()
        throw CancellationError()
      }
      // A synchronous settings operation may have resolved the same binding.
      if let existing = activeRoots[id] {
        access.stop()
        return existing.directory
      }
      activeRoots[id] = access
      return access.directory
    }
    readingRoots[id] = (requestId, task)
    defer { if readingRoots[id]?.id == requestId { readingRoots.removeValue(forKey: id) } }
    return try await task.value
  }
  func boundSourceURL(_ id: String) async throws -> URL {
    _ = try await readingRootURL(id)
    guard let access = activeRoots[id] else { throw LoginError.invalidToken }
    return access.resource
  }
  private func invalidateReadingRoots() {
    readingEpoch = UUID()
    readingRoots.values.forEach { $0.task.cancel() }
    readingRoots = [:]
  }
  func rootURL(_ id: String) throws -> URL {
    if let access = activeRoots[id] { return access.directory }
    guard let path = bindingsURL,
      let all = try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: path)),
      let bookmark = all[id]
    else { throw LoginError.server("Connect this storage root on this device first.") }
    var stale = false
    #if os(macOS)
      let url = try URL(
        resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
        bookmarkDataIsStale: &stale)
    #else
      let url = try URL(
        resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    #endif
    let access = try Self.access(url)
    activeRoots[id] = access
    return access.directory
  }
  func validateDestination(_ root: LibraryEntity) throws -> URL {
    guard root.isArchiveDestination, let owner = session.account?.ownerId else {
      throw LoginError.invalidToken
    }
    let url = try rootURL(root.id)
    let identity = try JSONDecoder().decode(
      LibraryDestinationIdentity.self,
      from: Data(contentsOf: PathPolicy.resolve(LibraryDestinationIdentity.filename, under: url)))
    try identity.validate(libraryId: owner, destinationId: root.id)
    return url
  }
  func validateDestinationAsync(_ root: LibraryEntity) async throws -> URL {
    guard root.isArchiveDestination, let owner = session.account?.ownerId else {
      throw LoginError.invalidToken
    }
    let url = try await readingRootURL(root.id)
    try await FileTasks.perform {
      let identity = try JSONDecoder().decode(
        LibraryDestinationIdentity.self,
        from: Data(contentsOf: PathPolicy.resolve(LibraryDestinationIdentity.filename, under: url)))
      try identity.validate(libraryId: owner, destinationId: root.id)
    }
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    return url
  }
  func referenceRoots(for media: [MediaVersion]) async throws -> [String: URL] {
    let owner = session.account?.ownerId
    var roots: [String: URL] = [:]
    for id in Set(media.map(\.storageRootId)) {
      try Task.checkCancellation()
      roots[id] = try? await readingRootURL(id)
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    }
    return roots
  }
  func sourceIsShared(_ candidates: [URL], excluding mediaId: String) async throws -> Bool {
    let owner = session.account?.ownerId
    let media = session.entities.filter { !$0.deleted }.flatMap(\.media).filter { $0.id != mediaId }
    let roots = try await referenceRoots(for: media)
    let shared = try await FileTasks.perform {
      let sources = Set(candidates.map { $0.resolvingSymlinksInPath().path })
      for version in media {
        try Task.checkCancellation()
        guard let root = roots[version.storageRootId] else { continue }
        for relative in version.relativePaths {
          if let url = try? PathPolicy.resolve(relative, under: root), sources.contains(url.path) {
            return true
          }
        }
      }
      return false
    }
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    return shared
  }
  func urls(for media: MediaVersion) throws -> [URL] {
    let root = try rootURL(media.storageRootId)
    let marker = try PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root)
    if FileManager.default.fileExists(atPath: marker.path), let owner = session.account?.ownerId {
      try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
        .validate(libraryId: owner, destinationId: media.storageRootId)
    }
    return try media.relativePaths.map { try PathPolicy.resolve($0, under: root) }
  }
  func availableURLs(for media: MediaVersion) async throws -> [URL] {
    let root = try rootURL(media.storageRootId)
    let owner = session.account?.ownerId
    return try await FileTasks.perform {
      let marker = try PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root)
      if FileManager.default.fileExists(atPath: marker.path), let owner {
        try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
          .validate(libraryId: owner, destinationId: media.storageRootId)
      }
      let urls = try media.relativePaths.map { try PathPolicy.resolve($0, under: root) }
      guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
        throw StorageError.emptyChapter
      }
      return urls
    }
  }
  func url(for media: MediaVersion, file index: Int) async throws -> URL {
    guard media.relativePaths.indices.contains(index) else { throw StorageError.emptyChapter }
    let root = try await readingRootURL(media.storageRootId)
    let owner = session.account?.ownerId
    let relative = media.relativePaths[index]
    return try await FileTasks.perform {
      let marker = try PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root)
      if FileManager.default.fileExists(atPath: marker.path), let owner {
        try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
          .validate(libraryId: owner, destinationId: media.storageRootId)
      }
      let url = try PathPolicy.resolve(relative, under: root)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw StorageError.emptyChapter
      }
      return url
    }
  }
  func archiveFiles(for entity: LibraryEntity, deleting ids: Set<String>) throws -> [ArchiveFile] {
    guard let owner = session.account?.ownerId else { throw LoginError.invalidToken }
    var files: [ArchiveFile] = []
    for media in entity.media {
      let paths = ComicDeletionPlan.exclusivePaths(media, deleting: ids, entities: session.entities)
      // Add-only imports store bare filenames under their source bookmark.
      // Managed imports store their organized relative folder path.
      guard !paths.isEmpty else { continue }
      let root: URL
      do { root = try rootURL(media.storageRootId) } catch {
        throw LoginError.server(
          "Connect this comic’s library folder in Media Storage or Connections before deleting it.")
      }
      let marker = try PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root)
      guard FileManager.default.fileExists(atPath: marker.path) else {
        throw LoginError.server(
          "Verify this library folder in Media Storage before recycling its comics.")
      }
      try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
        .validate(libraryId: owner, destinationId: media.storageRootId)
      files += paths.map {
        ArchiveFile(root: root, rootId: media.storageRootId, libraryId: owner, relativePath: $0)
      }
    }
    return files
  }
  func release() {
    invalidateReadingRoots()
    for access in activeRoots.values { access.stop() }
    activeRoots = [:]
  }
}

enum FileTasks {
  static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(operation: work)
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
