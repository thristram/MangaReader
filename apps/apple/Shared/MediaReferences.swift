import Foundation
import MangaCore
import SwiftUI

// A metadata reference is useful even when its device-specific connection is missing.
struct MediaStorageReference: Equatable, Sendable {
  let rootId: String
  let rootName: String
  let relativePath: String
  var sourceLocation: String?
  var localCopy: String?
  var rootLabel: String { rootName + " (" + rootId + ")" }

  static func fileIndex(_ media: MediaVersion, page: Int) -> Int {
    media.kind == "images" ? page : 0
  }
  static func smbLocation(_ connection: SMBConnection, relativePath: String) -> String? {
    guard let server = URLComponents(string: connection.server), let host = server.host else { return nil }
    // Only the server authority is displayed; credentials/query/fragment never appear.
    var origin = URLComponents()
    origin.scheme = "smb"
    origin.host = host
    origin.port = server.port
    guard let authority = origin.string else { return nil }
    let parts = [connection.share, connection.basePath, relativePath == "." ? "" : relativePath]
      .filter { !$0.isEmpty }
    return authority + "/" + parts.joined(separator: "/")
  }
}

struct SMBRootNotConfigured: LocalizedError {
  let rootId: String
  let rootName: String
  var referencePath: String?
  var errorDescription: String? {
    var text = "Configure this chapter’s SMB root in Connections first."
      + "\nStorage root: " + rootName + " (" + rootId + ")"
    if let referencePath { text += "\nReference file: " + referencePath }
    return text
  }
}

struct ReferencedMediaFolder: Identifiable {
  let id: String
  let label: String
  var reference: MediaStorageReference
}

@MainActor extension LibraryUIModel {
  func storageReference(_ media: MediaVersion, path: String) -> MediaStorageReference {
    MediaStorageReference(
      rootId: media.storageRootId,
      rootName: session.entities.first { $0.id == media.storageRootId && !$0.deleted }?.title
        ?? "Unknown storage root", relativePath: path)
  }
  func resolveStorageReference(_ reference: MediaStorageReference) async -> MediaStorageReference {
    var result = reference
    #if os(macOS)
      if let root = try? await local.readingRootURL(reference.rootId),
        let location = reference.relativePath == "." ? root
          : try? PathPolicy.resolve(reference.relativePath, under: root) {
        result.sourceLocation = location.path
      }
    #endif
    if result.sourceLocation == nil, let connection = try? smb.connection(rootId: reference.rootId) {
      result.sourceLocation = MediaStorageReference.smbLocation(connection, relativePath: reference.relativePath)
    }
    return result
  }
  func fileReference(_ media: MediaVersion, page: Int) async -> MediaStorageReference? {
    let index = MediaStorageReference.fileIndex(media, page: page)
    guard media.relativePaths.indices.contains(index) else { return nil }
    var result = await resolveStorageReference(storageReference(media, path: media.relativePaths[index]))
    if let cached = try? await smb.cachedPage(media, index: index) { result.localCopy = cached.path }
    return result
  }
  func referencedFolders(_ chapters: [LibraryEntity]) -> [ReferencedMediaFolder] {
    var seen = Set<String>()
    var folders: [ReferencedMediaFolder] = []
    for chapter in chapters {
      for media in chapter.media {
        for path in media.relativePaths {
          let parent = (path as NSString).deletingLastPathComponent
          let reference = storageReference(media, path: parent.isEmpty ? "." : parent)
          let id = chapter.id + ":" + media.id + ":" + reference.relativePath
          if seen.insert(id).inserted {
            folders.append(ReferencedMediaFolder(
              id: id, label: title(chapter) + " · " + media.languageLabel, reference: reference))
          }
        }
      }
    }
    return folders
  }
}

struct StorageReferenceDetails: View {
  let reference: MediaStorageReference
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Storage root", value: reference.rootLabel)
      Text("Reference path").font(.caption).foregroundStyle(.secondary)
      Text(reference.relativePath).font(.callout.monospaced())
      if let location = reference.sourceLocation {
        Text("Source location").font(.caption).foregroundStyle(.secondary)
        Text(location).font(.callout.monospaced())
      } else {
        Text("The source location is not configured on this device.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let localCopy = reference.localCopy {
        Text("On-device copy").font(.caption).foregroundStyle(.secondary)
        Text(localCopy).font(.callout.monospaced())
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled).accessibilityIdentifier("storage-reference")
  }
}

struct ReferencedFoldersView: View {
  let entity: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @State private var folders: [ReferencedMediaFolder] = []
  private var chapters: [LibraryEntity] {
    let current = session.entities.first { $0.id == entity.id && !$0.deleted } ?? entity
    return current.kind == .chapter ? [current] : library.chapters(current)
  }
  private var requestID: String {
    (session.account?.ownerId ?? "") + AppConfiguration.preferredLanguage
      + chapters.map { $0.id + ":" + String($0.revision) }.joined(separator: ":")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if folders.isEmpty {
        Text("No referenced folders.").foregroundStyle(.secondary)
      }
      ForEach(folders) { folder in
        VStack(alignment: .leading, spacing: 8) {
          Text(folder.label).font(.headline)
          StorageReferenceDetails(reference: folder.reference)
        }
        if folder.id != folders.last?.id { Divider() }
      }
    }.task(id: requestID) {
      let request = requestID
      var pending = library.referencedFolders(chapters)
      folders = pending
      // Resolve a root once, rather than opening every chapter or scanning its files.
      var roots: [String: MediaStorageReference] = [:]
      for index in pending.indices {
        let reference = pending[index].reference
        let root: MediaStorageReference
        if let existing = roots[reference.rootId] { root = existing }
        else {
          root = await library.resolveStorageReference(MediaStorageReference(
            rootId: reference.rootId, rootName: reference.rootName, relativePath: "."))
          roots[reference.rootId] = root
        }
        guard !Task.isCancelled, request == requestID else { return }
        if let location = root.sourceLocation {
          pending[index].reference.sourceLocation = reference.relativePath == "." ? location
            : location + (location.hasSuffix("/") ? "" : "/") + reference.relativePath
        }
      }
      folders = pending
    }
  }
}

struct ReaderFileInfo: View {
  let media: MediaVersion
  let page: Int
  @EnvironmentObject private var library: LibraryUIModel
  @Environment(\.dismiss) private var dismiss
  @State private var reference: MediaStorageReference?
  var body: some View {
    NavigationStack {
      Form {
        Section("File Location") {
          if let reference { StorageReferenceDetails(reference: reference) }
          else { ProgressView("Loading file information…") }
        }
        Section {
          LabeledContent("Media language", value: media.languageLabel)
          LabeledContent("Format", value: media.kind.uppercased())
        }
      }.formStyle(.grouped).navigationTitle("Info")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .task(id: media.id + ":" + media.storageRootId + ":" + media.relativePaths.joined(separator: "\0") + ":" + String(page)) {
      let index = MediaStorageReference.fileIndex(media, page: page)
      guard media.relativePaths.indices.contains(index) else { return }
      reference = library.storageReference(media, path: media.relativePaths[index])
      let resolved = await library.fileReference(media, page: page)
      if !Task.isCancelled { reference = resolved }
    }
    #if os(macOS)
      .frame(width: 600, height: 480)
    #else
      .presentationDetents([.medium, .large])
    #endif
  }
}
