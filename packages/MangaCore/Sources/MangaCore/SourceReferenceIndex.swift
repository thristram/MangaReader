import Foundation

/// Metadata-only index. Filesystem answers are deliberately not cached between checks:
/// users can change symlinks or move folders outside the app.
public struct SourceReferenceIndex: Sendable {
  private struct Root: Sendable {
    var mediaIDs = Set<String>()
    var directories: [String: [String: Set<String>]] = [:]
  }
  private var roots: [String: Root] = [:]

  public init(media: [MediaVersion]) {
    for version in media {
      for path in version.relativePaths {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Match PathPolicy.resolve's validation before indexing, without any disk access.
        guard !parts.isEmpty, parts.allSatisfy({ (try? PathPolicy.component($0)) != nil }) else {
          continue
        }
        let directory = parts.dropLast().joined(separator: "/")
        let name = parts.last!
        roots[version.storageRootId, default: Root()].mediaIDs.insert(version.id)
        roots[version.storageRootId, default: Root()]
          .directories[directory, default: [:]][name, default: []].insert(version.id)
      }
    }
  }

  public func rootIDs(excluding mediaID: String) -> [String] {
    roots.compactMap { id, root in root.mediaIDs.contains(where: { $0 != mediaID }) ? id : nil }
  }

  public func containsAny(
    of sources: Set<String>, under root: URL, rootID: String, excluding mediaID: String
  ) throws -> Bool {
    var probes = Probes()
    return try containsAny(of: sources, under: root, rootID: rootID, excluding: mediaID,
                           probes: &probes)
  }

  // Operation counts allow tests to verify filesystem work scales by directory, not page count.
  struct Probes {
    var directoriesResolved = 0
    var directoriesListed = 0
    var filesResolved = 0
  }

  func containsAny(
    of sources: Set<String>, under root: URL, rootID: String, excluding mediaID: String,
    probes: inout Probes
  ) throws -> Bool {
    guard let references = roots[rootID], !sources.isEmpty else { return false }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    // PathPolicy rejects any reference escaping its canonical root, including symlinks.
    // A separate archive/NAS root therefore needs no directory or per-page checks.
    let relevant = sources.filter { $0.hasPrefix(base.path + "/") }
    guard !relevant.isEmpty else { return false }
    var directories = ["": base]
    var rejected = Set<String>()
    func resolveDirectory(_ relative: String) throws -> URL? {
      try Task.checkCancellation()
      if let cached = directories[relative] { return cached }
      if rejected.contains(relative) { return nil }
      let parts = relative.split(separator: "/")
      let parent = parts.dropLast().joined(separator: "/")
      guard let parentURL = try resolveDirectory(parent) else {
        rejected.insert(relative)
        return nil
      }
      probes.directoriesResolved += 1
      let url = parentURL.appendingPathComponent(String(parts.last!))
        .resolvingSymlinksInPath().standardizedFileURL
      guard url.path.hasPrefix(base.path + "/") else {
        rejected.insert(relative)
        return nil
      }
      directories[relative] = url
      return url
    }

    for (relative, names) in references.directories {
      try Task.checkCancellation()
      let names = Set(names.compactMap { name, owners in
        owners.contains(where: { $0 != mediaID }) ? name : nil
      })
      guard !names.isEmpty, let directory = try resolveDirectory(relative) else { continue }
      // A direct match is sufficient to retain originals. No image reads or lstat per page.
      if names.contains(where: { relevant.contains(directory.appendingPathComponent($0).path) }) {
        return true
      }
      // A referenced file may be a differently named symlink. List once per directory
      // with prefetched attributes; resolve only symlinks, rather than every image path.
      probes.directoriesListed += 1
      let entries: [URL]
      do {
        entries = try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
      } catch {
        // A standalone-file sandbox grant may not permit listing its parent. Preserve
        // the original per-reference check for that folder instead of missing aliases.
        for name in names {
          try Task.checkCancellation()
          probes.filesResolved += 1
          let url = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
          if url.path.hasPrefix(base.path + "/"), relevant.contains(url.path) { return true }
        }
        continue
      }
      for entry in entries where names.contains(entry.lastPathComponent) {
        try Task.checkCancellation()
        // Unknown attributes also take the safe fallback, rather than assuming a regular file.
        guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != false
        else { continue }
        probes.filesResolved += 1
        let url = entry.resolvingSymlinksInPath().standardizedFileURL
        if url.path.hasPrefix(base.path + "/"), relevant.contains(url.path) { return true }
      }
    }
    return false
  }
}
