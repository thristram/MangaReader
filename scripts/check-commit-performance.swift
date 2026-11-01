import Foundation
import MangaCore

// Synthetic-only comparison. Old SHA journals replay the former verification
// workload; both paths retain current path/account/collision checks.
@main enum CommitPerformanceCheck {
  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data(("Benchmark failed: " + String(describing: error) + "\n").utf8))
      exit(1)
    }
  }
  static func run() throws {
    let fm = FileManager.default
    let parent = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
    let scratch = parent.appendingPathComponent(".mangareader-commit-check-" + UUID().uuidString)
    let journals = fm.temporaryDirectory.appendingPathComponent("commit-check-journals-" + UUID().uuidString)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch); try? fm.removeItem(at: journals) }
    let bytes = Data(repeating: 0x53, count: 2 * 1024 * 1024)
    print("Synthetic fixture: 8 × 2 MiB. Timings exclude fixture generation and final byte comparisons.")
    var failed = false
    for operation in ["copy", "recycle"] {
      var times: [Double] = []
      for legacy in [true, false] {
        let label = operation + (legacy ? "-legacy-sha" : "-optimized")
        do {
          let root = scratch.appendingPathComponent(label)
          try fm.createDirectory(at: root.appendingPathComponent("Chapter"), withIntermediateDirectories: true)
          try LibraryDestinationIdentity.bind(folder: root, libraryId: "synthetic", destinationId: "root")
          let paths = (0..<8).map { "Chapter/\($0).png" }
          for path in paths { try bytes.write(to: root.appendingPathComponent(path)) }
          let directory = journals.appendingPathComponent(label)
          try fm.createDirectory(at: directory, withIntermediateDirectories: true)
          FileHandle.standardError.write(Data(("Starting " + label + "\n").utf8))
          let start = Date()
          let outputs: [URL]
          if operation == "copy" {
            let files = paths.map { OrganizationFile(source: root.appendingPathComponent($0), relativePath: "Added/" + ($0 as NSString).lastPathComponent, keepSource: true) }
            var plan = try FileOrganization.prepare(entityId: "chapter", revision: 1,
              metadata: MetadataInput(kind: .chapter, title: "Chapter"), libraryId: "synthetic", rootId: "root", root: root,
              sourceRootIds: ["root"], files: files, directory: directory)
            if legacy {
              for index in plan.files.indices { plan.files[index].copySourceIdentity = nil }
              try JSONEncoder().encode(plan).write(to: directory.appendingPathComponent(plan.id + ".json"), options: .atomic)
            }
            var staged = try FileOrganization.stage(plan, in: directory)
            if legacy {
              for index in staged.files.indices { staged.files[index].publishedCopyIdentity = nil }
              try JSONEncoder().encode(staged).write(to: directory.appendingPathComponent(plan.id + ".json"), options: .atomic)
            }
            try FileOrganization.finish(staged, in: directory)
            outputs = files.map { root.appendingPathComponent($0.relativePath) }
          } else {
            let journal: RecycleJournal
            if legacy {
              let id = UUID().uuidString
              let entries = try paths.map { path -> [String: Any] in
                ["root": root.path, "rootId": "root", "libraryId": "synthetic", "source": path,
                 "destination": "Recycle/" + id + "/" + path, "digest": try FileInventory.digest(root.appendingPathComponent(path))]
              }
              let data = try JSONSerialization.data(withJSONObject: ["id": id, "entityId": "chapter", "revision": 1, "phase": "prepared", "entries": entries])
              try data.write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
              journal = try FileRecycle.resume(JSONDecoder().decode(RecycleJournal.self, from: data), in: directory)
            } else {
              journal = try FileRecycle.begin(entityId: "chapter", revision: 1,
                files: paths.map { ArchiveFile(root: root, rootId: "root", libraryId: "synthetic", relativePath: $0) }, journalDirectory: directory)
              guard journal.entries.allSatisfy({ $0.identity != nil && $0.digest.isEmpty }) else { throw StorageError.verificationFailed }
            }
            try FileRecycle.finish(journal, in: directory)
            outputs = journal.entries.map { root.appendingPathComponent($0.destination) }
          }
          let duration = Date().timeIntervalSince(start)
          for url in outputs { guard try Data(contentsOf: url) == bytes else { throw StorageError.verificationFailed } }
          for path in paths {
            guard fm.fileExists(atPath: root.appendingPathComponent(path).path) == (operation == "copy") else { throw StorageError.verificationFailed }
          }
          times.append(duration)
          print(String(format: "%@: %.3f s; byte verification passed", label, duration))
        } catch {
          failed = true
          FileHandle.standardError.write(Data((label + " FAILED: " + String(describing: error) + "\n").utf8))
        }
      }
      if times.count == 2 {
        print(String(format: "%@ ratio: %.2fx (legacy SHA replay / optimized)", operation, times[0] / times[1]))
      }
    }
    if failed { throw NSError(domain: "CommitPerformanceCheck", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "One or more checks failed; incomplete pairs have no ratio."]) }
  }
}
