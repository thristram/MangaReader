import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Verifies a same-volume link or rename without reading media bytes over SMB.
public struct FileIdentity: Codable, Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let size: Int64
  public let modifiedSeconds: Int64
  public let modifiedNanoseconds: Int64
  private static func info(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return value
  }
  public static func device(at url: URL) throws -> UInt64 {
    UInt64(truncatingIfNeeded: try info(url).st_dev)
  }
  public static func read(_ url: URL) throws -> Self {
    let value = try info(url)
    guard UInt32(value.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG), value.st_ino != 0 else {
      throw StorageError.unsupportedMove
    }
    #if canImport(Darwin)
      let modified = value.st_mtimespec
    #else
      let modified = value.st_mtim
    #endif
    return Self(
      device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino),
      size: Int64(value.st_size), modifiedSeconds: Int64(modified.tv_sec),
      modifiedNanoseconds: Int64(modified.tv_nsec))
  }
  static func renameExclusively(_ source: URL, to target: URL) throws {
    #if canImport(Darwin)
      if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
      let code = errno
      guard code == ENOTSUP || code == EINVAL else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
      }
      // Finder-mounted SMB can support rename but not RENAME_EXCL. Foundation's
      // move fallback may copy the bytes. Coordinate both paths and recheck the
      // destination before issuing an ordinary same-volume rename instead.
      let coordinator = NSFileCoordinator()
      var coordinationError: NSError?
      var operationError: Error?
      coordinator.coordinate(
        writingItemAt: source, options: .forMoving,
        writingItemAt: target, options: [], error: &coordinationError
      ) { before, after in
        do {
          guard !FileManager.default.fileExists(atPath: after.path) else {
            throw StorageError.collision
          }
          guard rename(before.path, after.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
          }
        } catch { operationError = error }
      }
      if let error = coordinationError ?? operationError as NSError? { throw error }
    #else
      // Foundation preserves collision errors. The caller has already checked st_dev.
      try FileManager.default.moveItem(at: source, to: target)
    #endif
  }
}
