import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum StorageError: Error, LocalizedError {
  case unsafePath, collision, unsupportedMove, emptyChapter, verificationFailed,
    recycleRecoveryRequired
  public var errorDescription: String? {
    switch self {
    case .unsafePath: return "The path is outside the selected storage root."
    case .collision: return "The destination already exists. No files were overwritten."
    case .unsupportedMove: return "This file type cannot be moved."
    case .verificationFailed:
      return "Files changed or could not be verified. Review Pending Organization before retrying."
    case .recycleRecoveryRequired:
      return
        "Files are safe in Recycle, but restoring their original paths needs review in Pending Organization."
    case .emptyChapter: return "No supported media was found."
    }
  }
}
public enum PathPolicy {
  public static func component(_ text: String) throws -> String {
    let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !v.isEmpty, v != ".", v != "..", !v.contains("/"), !v.contains("\\"), !v.contains("\0"),
      !v.contains(":"), v.utf8.count <= 240
    else { throw StorageError.unsafePath }
    return v
  }
  public static func chapterPath(
    author: String?, series: String?, work: String?, chapter: String, language: String?,
    mediaLanguageCount: Int
  ) throws -> String {
    let author = author?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = [
      author?.isEmpty == false ? author : "other author", series, work, chapter,
      mediaLanguageCount > 1 ? language : nil,
    ].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return try fields.map(component).joined(separator: "/")
  }
  public static func mutationPath(_ path: String, under root: URL) throws -> URL {
    guard !path.hasPrefix("/"), !path.isEmpty else { throw StorageError.unsafePath }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    for part in parts { _ = try component(part) }
    // Resolve the granted root once, then inspect each component once. Calling
    // resolve for every prefix repeatedly walks the same NAS ancestors.
    var url = root.resolvingSymlinksInPath().standardizedFileURL
    var missing = false
    for part in parts {
      url.appendPathComponent(part)
      if missing { continue }
      var value = stat()
      if lstat(url.path, &value) == 0 {
        guard UInt32(value.st_mode) & UInt32(S_IFMT) != UInt32(S_IFLNK) else {
          throw StorageError.unsafePath
        }
      } else if errno == ENOENT {
        missing = true
      } else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
    return url
  }
  public static func resolve(_ path: String, under root: URL) throws -> URL {
    guard !path.hasPrefix("/"), !path.isEmpty else { throw StorageError.unsafePath }
    _ = try path.split(separator: "/", omittingEmptySubsequences: false).map {
      try component(String($0))
    }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    var url = base
    for part in path.split(separator: "/") {
      url = url.appendingPathComponent(String(part)).resolvingSymlinksInPath().standardizedFileURL
      guard url.path.hasPrefix(base.path + "/") else { throw StorageError.unsafePath }
    }
    return url
  }
}
public struct ImportCandidate: Identifiable, Sendable {
  public var id: String { source.path }
  public var source: URL
  public var title: String
  public var kind: String
  public var pages: [URL]
  public var warnings: [String]
}
public struct ImportName: Equatable, Sendable {
  public let title: String
  public let pixivID: String?
  public static func parse(_ name: String) -> ImportName {
    let parts = name.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
    let prefix = parts.first.map(String.init) ?? ""
    guard !prefix.isEmpty, prefix.utf8.allSatisfy({ (48...57).contains($0) }) else {
      return .init(title: name, pixivID: nil)
    }
    return .init(
      title: parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "",
      pixivID: prefix)
  }
}
public enum ImportScanner {
  public static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "gif", "bmp", "avif",
  ]
  public static func scan(_ url: URL) throws -> [ImportCandidate] {
    let fm = FileManager.default
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values.isSymbolicLink == true { throw StorageError.unsafePath }
    guard values.isDirectory == true else {
      let ext = url.pathExtension.lowercased()
      guard imageExtensions.contains(ext) || ext == "pdf" || ext == "webm" || ext == "mp4" else { throw StorageError.emptyChapter }
      return [
        .init(
          source: url, title: url.deletingPathExtension().lastPathComponent,
          kind: imageExtensions.contains(ext) ? "images" : ext == "pdf" ? "pdf" : "video", pages: [url], warnings: [])
      ]
    }
    let entries = try fm.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    let images = entries.filter { imageExtensions.contains($0.pathExtension.lowercased()) }.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    let subfolders = entries.filter {
      (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    var result: [ImportCandidate] = []
    if !images.isEmpty {
      result.append(
        .init(
          source: url, title: url.lastPathComponent, kind: "images", pages: images,
          warnings: subfolders.isEmpty
            && !entries.contains(where: {
              ["pdf", "webm", "mp4"].contains($0.pathExtension.lowercased())
            })
            ? []
            : [
              "This folder also contains nested or separate chapters. Add-only is available; automatic folder moves are disabled."
            ]))
    }
    for entry in entries where ["pdf", "webm", "mp4"].contains(entry.pathExtension.lowercased()) {
      result += try scan(entry)
    }
    for folder in subfolders { result += try scan(folder) }
    return result
  }
}
public struct FileInventory: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var path: String
    public var digest: String?
  }
  public var directory: Bool
  public var entries: [Entry]
  public static func digest(_ url: URL, checkCancellation: Bool = true) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
      if checkCancellation { try Task.checkCancellation() }
      hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func read(_ url: URL) throws -> Self {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
    let values = try url.resourceValues(forKeys: keys)
    guard values.isSymbolicLink != true else { throw StorageError.unsafePath }
    if values.isDirectory != true {
      guard values.isRegularFile == true else { throw StorageError.unsupportedMove }
      return .init(directory: false, entries: [.init(path: "", digest: try digest(url))])
    }
    var entries: [Entry] = []
    func visit(_ folder: URL, prefix: String) throws {
      let children = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: Array(keys))
      for item in children {
        try Task.checkCancellation()
        let value = try item.resourceValues(forKeys: keys)
        guard value.isSymbolicLink != true else { throw StorageError.unsafePath }
        let path = prefix + item.lastPathComponent
        _ = try PathPolicy.resolve(path, under: url)
        if value.isDirectory == true {
          entries.append(.init(path: path, digest: nil))
          try visit(item, prefix: path + "/")
        } else if value.isRegularFile == true {
          entries.append(.init(path: path, digest: try digest(item)))
        } else {
          throw StorageError.unsupportedMove
        }
      }
    }
    try visit(url, prefix: "")
    return .init(directory: true, entries: entries.sorted { $0.path < $1.path })
  }
}
public struct MoveJournal: Codable, Sendable {
  public var id: String
  public var source: String
  public var destination: String
  public var phase: String
  public var removeSourceAfterCommit: Bool? = nil
  public var inventory: FileInventory? = nil
}
public enum FileCommit {
  /// Same-volume renames stay atomic. Cross-volume moves publish a verified copy
  /// and keep the source until metadata has committed successfully.
  public static func move(
    source: URL, destinationRelativePath: String, root: URL, journalDirectory: URL,
    recoveryPayload: Data? = nil, copyBeforeCommit: Bool = false, keepSource: Bool = false
  ) throws -> MoveJournal {
    let fm = FileManager.default
    guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw StorageError.unsafePath
    }
    let destination = try PathPolicy.resolve(destinationRelativePath, under: root)
    let source = source.standardizedFileURL
    guard source.resolvingSymlinksInPath() != root.resolvingSymlinksInPath(),
      !destination.path.hasPrefix(source.resolvingSymlinksInPath().path + "/")
    else { throw StorageError.unsafePath }
    guard !fm.fileExists(atPath: destination.path) else { throw StorageError.collision }
    let sourceVolume = try source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    let rootVolume = try root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    var copy =
      keepSource || copyBeforeCommit || sourceVolume == nil || rootVolume == nil
      || String(describing: sourceVolume) != String(describing: rootVolume)
    try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    var journal = MoveJournal(
      id: UUID().uuidString, source: source.path, destination: destination.path, phase: "prepared")
    if copy {
      journal.removeSourceAfterCommit = !keepSource
      journal.inventory = try FileInventory.read(source)
    }
    try write(journal, in: journalDirectory)
    if let recoveryPayload {
      try recoveryPayload.write(
        to: journalDirectory.appendingPathComponent(journal.id + "-metadata.json"), options: .atomic
      )
    }
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !copy {
      do { try fm.moveItem(at: source, to: destination) } catch {
        var error = error as NSError
        while let nested = error.userInfo[NSUnderlyingErrorKey] as? NSError { error = nested }
        guard error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) else { throw error }
        copy = true
        journal.removeSourceAfterCommit = !keepSource
        journal.inventory = try FileInventory.read(source)
        try write(journal, in: journalDirectory)
      }
    }
    if copy {
      let temporary = destination.deletingLastPathComponent().appendingPathComponent(
        ".mangareader-transfer-" + journal.id)
      do {
        try Task.checkCancellation()
        try fm.copyItem(at: source, to: temporary)
        guard try FileInventory.read(temporary) == journal.inventory,
          try FileInventory.read(source) == journal.inventory
        else { throw StorageError.verificationFailed }
        try Task.checkCancellation()
        guard !fm.fileExists(atPath: destination.path) else { throw StorageError.collision }
        try fm.moveItem(at: temporary, to: destination)
      } catch {
        try? fm.removeItem(at: temporary)
        journal.phase = "failed"
        try? write(journal, in: journalDirectory)
        throw error
      }
    }
    journal.phase = "filesMoved_metadataPending"
    try write(journal, in: journalDirectory)
    return journal
  }
  private static func write(_ journal: MoveJournal, in directory: URL) throws {
    try JSONEncoder().encode(journal).write(
      to: directory.appendingPathComponent(journal.id + ".json"), options: .atomic)
  }
  public static func finish(_ journal: MoveJournal, in directory: URL) throws {
    let path = directory.appendingPathComponent(journal.id + ".json")
    var current = try JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: path))
    if current.phase == "complete" { return }
    if current.removeSourceAfterCommit == true {
      guard let inventory = current.inventory,
        try FileInventory.read(URL(fileURLWithPath: current.destination)) == inventory
      else { throw StorageError.verificationFailed }
      let source = URL(fileURLWithPath: current.source)
      if FileManager.default.fileExists(atPath: source.path) {
        guard try FileInventory.read(source) == inventory else {
          throw StorageError.verificationFailed
        }
        try FileManager.default.removeItem(at: source)
      }
    }
    current.phase = "complete"
    try write(current, in: directory)
  }
}

/// A transport-independent marker. The same bytes are validated when the folder
/// is selected directly, mounted over SMB, or connected through the SMB client.
public struct LibraryDestinationIdentity: Codable, Equatable, Sendable {
  public static let filename = ".mangareader-library.json"
  // Storage root description is reserved for this role in the existing v1 API.
  // Import sources remain readable but never appear as archive destinations.
  public static let sourceOnlyDescription = "mangareader:import-source:v1"
  public var version = 1
  public var libraryId: String
  public var destinationId: String
  public init(libraryId: String, destinationId: String) {
    self.libraryId = libraryId
    self.destinationId = destinationId
  }
  public func validate(libraryId: String, destinationId: String) throws {
    guard version == 1, self.libraryId == libraryId, self.destinationId == destinationId else {
      throw DestinationIdentityError.mismatch
    }
  }
  public static func bind(folder: URL, libraryId: String, destinationId: String) throws {
    let marker = try PathPolicy.resolve(filename, under: folder)
    if FileManager.default.fileExists(atPath: marker.path) {
      try JSONDecoder().decode(Self.self, from: Data(contentsOf: marker))
        .validate(libraryId: libraryId, destinationId: destinationId)
    } else {
      let data = try JSONEncoder().encode(Self(libraryId: libraryId, destinationId: destinationId))
      try data.write(to: marker, options: .withoutOverwriting)
    }
  }
}
public enum DestinationIdentityError: Error, LocalizedError {
  case mismatch
  public var errorDescription: String? {
    "This folder belongs to a different library or destination. Choose the matching library folder."
  }
}
public struct HorizontalPageGesture: Sendable {
  private var accumulated: Double = 0
  private var lastTurn: Double = -.infinity
  private var lastEvent: Double = -.infinity
  public init() {}
  public mutating func consume(dx: Double, dy: Double, time: Double, ended: Bool = false) -> Int? {
    if ended {
      accumulated = 0
      return nil
    }
    if time - lastEvent > 0.25 { accumulated = 0 }
    lastEvent = time
    guard abs(dx) > abs(dy), time - lastTurn >= 0.4 else { return nil }
    if accumulated.sign != dx.sign { accumulated = 0 }
    accumulated += dx
    guard abs(accumulated) >= 45 else { return nil }
    let step = accumulated > 0 ? -1 : 1
    accumulated = 0
    lastTurn = time
    return step
  }
}

/// Explicit, bounded empty-directory cleanup, persisted with the file journal.
/// rmdir is atomic and never recursively removes unrelated or concurrently added files.
public struct EmptyMediaFolder: Codable, Sendable {
  public let root: String
  public let relativePath: String
  public init(root: URL, relativePath: String) {
    self.root = root.path
    self.relativePath = relativePath
  }
  public static func plan(media: [MediaVersion], roots: [String: URL], chapterTitle: String? = nil) -> [Self] {
    var result: [Self] = []
    var seen = Set<String>()
    for version in media {
      guard let root = roots[version.storageRootId] else { continue }
      for path in version.relativePaths {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { continue } // Never remove the storage root.
        parts.removeLast()
        let folder = parts.joined(separator: "/")
        if seen.insert(root.path + "/" + folder).inserted {
          result.append(Self(root: root, relativePath: folder))
        }
        if parts.count > 1, parts.last?.lowercased() == version.language.lowercased(),
          parts.dropLast().last == chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) {
          parts.removeLast()
          let chapter = parts.joined(separator: "/")
          if seen.insert(root.path + "/" + chapter).inserted {
            result.append(Self(root: root, relativePath: chapter))
          }
        }
      }
    }
    return result.sorted { $0.relativePath.split(separator: "/").count > $1.relativePath.split(separator: "/").count }
  }
  public static func removeEmpty(_ folders: [Self]) throws {
    for folder in folders.sorted(by: { $0.relativePath.split(separator: "/").count > $1.relativePath.split(separator: "/").count }) {
      let url = try PathPolicy.mutationPath(folder.relativePath, under: URL(fileURLWithPath: folder.root))
      if rmdir(url.path) != 0 {
        let code = errno
        if code != ENOENT && code != ENOTEMPTY && code != EEXIST {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
      }
    }
  }
}

public struct ArchiveFile: Sendable {
  public let root: URL
  public let rootId: String
  public let libraryId: String
  public let relativePath: String
  public init(root: URL, rootId: String, libraryId: String, relativePath: String) {
    self.root = root
    self.rootId = rootId
    self.libraryId = libraryId
    self.relativePath = relativePath
  }
}
public struct RecycleJournal: Codable, Sendable {
  public struct Entry: Codable, Sendable {
    public var root: String
    public var rootId: String
    public var libraryId: String
    public var source: String
    public var destination: String
    public var digest: String
    public var identity: FileIdentity? = nil
    public var publishedIdentity: FileIdentity? = nil
  }
  public var id: String
  public var entityId: String
  public var revision: Int
  public var phase: String
  public var entries: [Entry]
  public var cleanupFolders: [EmptyMediaFolder]? = nil
}
public enum FileRecycle {
  private static func validate(_ entry: RecycleJournal.Entry) throws -> URL {
    let root = URL(fileURLWithPath: entry.root)
    let marker = try PathPolicy.mutationPath(LibraryDestinationIdentity.filename, under: root)
    try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
      .validate(libraryId: entry.libraryId, destinationId: entry.rootId)
    return root
  }
  private static func validates(_ entries: [RecycleJournal.Entry]) throws -> [String: URL] {
    var roots: [String: URL] = [:]
    for entry in entries {
      let key = entry.root + "\0" + entry.rootId + "\0" + entry.libraryId
      if roots[key] == nil { roots[key] = try validate(entry) }
    }
    return roots
  }
  private static func verifies(_ entry: RecycleJournal.Entry, at url: URL,
    published: Bool, cancellable: Bool = true) throws -> Bool {
    if let identity = published ? entry.publishedIdentity ?? entry.identity : entry.identity {
      return try FileIdentity.read(url) == identity
    }
    guard !entry.digest.isEmpty else { throw StorageError.verificationFailed }
    return try FileInventory.digest(url, checkCancellation: cancellable) == entry.digest
  }
  private static func move(_ entry: RecycleJournal.Entry, from source: URL, to target: URL) throws {
    guard !FileManager.default.fileExists(atPath: target.path) else { throw StorageError.collision }
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if entry.identity != nil { try FileIdentity.renameExclusively(source, to: target) }
    else { try FileManager.default.moveItem(at: source, to: target) }
  }
  private static func write(_ journal: RecycleJournal, in directory: URL) throws {
    try JSONEncoder().encode(journal).write(
      to: directory.appendingPathComponent(journal.id + ".json"), options: .atomic)
  }
  public static func begin(
    entityId: String, revision: Int, files: [ArchiveFile], journalDirectory: URL,
    cleanupFolders: [EmptyMediaFolder] = []
  ) throws -> RecycleJournal {
    let fm = FileManager.default
    let id = UUID().uuidString
    var entries: [RecycleJournal.Entry] = []
    var seen = Set<String>()
    var devices: [String: UInt64] = [:]
    for file in files {
      try Task.checkCancellation()
      let root = file.root.standardizedFileURL
      guard seen.insert(root.path + "\0" + file.relativePath).inserted else { continue }
      let source = try PathPolicy.mutationPath(file.relativePath, under: root)
      if !fm.fileExists(atPath: source.path) { continue }
      guard
        try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile
          == true,
        try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
      else { throw StorageError.unsafePath }
      if devices[root.path] == nil { devices[root.path] = try FileIdentity.device(at: root) }
      let snapshot = try? FileIdentity.read(source)
      let sameVolume = snapshot?.device == devices[root.path]
      entries.append(RecycleJournal.Entry(
        root: root.path, rootId: file.rootId, libraryId: file.libraryId,
        source: file.relativePath, destination: "Recycle/" + id + "/" + file.relativePath,
        digest: sameVolume ? "" : try FileInventory.digest(source),
        identity: sameVolume ? snapshot : nil))
    }
    _ = try validates(entries)
    try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    var journal = RecycleJournal(
      id: id, entityId: entityId, revision: revision, phase: "prepared", entries: entries, cleanupFolders: cleanupFolders)
    try write(journal, in: journalDirectory)
    do {
      _ = try validates(entries)
      for index in journal.entries.indices {
        try Task.checkCancellation()
        let entry = journal.entries[index]
        let root = URL(fileURLWithPath: entry.root)
        let source = try PathPolicy.mutationPath(entry.source, under: root)
        let destination = try PathPolicy.mutationPath(entry.destination, under: root)
        guard try verifies(entry, at: source, published: false) else { throw StorageError.verificationFailed }
        try move(entry, from: source, to: destination)
        if let identity = entry.identity {
          let published = try FileIdentity.read(destination)
          guard published.device == identity.device, published.size == identity.size else {
            throw StorageError.verificationFailed
          }
          journal.entries[index].publishedIdentity = published
          // A NAS may change file IDs during rename; persist that proof immediately.
          if published != identity { try write(journal, in: journalDirectory) }
        }
      }
      journal.phase = "filesRecycled_metadataPending"
      try write(journal, in: journalDirectory)
      return journal
    } catch {
      do { try rollback(journal, in: journalDirectory) } catch {
        journal.phase = "rollbackRequired"
        try? write(journal, in: journalDirectory)
        throw StorageError.recycleRecoveryRequired
      }
      throw error
    }
  }
  public static func resume(_ journal: RecycleJournal, in directory: URL) throws -> RecycleJournal {
    let fm = FileManager.default
    _ = try validates(journal.entries)
    var pending = journal
    for index in pending.entries.indices {
      try Task.checkCancellation()
      let entry = pending.entries[index]
      let root = URL(fileURLWithPath: entry.root)
      let original = try PathPolicy.mutationPath(entry.source, under: root)
      let recycled = try PathPolicy.mutationPath(entry.destination, under: root)
      if fm.fileExists(atPath: recycled.path) {
        guard !fm.fileExists(atPath: original.path), try verifies(entry, at: recycled, published: true)
        else { throw StorageError.verificationFailed }
      } else {
        guard try verifies(entry, at: original, published: false) else { throw StorageError.verificationFailed }
        try move(entry, from: original, to: recycled)
        if let identity = entry.identity {
          let published = try FileIdentity.read(recycled)
          guard published.device == identity.device, published.size == identity.size else { throw StorageError.verificationFailed }
          pending.entries[index].publishedIdentity = published
          if published != identity { try write(pending, in: directory) }
        }
      }
    }
    pending.phase = "filesRecycled_metadataPending"
    try write(pending, in: directory)
    return pending
  }
  public static func rollback(_ journal: RecycleJournal, in directory: URL) throws {
    let fm = FileManager.default
    _ = try validates(journal.entries)
    for entry in journal.entries.reversed() {
      let root = URL(fileURLWithPath: entry.root)
      let original = try PathPolicy.mutationPath(entry.source, under: root)
      let recycled = try PathPolicy.mutationPath(entry.destination, under: root)
      if !fm.fileExists(atPath: recycled.path) { continue }
      guard !fm.fileExists(atPath: original.path) else { throw StorageError.collision }
      guard try verifies(entry, at: recycled, published: true, cancellable: false) else {
        throw StorageError.verificationFailed
      }
      try move(entry, from: recycled, to: original)
    }
    var complete = journal
    complete.phase = "rolledBack"
    try write(complete, in: directory)
  }
  public static func finish(_ journal: RecycleJournal, in directory: URL) throws {
    try EmptyMediaFolder.removeEmpty(journal.cleanupFolders ?? [])
    var complete = journal
    complete.phase = "complete"
    try write(complete, in: directory)
  }
}

/// A language correction keeps media identity, page order and text locales intact.
/// Only existing language-directory components change; hierarchy edits remain separate.
public struct MediaLanguageChangePlan: Sendable {
  public let mediaId: String
  public let fromLanguage: String
  public let toLanguage: String
  public let rootId: String
  public let sourceDirectory: String?
  public let destinationDirectory: String?
  public let metadata: MetadataInput
  public init(metadata: MetadataInput, mediaId: String, language: String) throws {
    guard metadata.kind == .chapter,
      let index = metadata.media.firstIndex(where: { $0.id == mediaId })
    else { throw StorageError.unsafePath }
    let media = metadata.media[index]
    let language = try PathPolicy.component(language)
    guard language != media.language else {
      throw MediaLanguageChangeError.unchanged
    }
    guard
      !metadata.media.contains(where: {
        $0.id != mediaId && $0.language.lowercased() == language.lowercased()
      })
    else { throw MediaLanguageChangeError.duplicateLanguage }
    self.mediaId = mediaId
    fromLanguage = media.language
    toLanguage = language
    rootId = media.storageRootId
    var updated = metadata
    updated.media[index].language = language
    if metadata.media.count > 1 {
      guard let first = media.relativePaths.first else { throw StorageError.emptyChapter }
      let parts = first.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 3, parts[parts.count - 2] == media.language else {
        throw MediaLanguageChangeError.unorganizedPaths
      }
      let source = parts.dropLast().joined(separator: "/")
      let destination = (parts.dropLast(2) + [language]).joined(separator: "/")
      updated.media[index].relativePaths = try media.relativePaths.map { path in
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(
          String.init)
        _ = try components.map(PathPolicy.component)
        guard components.dropLast().joined(separator: "/") == source else {
          throw MediaLanguageChangeError.unorganizedPaths
        }
        return destination + "/" + components.last!
      }
      sourceDirectory = source
      destinationDirectory = destination
    } else {
      // The storage rule omits language folders for a single media version.
      sourceDirectory = nil
      destinationDirectory = nil
    }
    self.metadata = updated
  }
}
public enum MediaLanguageChangeError: Error, LocalizedError {
  case unchanged, duplicateLanguage, unorganizedPaths
  public var errorDescription: String? {
    switch self {
    case .unchanged: return "Choose a different media language."
    case .duplicateLanguage: return "This chapter already has a media version in that language."
    case .unorganizedPaths:
      return "Organize this chapter into language folders before changing its media language."
    }
  }
}

/// One recoverable metadata commit for all language folders of a chapter.
/// Copies/links retain sources until metadata commits. Opt-in same-volume renames
/// publish directly; their persisted identity/intent allows recovery before metadata.
public struct OrganizationFile: Codable, Sendable {
  public var source: String
  public var relativePath: String
  public var keepSource: Bool
  public var digest = ""
  public var identity: FileIdentity? = nil
  public var allowRename: Bool? = nil
  /// Independent copies keep SHA verification, but source guards and later
  /// checkpoints can use the exact object instead of re-reading its bytes.
  public var copySourceIdentity: FileIdentity? = nil
  public var publishedCopyIdentity: FileIdentity? = nil
  public var phase = "pending"
  public init(source: URL, relativePath: String, keepSource: Bool) {
    self.source = source.path
    self.relativePath = relativePath
    self.keepSource = keepSource
  }
}
public struct OrganizationJournal: Codable, Sendable, Identifiable {
  public var id: String
  public var libraryId: String
  public var entityId: String
  public var revision: Int
  public var rootId: String
  public var root: String
  public var sourceRootIds: [String]
  public var metadata: MetadataInput
  /// Optional for journals written before media-only recovery was supported.
  public var originalMetadata: MetadataInput? = nil
  /// Retain the initial payload when recovery preserves a newer appended page.
  public var priorMetadata: MetadataInput? = nil
  public var files: [OrganizationFile]
  public var cleanupFolders: [EmptyMediaFolder]? = nil
  public var sourceBookmarks: [String: Data]? = nil
  public var destinationFolders: [String]? = nil
  public var phase: String

  /// A changed revision alone is not a file conflict. Never replace newer text or tags.
  public func recovery(current: MetadataInput, revision: Int) throws -> OrganizationRecovery {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    func equal<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
      try encoder.encode(lhs) == encoder.encode(rhs)
    }
    if try equal(current, metadata) { return .committed }
    // The server may have accepted the file references before a response was lost,
    // followed by an unrelated metadata edit. Finishing needs no metadata write.
    if current.kind == .chapter, !metadata.media.isEmpty,
      try equal(current.media, metadata.media) { return .committed }
    if revision == self.revision { return .update(metadata) }
    guard let originalMetadata else { return .conflict }
    var planned = originalMetadata
    planned.media = metadata.media
    guard try equal(planned, metadata) else { return .conflict }
    var protected = current
    protected.description = originalMetadata.description
    protected.localizations = originalMetadata.localizations
    protected.tagIds = originalMetadata.tagIds
    protected.nsfw = originalMetadata.nsfw
    protected.sources = originalMetadata.sources
    // Root/path/order, original title/language and parent changes still require review.
    guard try equal(protected, originalMetadata) else { return .conflict }
    var merged = current
    merged.media = metadata.media
    return .update(merged)
  }

  /// Old per-page translation commits can prove their baseline from the inverse of
  /// one appended cache image plus the journal's exact existing-file moves.
  /// This is deliberately unavailable to arbitrary old organization journals.
  public func recoveringLegacyImageAddition(current: MetadataInput, mediaId: String,
    language: String, canonical: Int, count: Int, cachedSource: URL,
    roots: [String: URL]) throws -> OrganizationJournal? {
    guard originalMetadata == nil, current.kind == .chapter, metadata.kind == .chapter,
      ["prepared", "copying", "filesReady_metadataPending"].contains(phase),
      let destination = roots[rootId], destination.standardizedFileURL.path == root,
      let targetIndex = metadata.media.firstIndex(where: { $0.id == mediaId }),
      (0..<count).contains(canonical) else { return nil }
    let target = metadata.media[targetIndex]
    guard target.kind == "images", target.language == language, target.storageRootId == rootId,
      target.pageCount == target.relativePaths.count, target.pageCount > 0,
      let alignment = target.pageAlignment, alignment.count == count,
      alignment[canonical] == target.pageCount - 1,
      alignment.filter({ $0 == target.pageCount - 1 }).count == 1,
      let addedPath = target.relativePaths.last else { return nil }
    let cached = cachedSource.standardizedFileURL.path
    let additions = files.indices.filter { files[$0].source == cached }
    guard additions.count == 1, let addition = additions.first,
      files[addition].keepSource, files[addition].relativePath == addedPath else { return nil }
    var expected = metadata.media
    expected[targetIndex].relativePaths.removeLast()
    expected[targetIndex].pageCount -= 1
    expected[targetIndex].pageAlignment?[canonical] = nil
    if expected[targetIndex].pageCount == 0 {
      guard targetIndex == expected.count - 1,
        expected[targetIndex].pageAlignment?.allSatisfy({ $0 == nil }) == true else { return nil }
      expected.remove(at: targetIndex)
    }
    guard current.media.map(\.id) == expected.map(\.id) else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var used: Set<Int> = [addition]
    var recovered = self
    for (existing, planned) in zip(current.media, expected) {
      guard sourceRootIds.contains(existing.storageRootId), let source = roots[existing.storageRootId],
        planned.storageRootId == rootId,
        existing.relativePaths.count >= planned.relativePaths.count
      else { return nil }
      var comparable = existing
      comparable.storageRootId = planned.storageRootId
      comparable.relativePaths = planned.relativePaths
      if existing.id == mediaId {
        let priorCount = planned.relativePaths.count
        // A stale snapshot may omit a just-committed earlier page. Preserve only
        // append-only additions, with every old canonical mapping unchanged.
        guard existing.pageCount == existing.relativePaths.count,
          existing.sourcePage(at: canonical) == nil,
          !existing.relativePaths.contains(addedPath),
          (existing.relativePaths.count == priorCount || existing.storageRootId == rootId),
          (existing.pageAlignment?.count ?? count) <= count,
          (0..<count).allSatisfy({ page in
            let old = planned.sourcePage(at: page)
            let actual = existing.sourcePage(at: page)
            return old != nil ? actual == old : actual == nil || actual! >= priorCount
          })
        else { return nil }
        comparable.pageCount = planned.pageCount
        comparable.pageAlignment = planned.pageAlignment
        let extra = Array(existing.relativePaths.dropFirst(priorCount))
        for path in extra {
          let preserved = try PathPolicy.mutationPath(path, under: destination)
          guard !files.contains(where: { !$0.keepSource && $0.source == preserved.path }) else { return nil }
        }
        var merged = existing
        merged.storageRootId = rootId
        merged.relativePaths = planned.relativePaths + extra + [addedPath]
        merged.pageCount = merged.relativePaths.count
        merged.pageAlignment = (0..<count).map {
          $0 == canonical ? existing.relativePaths.count : existing.sourcePage(at: $0)
        }
        recovered.metadata.media[targetIndex] = merged
      } else if existing.relativePaths.count != planned.relativePaths.count {
        return nil
      }
      guard try encoder.encode(comparable) == encoder.encode(planned) else { return nil }
      for (before, after) in zip(existing.relativePaths, planned.relativePaths) {
        let sourcePath = try PathPolicy.mutationPath(before, under: source).path
        let targetPath = try PathPolicy.mutationPath(after, under: destination).path
        let moves = files.indices.filter { files[$0].relativePath == after }
        if sourcePath == targetPath {
          guard moves.isEmpty else { return nil }
        } else {
          guard moves.count == 1, let move = moves.first, move != addition,
            files[move].source == sourcePath else { return nil }
          used.insert(move)
        }
      }
    }
    // Do not adopt unrelated, duplicate, or unexplained file operations.
    guard used.count == files.count else { return nil }
    for file in files {
      guard !file.digest.isEmpty,
        try FileInventory.digest(URL(fileURLWithPath: file.source)) == file.digest
      else { throw StorageError.verificationFailed }
    }
    var baseline = recovered.metadata
    baseline.media = current.media
    recovered.originalMetadata = baseline
    // Bypass the unchanged-revision shortcut: folder-defining fields must match too.
    guard case .update = try recovered.recovery(current: current, revision: revision + 1)
    else { return nil }
    return recovered
  }
}
public enum OrganizationRecovery: Sendable {
  case committed, update(MetadataInput), conflict
}
public enum FileOrganization {
  private static func save(_ journal: OrganizationJournal, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(journal).write(
      to: directory.appendingPathComponent(journal.id + ".json"), options: .atomic)
  }
  public static func read(_ id: String, in directory: URL) throws -> OrganizationJournal {
    try JSONDecoder().decode(
      OrganizationJournal.self,
      from: Data(contentsOf: directory.appendingPathComponent(id + ".json")))
  }
  /// Persist a proven recovery payload before its revision-checked metadata write.
  public static func recordRecovery(
    _ initial: OrganizationJournal,
    recovered: OrganizationJournal, in directory: URL
  ) throws -> OrganizationJournal {
    var stored = try read(initial.id, in: directory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard try encoder.encode(stored) == encoder.encode(initial),
      stored.originalMetadata == nil, recovered.originalMetadata != nil,
      ["prepared", "copying", "filesReady_metadataPending"].contains(stored.phase)
    else { throw StorageError.verificationFailed }
    if try encoder.encode(stored.metadata) != encoder.encode(recovered.metadata) {
      stored.priorMetadata = stored.priorMetadata ?? stored.metadata
    }
    stored.originalMetadata = recovered.originalMetadata
    stored.metadata = recovered.metadata
    try save(stored, in: directory)
    return stored
  }
  public static func prepare(
    entityId: String, revision: Int, metadata: MetadataInput,
    libraryId: String, rootId: String, root: URL, sourceRootIds: [String],
    files: [OrganizationFile], directory: URL, cleanupFolders: [EmptyMediaFolder] = [],
    sourceBookmarks: [String: Data] = [:], originalMetadata: MetadataInput? = nil,
    preferLinks: Bool = true, allowRename: Bool = false, destinationFolders: [String] = []
  ) throws -> OrganizationJournal {
    try JSONDecoder().decode(
      LibraryDestinationIdentity.self,
      from: Data(contentsOf: PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root))
    )
    .validate(libraryId: libraryId, destinationId: rootId)
    var files = files
    var destinations = Set<String>()
    let device = try FileIdentity.device(at: root)
    for index in files.indices {
      try Task.checkCancellation()
      files[index].identity = nil
      files[index].allowRename = nil
      let target = try PathPolicy.mutationPath(files[index].relativePath, under: root)
      guard destinations.insert(target.path.lowercased()).inserted,
        !FileManager.default.fileExists(atPath: target.path)
      else { throw StorageError.collision }
      let source = URL(fileURLWithPath: files[index].source)
      if preferLinks, !files[index].keepSource, let identity = try? FileIdentity.read(source),
        identity.device == device
      {
        files[index].identity = identity
        files[index].allowRename = allowRename && originalMetadata != nil
        continue
      }
      let fingerprint = try copyFingerprint(source)
      files[index].copySourceIdentity = fingerprint.identity
      files[index].digest = fingerprint.digest
    }
    for path in destinationFolders { _ = try PathPolicy.mutationPath(path, under: root) }
    var journal = OrganizationJournal(
      id: UUID().uuidString, libraryId: libraryId,
      entityId: entityId, revision: revision, rootId: rootId, root: root.path,
      sourceRootIds: sourceRootIds, metadata: metadata, originalMetadata: originalMetadata,
      files: files, cleanupFolders: cleanupFolders, sourceBookmarks: sourceBookmarks,
      phase: "prepared")
    journal.destinationFolders = destinationFolders
    try save(journal, in: directory)
    return journal
  }
  /// SMB servers can advance mtime when a read flushes a recently written file.
  /// Require two matching byte inventories in that case, rather than rejecting
  /// unchanged content or trusting a timestamp-only refresh for an independent copy.
  static func copyFingerprint(_ source: URL,
    inventory: (URL) throws -> FileInventory = { try FileInventory.read($0) }
  ) throws -> (digest: String, identity: FileIdentity?) {
    let before = try? FileIdentity.read(source)
    let contents = try inventory(source)
    guard !contents.directory, let digest = contents.entries.first?.digest else {
      throw StorageError.unsupportedMove
    }
    var after = try? FileIdentity.read(source)
    if let before, after != before {
      guard let changed = after, changed.device == before.device,
        changed.inode == before.inode, changed.size == before.size,
        try inventory(source) == contents
      else { throw StorageError.verificationFailed }
      after = try? FileIdentity.read(source)
      guard let final = after, final.device == before.device,
        final.inode == before.inode, final.size == before.size
      else { throw StorageError.verificationFailed }
    }
    return (digest, after)
  }

  public static func stage(
    _ initial: OrganizationJournal, in directory: URL,
    progress: @Sendable (Double) -> Void = { _ in },
    link: @Sendable (URL, URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) }
  ) throws -> OrganizationJournal {
    var journal = try read(initial.id, in: directory)
    guard ["prepared", "copying", "filesReady_metadataPending"].contains(journal.phase) else {
      throw StorageError.unsafePath
    }
    let root = URL(fileURLWithPath: journal.root)
    try JSONDecoder().decode(
      LibraryDestinationIdentity.self,
      from: Data(contentsOf: PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root))
    )
    .validate(libraryId: journal.libraryId, destinationId: journal.rootId)
    journal.phase = "copying"
    // Persist publication intent for fast entries together. Each target must
    // still be absent before its first attempt; resume verifies its exact inode.
    for index in journal.files.indices
    where journal.files[index].identity != nil
      && journal.files[index].phase == "pending"
    {
      let target = try PathPolicy.mutationPath(journal.files[index].relativePath, under: root)
      guard !FileManager.default.fileExists(atPath: target.path) else {
        throw StorageError.collision
      }
      journal.files[index].phase = "copying"
    }
    try save(journal, in: directory)
    var linksUnsupported = false
    for path in journal.destinationFolders ?? [] {
      try FileManager.default.createDirectory(
        at: PathPolicy.mutationPath(path, under: root),
        withIntermediateDirectories: true)
    }
    for index in journal.files.indices {
      try Task.checkCancellation()
      var entry = journal.files[index]
      let source = URL(fileURLWithPath: entry.source)
      let target = try PathPolicy.mutationPath(entry.relativePath, under: root)
      if FileManager.default.fileExists(atPath: target.path) {
        // Only a file which this journal began publishing can be resumed.
        guard entry.phase != "pending", try verifies(entry, at: target) else {
          throw StorageError.collision
        }
      } else {
        if entry.allowRename == true, let identity = entry.identity {
          let current = try FileIdentity.read(source)
          guard current.device == identity.device, current.inode == identity.inode,
            current.size == identity.size
          else { throw StorageError.verificationFailed }
          // A move preserves the current file object. Some NAS access/metadata
          // operations advance mtime without replacing it; freeze its current
          // timestamp only when staging starts, then verify published identities strictly.
          if current != identity {
            entry.identity = current
            journal.files[index] = entry
            try save(journal, in: directory)
          }
        } else {
          guard try verifiesSource(entry, at: source) else { throw StorageError.verificationFailed }
        }
        // A missing published copy may be recreated only from the unchanged
        // source. Its new temporary file must still pass the stored SHA.
        entry.publishedCopyIdentity = nil
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
          ".mangareader-" + journal.id + "-" + String(index))
        if FileManager.default.fileExists(atPath: temporary.path) {
          try FileManager.default.removeItem(at: temporary)
        }
        do {
          if entry.identity != nil {
            do {
              if linksUnsupported { throw StorageError.unsupportedMove }
              try link(source, temporary)
            } catch {
              // Some SMB servers/filesystems do not implement hard links.
              // Only explicit plans with an original snapshot may rename.
              // Other callers retain the existing verified-copy behavior.
              try Task.checkCancellation()
              if FileManager.default.fileExists(atPath: temporary.path) { throw error }
              linksUnsupported = true
              if entry.allowRename == true {
                // Intent was saved before any source changes. An interrupted
                // metadata write is resumed from the published exact inode.
                try FileIdentity.renameExclusively(source, to: target)
                let published = try FileIdentity.read(target)
                guard let original = entry.identity, published.device == original.device,
                  published.size == original.size
                else { throw StorageError.verificationFailed }
                // SMB may change inodes and timestamps during rename. The successful rename preserves the bytes;
                // persist its published identity immediately for later recovery.
                entry.identity = published
                journal.files[index] = entry
                journal.files[index].phase = "copied"
                try save(journal, in: directory)
                progress(Double(index + 1) / Double(max(1, journal.files.count)))
                continue
              }
              entry.identity = nil
              let fingerprint = try copyFingerprint(source)
              entry.copySourceIdentity = fingerprint.identity
              entry.digest = fingerprint.digest
              journal.files[index] = entry
              try save(journal, in: directory)
            }
          }
          if entry.identity == nil {
            entry.phase = "copying"
            journal.files[index] = entry
            try save(journal, in: directory)
            try FileManager.default.copyItem(at: source, to: temporary)
          }
          guard try verifies(entry, at: temporary), try verifiesSource(entry, at: source)
          else { throw StorageError.verificationFailed }
          try Task.checkCancellation()
          try FileManager.default.moveItem(at: temporary, to: target)
          if entry.identity == nil { entry.publishedCopyIdentity = try? FileIdentity.read(target) }
        } catch {
          try? FileManager.default.removeItem(at: temporary)
          throw error
        }
      }
      entry.phase = "copied"
      journal.files[index] = entry
      if entry.identity == nil || index % 32 == 31 { try save(journal, in: directory) }
      progress(Double(index + 1) / Double(max(1, journal.files.count)))
    }
    journal.phase = "filesReady_metadataPending"
    try save(journal, in: directory)
    return journal
  }
  private static func verifiesSource(_ entry: OrganizationFile, at url: URL) throws -> Bool {
    if let identity = entry.copySourceIdentity,
      (try? FileIdentity.read(url)) == identity { return true }
    if let identity = entry.identity { return try FileIdentity.read(url) == identity }
    guard !entry.digest.isEmpty else { return false }
    return try FileInventory.digest(url) == entry.digest
  }
  private static func verifies(_ entry: OrganizationFile, at url: URL) throws -> Bool {
    if let published = entry.publishedCopyIdentity,
      (try? FileIdentity.read(url)) == published { return true }
    if let identity = entry.identity { return try FileIdentity.read(url) == identity }
    guard !entry.digest.isEmpty else { return false }
    return try FileInventory.digest(url) == entry.digest
  }
  /// Call only after the chapter's metadata has been confirmed committed.
  public static func finish(_ initial: OrganizationJournal, in directory: URL) throws {
    var journal = try read(initial.id, in: directory)
    if journal.phase == "complete" { return }
    guard ["filesReady_metadataPending", "metadataCommitted"].contains(journal.phase) else {
      throw StorageError.unsafePath
    }
    let root = URL(fileURLWithPath: journal.root)
    try JSONDecoder().decode(
      LibraryDestinationIdentity.self,
      from: Data(contentsOf: PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root))
    )
    .validate(libraryId: journal.libraryId, destinationId: journal.rootId)
    for entry in journal.files {
      guard
        try verifies(entry, at: PathPolicy.mutationPath(entry.relativePath, under: root))
      else { throw StorageError.verificationFailed }
      let source = URL(fileURLWithPath: entry.source)
      if !entry.keepSource, FileManager.default.fileExists(atPath: source.path) {
        guard try verifiesSource(entry, at: source) else {
          throw StorageError.verificationFailed
        }
      }
    }
    journal.phase = "metadataCommitted"
    try save(journal, in: directory)
    for entry in journal.files where !entry.keepSource {
      let source = URL(fileURLWithPath: entry.source)
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.removeItem(at: source)
      }
    }
    try EmptyMediaFolder.removeEmpty(journal.cleanupFolders ?? [])
    journal.phase = "complete"
    try save(journal, in: directory)
  }
}
