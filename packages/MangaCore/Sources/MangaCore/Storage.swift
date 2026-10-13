import CryptoKit
import Foundation

public enum StorageError: Error, LocalizedError {
  case unsafePath, collision, unsupportedMove, emptyChapter
  public var errorDescription: String? {
    switch self {
    case .unsafePath: return "The path is outside the selected storage root."
    case .collision: return "The destination already exists. No files were overwritten."
    case .unsupportedMove:
      return "This initial mover requires source and destination on the same volume."
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
public struct MoveJournal: Codable, Sendable {
  public var id: String
  public var source: String
  public var destination: String
  public var phase: String
}
public enum FileCommit {
  /// Journals a single same-volume atomic filesystem rename. Never overwrites or follows escaping symlinks.
  public static func move(
    source: URL, destinationRelativePath: String, root: URL, journalDirectory: URL,
    recoveryPayload: Data? = nil
  ) throws -> MoveJournal {
    let fm = FileManager.default
    let destination = try PathPolicy.resolve(destinationRelativePath, under: root)
    let source = source.resolvingSymlinksInPath().standardizedFileURL
    guard source != root.resolvingSymlinksInPath(), !destination.path.hasPrefix(source.path + "/")
    else { throw StorageError.unsafePath }
    guard !fm.fileExists(atPath: destination.path) else { throw StorageError.collision }
    let sourceVolume = try source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    let rootVolume = try root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    guard String(describing: sourceVolume) == String(describing: rootVolume) else {
      throw StorageError.unsupportedMove
    }
    try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    var journal = MoveJournal(
      id: UUID().uuidString, source: source.path, destination: destination.path, phase: "prepared")
    let journalURL = journalDirectory.appendingPathComponent(journal.id + ".json")
    try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    if let recoveryPayload {
      try recoveryPayload.write(
        to: journalDirectory.appendingPathComponent(journal.id + "-metadata.json"), options: .atomic
      )
    }
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard !fm.fileExists(atPath: destination.path) else { throw StorageError.collision }
    try fm.moveItem(at: source, to: destination)
    journal.phase = "filesMoved_metadataPending"
    try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    return journal
  }
  public static func finish(_ journal: MoveJournal, in directory: URL) throws {
    var j = journal
    j.phase = "complete"
    try JSONEncoder().encode(j).write(
      to: directory.appendingPathComponent(j.id + ".json"), options: .atomic)
  }
}
