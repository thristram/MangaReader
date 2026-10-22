import Foundation
import MangaCore
import SwiftUI

struct TemporaryOrganizationRow: Identifiable {
  let entity: LibraryEntity
  let chapters: [LibraryEntity]
  var id: String { entity.id }
  var subtitle: String {
    let versions = chapters.flatMap(\.media).count
    return "\(chapters.count) " + (chapters.count == 1 ? "chapter" : "chapters")
      + " · \(versions) media " + (versions == 1 ? "version" : "versions")
  }
}

extension LibraryUIModel {
  func temporaryOrganizationRows() -> [TemporaryOrganizationRow] {
    let sourceRoots = Set(session.entities.filter {
      $0.kind == .storageRoot && !$0.deleted
        && $0.description == LibraryDestinationIdentity.sourceOnlyDescription
    }.map(\.id))
    let pending = session.visibleEntities(kind: .chapter).filter {
      $0.media.contains { sourceRoots.contains($0.storageRootId) }
    }
    let groups = Dictionary(grouping: pending) { chapter in
      chapter.workId.flatMap { entity($0)?.id } ?? chapter.id
    }
    return groups.compactMap { id, chapters in
      guard let parent = entity(id) else { return nil }
      return TemporaryOrganizationRow(entity: parent, chapters: chapters.sorted {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
      })
    }.sorted { title($0.entity).localizedStandardCompare(title($1.entity)) == .orderedAscending }
  }

  func pendingFileOrganizationIds() async throws -> Set<String> {
    guard let cache = session.cacheDirectory else { throw LoginError.invalidToken }
    return try await FileTasks.perform {
      var result = Set<String>()
      for name in ["organization-journals", "commit-journals", "delete-journals"] {
        let directory = cache.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: directory.path) else { continue }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" && !url.lastPathComponent.contains("-metadata") {
          let data = try Data(contentsOf: url)
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
          guard let phase = value?["phase"] as? String, !["complete", "rolledBack"].contains(phase) else { continue }
          if let id = value?["entityId"] as? String { result.insert(id) }
          else if name == "commit-journals", let id = value?["id"] as? String {
            let payload = directory.appendingPathComponent(id + "-metadata.json")
            if FileManager.default.fileExists(atPath: payload.path),
              let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: payload)) as? [String: Any],
              let entity = metadata["entityId"] as? String { result.insert(entity) }
          }
        }
      }
      return result
    }
  }

  @discardableResult func moveTemporaryFiles(
    rowId: String, destinationId: String,
    progress: @escaping @MainActor @Sendable (String, Double) -> Void = { _, _ in }
  ) async throws -> Int {
    guard canManage, let owner = session.account?.ownerId,
      let destination = entity(destinationId), destination.isArchiveDestination,
      let row = temporaryOrganizationRows().first(where: { $0.id == rowId })
    else { throw LoginError.server("Choose a connected archive destination and an unorganized comic.") }
    var completed = 0
    for chapter in row.chapters {
      try Task.checkCancellation()
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      guard !fileQueue.manages(chapter.id), !organizingChapterIds.contains(chapter.id) else {
        throw LoginError.server("This chapter has an active file task. Wait for it to finish.")
      }
      try await organizeChapterFiles(chapter, destination: destination) { value in
        progress(chapter.title, value)
      }
      completed += 1
    }
    return completed
  }

  func organizeChapterFiles(
    _ chapter: LibraryEntity, destination: LibraryEntity,
    metadata: MetadataInput? = nil,
    progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
  ) async throws
  {
    guard let owner = session.account?.ownerId,
      let directory = session.cacheDirectory?.appendingPathComponent("organization-journals")
    else { throw LoginError.invalidToken }
    guard canManage, destination.isArchiveDestination,
      let current = session.entities.first(where: { $0.id == chapter.id && !$0.deleted }),
      current.revision == chapter.revision, !organizingChapterIds.contains(chapter.id)
    else { throw LoginError.server("This chapter changed or is already being organized.") }
    organizingChapterIds.insert(chapter.id)
    defer { organizingChapterIds.remove(chapter.id) }
    guard !(try await pendingFileOrganizationIds()).contains(chapter.id) else {
      throw LoginError.server("This chapter has unfinished file work. Review its recovery record below.")
    }
    let folder = try await local.validateDestinationAsync(destination)
    try Task.checkCancellation()
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    let author = entity(chapter.authorId)?.title
    let work = entity(chapter.workId)
    let series = entity(chapter.seriesId ?? work?.seriesId)?.title
    var update = metadata ?? chapter.input
    var plans: [OrganizationFile] = []
    var scoped: [URL] = []
    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
    let sourceRootIds = Array(Set(update.media.map(\.storageRootId)))
    // Bookmark access happens on the main actor; all path checks and file work happen off it.
    var sources: [String: URL] = [:]
    for rootId in sourceRootIds {
      try Task.checkCancellation()
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      let root = try await local.readingRootURL(rootId)
      if root.startAccessingSecurityScopedResource() { scoped.append(root) }
      try await FileTasks.perform {
        let marker = try PathPolicy.resolve(LibraryDestinationIdentity.filename, under: root)
        if FileManager.default.fileExists(atPath: marker.path) {
          try JSONDecoder().decode(LibraryDestinationIdentity.self, from: Data(contentsOf: marker))
            .validate(libraryId: owner, destinationId: rootId)
        }
      }
      sources[rootId] = root
    }
    let otherMedia = session.entities.filter { !$0.deleted && $0.id != chapter.id }.flatMap(\.media)
    let referenceRoots = try await local.referenceRoots(for: otherMedia)
    let usedElsewhere = try await FileTasks.perform {
      var paths = Set<String>()
      for media in otherMedia {
        try Task.checkCancellation()
        if let root = referenceRoots[media.storageRootId] {
          for path in media.relativePaths {
            paths.insert(root.appendingPathComponent(path).standardizedFileURL.path.lowercased())
          }
        }
      }
      return paths
    }
    for index in update.media.indices {
      let media = update.media[index]
      guard let sourceRoot = sources[media.storageRootId] else { throw LoginError.invalidToken }
      let languagePath = try PathPolicy.chapterPath(
        author: author, series: series, work: work?.title,
        chapter: chapter.title, language: media.language, mediaLanguageCount: update.media.count)
      let paths = media.relativePaths.map {
        languagePath + "/" + URL(fileURLWithPath: $0).lastPathComponent
      }
      for (old, new) in zip(media.relativePaths, paths) {
        let source = try await FileTasks.perform {
          try PathPolicy.mutationPath(old, under: sourceRoot)
        }
        let target = folder.appendingPathComponent(new).standardizedFileURL
        if source.standardizedFileURL != target {
          plans.append(
            OrganizationFile(
              source: source, relativePath: new,
              keepSource: usedElsewhere.contains(source.standardizedFileURL.path.lowercased())))
        }
      }
      update.media[index].storageRootId = destination.id
      update.media[index].relativePaths = paths
    }
    let files = plans
    let metadata = update
    try Task.checkCancellation()
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    let prepared = try await FileTasks.perform {
      try FileOrganization.prepare(
        entityId: chapter.id, revision: chapter.revision,
        metadata: metadata, libraryId: owner, rootId: destination.id, root: folder,
        sourceRootIds: sourceRootIds, files: files, directory: directory)
    }
    try Task.checkCancellation()
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    let staged = try await FileTasks.perform {
      try FileOrganization.stage(prepared, in: directory) { value in
        Task { @MainActor in progress(value) }
      }
    }
    try Task.checkCancellation()
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    _ = try await local.validateDestinationAsync(destination)
    try await session.update(chapter, input: update)
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    _ = try await local.validateDestinationAsync(destination)
    try await FileTasks.perform { try FileOrganization.finish(staged, in: directory) }
  }
}

struct TemporaryOrganizationPanel: View {
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @ObservedObject var queue: ImportFileQueue
  let refreshToken: Int
  let onFinished: () -> Void
  @State private var destinationId = ""
  @State private var moving: String?
  @State private var detail = ""
  @State private var status = ""
  @State private var blocked = Set<String>()
  private var rows: [TemporaryOrganizationRow] { library.temporaryOrganizationRows() }
  private var destinations: [LibraryEntity] { session.entities.filter(\.isArchiveDestination) }
  private var refreshID: String {
    (session.account?.ownerId ?? "") + rows.flatMap(\.chapters).map {
      $0.id + ":" + String($0.revision)
    }.joined(separator: ":") + String(library.organizingChapterIds.count) + ":" + String(refreshToken)
  }
  var body: some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Not Yet Organized").font(.title2.bold())
          Spacer()
          Picker("Move to", selection: $destinationId) {
            Text("Choose destination").tag("")
            ForEach(destinations) { Text($0.title).tag($0.id) }
          }.frame(maxWidth: 360).disabled(moving != nil)
        }
        Text("These comics still reference their original source folders. Move Files commits them to the selected archive.")
          .font(.callout).foregroundStyle(.secondary)
        LazyVStack(spacing: 0) {
          ForEach(rows) { row in
            HStack(spacing: 14) {
              Image(systemName: row.entity.kind == .work ? "books.vertical" : "doc.richtext")
                .foregroundStyle(.pink).frame(width: 24)
              VStack(alignment: .leading, spacing: 4) {
                Text(library.title(row.entity)).font(.headline)
                Text(row.subtitle)
                  .font(.caption).foregroundStyle(.secondary)
                if row.chapters.contains(where: { blocked.contains($0.id) }) {
                  Text("Unfinished file work · review recovery below").font(.caption).foregroundStyle(.orange)
                }
              }
              Spacer()
              if moving == row.id { ProgressView().controlSize(.small) }
              Button(moving == row.id ? "Moving…" : "Move Files", systemImage: "folder.badge.arrow.forward") {
                move(row)
              }.disabled(!library.canManage || destinationId.isEmpty || moving != nil
                || !library.organizingChapterIds.isEmpty
                || row.chapters.contains { blocked.contains($0.id) || queue.manages($0.id) })
                .accessibilityLabel("Move Files · " + library.title(row.entity))
            }.padding(.vertical, 12)
            if row.id != rows.last?.id { Divider() }
          }
        }
        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
      }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: refreshID) {
          if !destinations.contains(where: { $0.id == destinationId }) {
            let key = "ArchiveDestination:" + (session.account?.ownerId ?? "")
            let previous = UserDefaults.standard.string(forKey: key)
            destinationId = destinations.first { $0.id == previous }?.id ?? destinations.first?.id ?? ""
          }
          do {
            let ids = try await library.pendingFileOrganizationIds()
            if !Task.isCancelled { blocked = ids }
          } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
        .onChange(of: destinationId) { _, value in
          if !value.isEmpty {
            UserDefaults.standard.set(value, forKey: "ArchiveDestination:" + (session.account?.ownerId ?? ""))
          }
        }
    }
  }
  private func move(_ row: TemporaryOrganizationRow) {
    moving = row.id
    status = ""
    let destination = destinationId
    Task {
      defer { moving = nil; detail = ""; onFinished() }
      do {
        let count = try await library.moveTemporaryFiles(rowId: row.id, destinationId: destination) { title, value in
          detail = title + " · " + String(Int(value * 100)) + "%"
        }
        status = "Moved \(count) " + (count == 1 ? "chapter." : "chapters.")
      } catch {
        status = error.localizedDescription
        blocked = (try? await library.pendingFileOrganizationIds()) ?? blocked
      }
    }
  }
}
