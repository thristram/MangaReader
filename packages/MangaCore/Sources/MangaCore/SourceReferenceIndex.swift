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

  /// Resolve selected parents once per operation, not once per image. Fresh
  /// directory attributes still resolve file symlinks and unknown entries safely.
  public static func canonicalSources(_ candidates: [URL]) throws -> Set<String> {
    var probes = Probes()
    return try canonicalSources(candidates, probes: &probes)
  }
  static func canonicalSources(_ candidates: [URL], probes: inout Probes) throws -> Set<String> {
    var paths = Set<String>()
    for (parent, files) in Dictionary(grouping: candidates, by: { $0.deletingLastPathComponent().standardizedFileURL.path }) {
      try Task.checkCancellation()
      probes.directoriesResolved += 1
      let base = URL(fileURLWithPath: parent).resolvingSymlinksInPath().standardizedFileURL
      probes.directoriesListed += 1
      let entries = try? FileManager.default.contentsOfDirectory(at: base,
        includingPropertiesForKeys: [.isSymbolicLinkKey])
      let names = Dictionary((entries ?? []).map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
      for file in files {
        try Task.checkCancellation()
        if let entry = names[file.lastPathComponent],
          (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false {
          paths.insert(base.appendingPathComponent(file.lastPathComponent).path)
        } else {
          probes.filesResolved += 1
          paths.insert(file.resolvingSymlinksInPath().standardizedFileURL.path)
        }
      }
    }
    return paths
  }

  public func rootIDs(excluding mediaID: String) -> [String] {
    rootIDs(excluding: [mediaID])
  }

  public func rootIDs(excluding mediaIDs: Set<String>) -> [String] {
    roots.compactMap { id, root in root.mediaIDs.subtracting(mediaIDs).isEmpty ? nil : id }
  }

  public func matchingSources(
    _ sources: Set<String>, under root: URL, rootID: String, excluding mediaIDs: Set<String>
  ) throws -> Set<String> {
    var probes = Probes()
    return try matchingSources(
      sources, under: root, rootID: rootID, excluding: mediaIDs,
      firstOnly: false, probes: &probes)
  }

  public func containsAny(
    of sources: Set<String>, under root: URL, rootID: String, excluding mediaID: String
  ) throws -> Bool {
    var probes = Probes()
    return try containsAny(
      of: sources, under: root, rootID: rootID, excluding: mediaID,
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
    try !matchingSources(
      sources, under: root, rootID: rootID, excluding: [mediaID],
      firstOnly: true, probes: &probes
    ).isEmpty
  }

  private func matchingSources(
    _ sources: Set<String>, under root: URL, rootID: String, excluding mediaIDs: Set<String>,
    firstOnly: Bool, probes: inout Probes
  ) throws -> Set<String> {
    var matches = Set<String>()
    guard let references = roots[rootID], !sources.isEmpty else { return [] }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    // PathPolicy rejects any reference escaping its canonical root, including symlinks.
    // A separate archive/NAS root therefore needs no directory or per-page checks.
    let relevant = sources.filter { $0.lowercased().hasPrefix(base.path.lowercased() + "/") }
    guard !relevant.isEmpty else { return [] }
    // Conservatively retain case aliases on case-insensitive mounted volumes too.
    let byPath = Dictionary(grouping: relevant, by: { $0.lowercased() })
    func addMatches(_ path: String) {
      matches.formUnion(byPath[path.lowercased()] ?? [])
    }
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
      let names = Set(
        names.compactMap { name, owners in
          !owners.subtracting(mediaIDs).isEmpty ? name : nil
        })
      guard !names.isEmpty, let directory = try resolveDirectory(relative) else { continue }
      // A direct match is sufficient to retain originals. No image reads or lstat per page.
      for name in names {
        let path = directory.appendingPathComponent(name).path
        addMatches(path)
        if firstOnly && !matches.isEmpty { return matches }
      }
      if matches == relevant { return matches }
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
          if url.path.hasPrefix(base.path + "/") {
            addMatches(url.path)
            if firstOnly && !matches.isEmpty || matches == relevant { return matches }
          }
        }
        continue
      }
      let foldedNames = Set(names.map { $0.lowercased() })
      for entry in entries where foldedNames.contains(entry.lastPathComponent.lowercased()) {
        try Task.checkCancellation()
        // Unknown attributes also take the safe fallback, rather than assuming a regular file.
        guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != false
        else { continue }
        probes.filesResolved += 1
        let url = entry.resolvingSymlinksInPath().standardizedFileURL
        if url.path.hasPrefix(base.path + "/") {
          addMatches(url.path)
          if firstOnly && !matches.isEmpty || matches == relevant { return matches }
        }
      }
    }
    return matches
  }
}
