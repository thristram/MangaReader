import Foundation
import MangaCore

@MainActor final class LocalMedia {
  let session: AppSession
  private var activeRoots: [String: URL] = [:]
  init(session: AppSession) { self.session = session }
  private var bindingsURL: URL? {
    session.cacheDirectory?.appendingPathComponent("storage-bindings.json")
  }
  func bind(_ root: LibraryEntity, to url: URL) throws {
    #if os(macOS)
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    #else
      let bookmark = try url.bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    #endif
    guard let path = bindingsURL else { throw LoginError.invalidToken }
    var all = (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: path))) ?? [:]
    all[root.id] = bookmark
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(all).write(to: path, options: .atomic)
    if url.startAccessingSecurityScopedResource() { activeRoots[root.id] = url }
  }
  func rootURL(_ id: String) throws -> URL {
    if let url = activeRoots[id] { return url }
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
    _ = url.startAccessingSecurityScopedResource()
    activeRoots[id] = url
    return url
  }
  func urls(for media: MediaVersion) throws -> [URL] {
    let root = try rootURL(media.storageRootId)
    return try media.relativePaths.map { try PathPolicy.resolve($0, under: root) }
  }
  func release() {
    for url in activeRoots.values { url.stopAccessingSecurityScopedResource() }
    activeRoots = [:]
  }
}
