import CryptoKit
import Foundation

public enum StorageError: Error, LocalizedError {
  case unsafePath, collision, unsupportedMove, emptyChapter, verificationFailed,
    recycleRecoveryRequired
  public var errorDescription: String? {
    switch self {
    case .unsafePath: return "The path is outside the selected storage root."
    case .collision: return "The destination already exists. No files were overwritten."
    case .unsupportedMove: return "This file type cannot be moved."
    case .verificationFailed:
      return "Files changed or the copy could not be verified. The original files were kept."
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
    let resolved = try resolve(path, under: root)
    var url = root
    for component in path.split(separator: "/") {
      url.appendPathComponent(String(component))
      if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw StorageError.unsafePath
      }
    }
    return resolved
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
      guard ext == "pdf" || ext == "webm" || ext == "mp4" else { throw StorageError.emptyChapter }
      return [
        .init(
          source: url, title: url.deletingPathExtension().lastPathComponent,
          kind: ext == "pdf" ? "pdf" : "video", pages: [url], warnings: [])
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
  }
  public var id: String
  public var entityId: String
  public var revision: Int
  public var phase: String
  public var entries: [Entry]
}
public enum FileRecycle {
  private static func validate(_ entry: RecycleJournal.Entry) throws -> URL {
    let root = URL(fileURLWithPath: entry.root)
    let marker = try PathPolicy.mutationPath(LibraryDestinationIdentity.filename, under: root)
    try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
      .validate(libraryId: entry.libraryId, destinationId: entry.rootId)
    return root
  }
  private static func write(_ journal: RecycleJournal, in directory: URL) throws {
    try JSONEncoder().encode(journal).write(
      to: directory.appendingPathComponent(journal.id + ".json"), options: .atomic)
  }
  public static func begin(
    entityId: String, revision: Int, files: [ArchiveFile], journalDirectory: URL
  ) throws -> RecycleJournal {
    let fm = FileManager.default
    let id = UUID().uuidString
    var entries: [RecycleJournal.Entry] = []
    var seen = Set<String>()
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
      let entry = RecycleJournal.Entry(
        root: root.path, rootId: file.rootId, libraryId: file.libraryId,
        source: file.relativePath, destination: "Recycle/" + id + "/" + file.relativePath,
        digest: try FileInventory.digest(source))
      _ = try validate(entry)
      entries.append(entry)
    }
    try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    var journal = RecycleJournal(
      id: id, entityId: entityId, revision: revision, phase: "prepared", entries: entries)
    try write(journal, in: journalDirectory)
    do {
      for entry in entries {
        try Task.checkCancellation()
        let root = try validate(entry)
        let source = try PathPolicy.mutationPath(entry.source, under: root)
        let destination = try PathPolicy.mutationPath(entry.destination, under: root)
        guard try FileInventory.digest(source) == entry.digest else {
          throw StorageError.verificationFailed
        }
        try fm.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
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
    for entry in journal.entries {
      try Task.checkCancellation()
      let root = try validate(entry)
      let original = try PathPolicy.mutationPath(entry.source, under: root)
      let recycled = try PathPolicy.mutationPath(entry.destination, under: root)
      if fm.fileExists(atPath: recycled.path) {
        guard !fm.fileExists(atPath: original.path),
          try FileInventory.digest(recycled) == entry.digest
        else { throw StorageError.verificationFailed }
      } else {
        guard try FileInventory.digest(original) == entry.digest else {
          throw StorageError.verificationFailed
        }
        try fm.createDirectory(
          at: recycled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: original, to: recycled)
      }
    }
    var pending = journal
    pending.phase = "filesRecycled_metadataPending"
    try write(pending, in: directory)
    return pending
  }
  public static func rollback(_ journal: RecycleJournal, in directory: URL) throws {
    let fm = FileManager.default
    for entry in journal.entries.reversed() {
      let root = try validate(entry)
      let original = try PathPolicy.mutationPath(entry.source, under: root)
      let recycled = try PathPolicy.mutationPath(entry.destination, under: root)
      if !fm.fileExists(atPath: recycled.path) { continue }
      guard !fm.fileExists(atPath: original.path) else { throw StorageError.collision }
      guard try FileInventory.digest(recycled, checkCancellation: false) == entry.digest else {
        throw StorageError.verificationFailed
      }
      try fm.createDirectory(
        at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.moveItem(at: recycled, to: original)
    }
    var complete = journal
    complete.phase = "rolledBack"
    try write(complete, in: directory)
  }
  public static func finish(_ journal: RecycleJournal, in directory: URL) throws {
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
/// Sources stay readable until every new file has been verified and metadata commits.
public struct OrganizationFile: Codable, Sendable {
  public var source: String
  public var relativePath: String
  public var keepSource: Bool
  public var digest = ""
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
  public var files: [OrganizationFile]
  public var phase: String
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
  public static func prepare(
    entityId: String, revision: Int, metadata: MetadataInput,
    libraryId: String, rootId: String, root: URL, sourceRootIds: [String],
    files: [OrganizationFile], directory: URL
  ) throws -> OrganizationJournal {
    try JSONDecoder().decode(
      LibraryDestinationIdentity.self,
      from: Data(contentsOf: PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root))
    )
    .validate(libraryId: libraryId, destinationId: rootId)
    var files = files
    var destinations = Set<String>()
    for index in files.indices {
      let target = try PathPolicy.mutationPath(files[index].relativePath, under: root)
      guard destinations.insert(target.path.lowercased()).inserted,
        !FileManager.default.fileExists(atPath: target.path)
      else { throw StorageError.collision }
      let inventory = try FileInventory.read(URL(fileURLWithPath: files[index].source))
      guard !inventory.directory, let digest = inventory.entries.first?.digest else {
        throw StorageError.unsupportedMove
      }
      files[index].digest = digest
    }
    let journal = OrganizationJournal(
      id: UUID().uuidString, libraryId: libraryId,
      entityId: entityId, revision: revision, rootId: rootId, root: root.path,
      sourceRootIds: sourceRootIds, metadata: metadata, files: files, phase: "prepared")
    try save(journal, in: directory)
    return journal
  }
  public static func stage(
    _ initial: OrganizationJournal, in directory: URL,
    progress: @Sendable (Double) -> Void = { _ in }
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
    try save(journal, in: directory)
    for index in journal.files.indices {
      try Task.checkCancellation()
      let entry = journal.files[index]
      let source = URL(fileURLWithPath: entry.source)
      let target = try PathPolicy.mutationPath(entry.relativePath, under: root)
      if FileManager.default.fileExists(atPath: target.path) {
        // Only a file which this journal began publishing can be resumed.
        guard entry.phase != "pending", try FileInventory.digest(target) == entry.digest else {
          throw StorageError.collision
        }
      } else {
        guard try FileInventory.read(source).entries.first?.digest == entry.digest else {
          throw StorageError.verificationFailed
        }
        journal.files[index].phase = "copying"
        try save(journal, in: directory)
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
          ".mangareader-" + journal.id + "-" + String(index))
        if FileManager.default.fileExists(atPath: temporary.path) {
          try FileManager.default.removeItem(at: temporary)
        }
        do {
          try FileManager.default.copyItem(at: source, to: temporary)
          guard try FileInventory.digest(temporary) == entry.digest,
            try FileInventory.digest(source) == entry.digest
          else { throw StorageError.verificationFailed }
          try Task.checkCancellation()
          try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
          try? FileManager.default.removeItem(at: temporary)
          throw error
        }
      }
      journal.files[index].phase = "copied"
      try save(journal, in: directory)
      progress(Double(index + 1) / Double(max(1, journal.files.count)))
    }
    journal.phase = "filesReady_metadataPending"
    try save(journal, in: directory)
    return journal
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
        try FileInventory.digest(PathPolicy.mutationPath(entry.relativePath, under: root))
          == entry.digest
      else { throw StorageError.verificationFailed }
      let source = URL(fileURLWithPath: entry.source)
      if !entry.keepSource, FileManager.default.fileExists(atPath: source.path) {
        guard try FileInventory.read(source).entries.first?.digest == entry.digest else {
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
    journal.phase = "complete"
    try save(journal, in: directory)
  }
}
