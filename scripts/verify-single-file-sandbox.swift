// Isolated regression app. Uses only selected synthetic fixtures and a fake API.
import AppKit
import Foundation
import MangaCore

@main @MainActor enum SingleFileSandboxApp {
  static func main() {
    let app = NSApplication.shared
    let delegate = SingleFileSandboxDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor final class SingleFileSandboxDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.title = "Single-file sandbox regression"
    panel.message = "Select the six synthetic MP4, WebM and PDF fixtures in the supplied folder."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.directoryURL = URL(fileURLWithPath: "FIXTURE_DIRECTORY")
    guard panel.runModal() == .OK else { exit(2) }
    do {
      let sources = try panel.urls.map { try ImportSourceAccess($0) }
      guard sources.count == 6 else { throw LoginError.server("Select all six synthetic fixtures") }
      Task {
        do {
          try await run(sources)
          print(
            "PASS: sandboxed MP4/WebM/PDF add-only and commit; exact file grants persist after scope release; archived bytes and cleanup verified. No production API or user media."
          )
          NSApp.terminate(nil)
        } catch {
          fputs("FAIL: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
    } catch {
      fputs("FAIL: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private func run(_ sources: [ImportSourceAccess]) async throws {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("single-file-sandbox-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    defer { library.reset() }
    let work = session.entities.first { $0.id == "w0" }!
    let archive = directory.appendingPathComponent("Archive")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let destination = try await session.create(
      .init(kind: .storageRoot, title: "Archive", storageKind: "local"))
    try library.local.bind(destination, to: archive)
    let parent = sources[0].url.deletingLastPathComponent()
    if (try? LocalMedia.bookmark(for: parent)) == nil {
      print("PASS: parent folder bookmark is denied while selected files remain readable")
    } else {
      throw LoginError.server(
        "The fixture parent was already authorized; use a fresh fixture folder")
    }
    for source in sources {
      let bytes = try Data(contentsOf: source.url)
      let move = source.url.lastPathComponent.hasPrefix("Move")
      let model = ImportWorkspaceModel(library: library)
      model.append(source)
      model.input.authorId = work.authorId
      model.input.workId = work.id
      model.destinationId = destination.id
      model.input.title = source.url.lastPathComponent
      let title = model.input.title
      await model.process(move: move)?.value
      guard model.queue.isEmpty else { throw LoginError.server(model.status) }
      model.close()
      let chapter = session.entities.first { $0.kind == .chapter && $0.title == title }!
      library.local.release()
      let read = try await library.local.url(for: chapter.media[0], file: 0)
      guard try Data(contentsOf: read) == bytes else {
        throw LoginError.server("Media bytes changed")
      }
      if move {
        guard !FileManager.default.fileExists(atPath: source.url.path) else {
          throw LoginError.server("Source cleanup failed")
        }
      } else {
        let resource = try await library.local.boundSourceURL(chapter.media[0].storageRootId)
        guard resource == source.url else {
          throw LoginError.server("File grant became a parent grant")
        }
      }
    }
  }
}
