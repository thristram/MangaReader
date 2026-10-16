import Foundation

/// Resolves Finder's decomposed Unicode names against a direct SMB directory listing.
/// It never guesses a similar title or searches outside the configured share/base folder.
public enum SMBReadPath {
  public struct Entry: Sendable {
    public let name: String
    public let directory: Bool
    public init(name: String, directory: Bool) {
      self.name = name
      self.directory = directory
    }
  }
  public enum Failure: LocalizedError {
    case missing(String), ambiguous(String)
    public var errorDescription: String? {
      switch self {
      case .missing(let path):
        return
          "The NAS could not find ‘\(path)’. Check this device’s share and library folder in Connections."
      case .ambiguous(let path):
        return "More than one NAS filename matches ‘\(path)’. Rename the duplicate on your Mac."
      }
    }
  }
  public static func components(_ path: String) throws -> [String] {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
      throw StorageError.unsafePath
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw StorageError.unsafePath
    }
    // Keep the same component rules as local storage without touching the local filesystem.
    for part in parts { _ = try PathPolicy.component(part) }
    return parts
  }
  public static func resolve(
    _ path: String, under basePath: String = "", list: @Sendable (String) async throws -> [Entry]
  ) async throws -> String {
    let parts = try components(path)
    var resolved = basePath.isEmpty ? [] : try components(basePath)
    for (index, part) in parts.enumerated() {
      try Task.checkCancellation()
      let entries = try await list(resolved.isEmpty ? "/" : resolved.joined(separator: "/"))
      // Swift String equality normalizes Unicode. Compare UTF-8 for an exact NAS name first.
      let eligible = entries.filter { index == parts.count - 1 || $0.directory }
      let exact = eligible.filter { $0.name.utf8.elementsEqual(part.utf8) }
      let matches = exact.isEmpty ? eligible.filter { $0.name == part } : exact
      guard matches.count == 1 else {
        if matches.isEmpty { throw Failure.missing(path) }
        throw Failure.ambiguous(path)
      }
      let name = matches[0].name
      guard try components(name).count == 1 else { throw StorageError.unsafePath }
      resolved.append(name)
    }
    return resolved.joined(separator: "/")
  }
}
