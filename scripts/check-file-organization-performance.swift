import Foundation
import MangaCore

// Synthetic files only. The optional argument is a parent directory, e.g. a mounted SMB share.
// Never opens existing media, contacts the API, or writes production queue state.
@main enum OrganizationPerformanceCheck {
  static func main() {
    do { try run() } catch { print("Benchmark failed: \(error)"); exit(1) }
  }
  static func run() throws {
    let parent = URL(
      fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
    let directory = parent.appendingPathComponent(
      ".mangareader-organization-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalBase = FileManager.default.temporaryDirectory.appendingPathComponent("organization-benchmark-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: journalBase) }
    let bytes = Data(repeating: 0x42, count: 2 * 1024 * 1024)
    var durations: [String: Double] = [:]
    for fast in [true, false] {
      let root = directory.appendingPathComponent(fast ? "fast" : "copy")
      let incoming = root.appendingPathComponent("Chapter")
      try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
      try LibraryDestinationIdentity.bind(
        folder: root, libraryId: "synthetic", destinationId: "root")
      let paths = (0..<12).map { "Chapter/\($0).png" }
      for path in paths {
        let url = root.appendingPathComponent(path)
        try bytes.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
      }
      // Let newly generated SMB write attributes settle before timing organization.
      Thread.sleep(forTimeInterval: 0.5)
      let original = MetadataInput(
        kind: .chapter, title: "Chapter",
        media: [
          .init(
            language: "ja", kind: "images", storageRootId: "root", relativePaths: paths,
            pageCount: paths.count)
        ])
      let files = paths.map {
        OrganizationFile(
          source: root.appendingPathComponent($0),
          relativePath: "Chapter/ja/" + ($0 as NSString).lastPathComponent, keepSource: false)
      }
      var desired = original
      desired.media[0].relativePaths = files.map(\.relativePath)
      let journals = journalBase.appendingPathComponent(fast ? "fast" : "copy")
      let start = Date()
      do {
        let prepared = try FileOrganization.prepare(
          entityId: "chapter", revision: 1, metadata: desired,
          libraryId: "synthetic", rootId: "root", root: root, sourceRootIds: ["root"],
          files: files, directory: journals, originalMetadata: original, preferLinks: fast,
          allowRename: fast)
        let staged = try FileOrganization.stage(prepared, in: journals)
        try FileOrganization.finish(staged, in: journals)
        let duration = Date().timeIntervalSince(start)
        for file in files {
          guard try Data(contentsOf: root.appendingPathComponent(file.relativePath)) == bytes,
            !FileManager.default.fileExists(atPath: file.source)
          else { throw StorageError.verificationFailed }
        }
        guard try FileOrganization.read(staged.id, in: journals).phase == "complete" else {
          throw StorageError.verificationFailed
        }
        durations[fast ? "fast_seconds" : "copy_seconds"] = duration
      } catch {
        print("\(fast ? "Fast path" : "Copy path") failed: \(error.localizedDescription)")
      }
    }
    print("Synthetic: 12 files, 24 MiB. Successful paths verified every byte and the completed journal.")
    if let copy = durations["copy_seconds"], let fast = durations["fast_seconds"] {
      print(
        String(
          format: "Copy + SHA: %.3fs; same-volume organization: %.3fs; speedup: %.2fx", copy, fast,
          copy / fast))
    } else {
      print(durations)
    }
    guard durations["fast_seconds"] != nil else { throw StorageError.verificationFailed }
  }
}
