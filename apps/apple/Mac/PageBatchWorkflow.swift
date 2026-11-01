import Foundation
import MangaCore
import SwiftUI

struct PageBatchRequest: Identifiable {
  let id = UUID().uuidString.lowercased()
  let chapter: LibraryEntity
  let plan: PageBatchPlan
  let translating: Bool
}

extension LibraryUIModel {
  func batchOrganizedPath(_ chapter: LibraryEntity, media: MediaVersion, count: Int) throws -> String {
    let work = entity(chapter.workId)
    return try PathPolicy.chapterPath(author: entity(chapter.authorId)?.title,
      series: entity(chapter.seriesId ?? work?.seriesId)?.title, work: work?.title,
      chapter: chapter.title, language: media.language, mediaLanguageCount: count)
  }
  func commitPageBatch(_ request: PageBatchRequest, plan: PageBatchPlan, destinationId: String) async throws -> LibraryEntity {
    guard canManage, let owner = session.account?.ownerId,
      let chapter = entity(request.chapter.id), chapter.revision == request.chapter.revision,
      !fileQueue.manages(chapter.id), !organizingChapterIds.contains(chapter.id),
      let destination = entity(destinationId), destination.isArchiveDestination
    else { throw LoginError.server("The chapter changed or has active file work. Reopen All Pages.") }
    if request.translating {
      guard plan.translationId != nil else { throw LoginError.server("Confirm the translation alignment first.") }
      try await organizeChapterFiles(chapter, destination: destination, metadata: plan.metadata)
    } else {
      guard !(try await pendingFileOrganizationIds()).contains(chapter.id),
        let directory = session.cacheDirectory?.appendingPathComponent("organization-journals")
      else { throw LoginError.server("Review unfinished file work in Pending Organization first.") }
      organizingChapterIds.insert(chapter.id)
      defer { organizingChapterIds.remove(chapter.id) }
      let folder = try await local.validateDestinationAsync(destination)
      let sourceRoot = try await local.readingRootURL(plan.source.storageRootId)
      let selectedPaths = plan.selectedIndices.map { plan.source.relativePaths[$0] }
      let candidates = try await FileTasks.perform {
        try selectedPaths.map { try PathPolicy.mutationPath($0, under: sourceRoot) }
      }
      let external = try await local.sharedSources(candidates, excluding: Set(chapter.media.map(\.id)))
      let remainingMedia = plan.metadata.media
      let remainingRoots = try await local.referenceRoots(for: remainingMedia)
      let retained = try await FileTasks.perform {
        Set(remainingMedia.flatMap { media -> [String] in
          guard let root = remainingRoots[media.storageRootId] else { return [] }
          return media.relativePaths.map { root.appendingPathComponent($0).standardizedFileURL.path.lowercased() }
        })
      }
      let files = candidates.enumerated().map { offset, source in
        OrganizationFile(source: source,
          relativePath: "Recycle/PageEdits/" + request.id + "/" + String(offset + 1) + "-" + source.lastPathComponent,
          keepSource: external.contains(source.path) || retained.contains(source.path.lowercased()))
      }
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      let cleanup = EmptyMediaFolder.plan(media: [plan.source], roots: [plan.source.storageRootId: sourceRoot], chapterTitle: chapter.title)
      let operations = files
      let staged = try await FileTasks.perform {
        let prepared = try FileOrganization.prepare(entityId: chapter.id, revision: chapter.revision,
          metadata: plan.metadata, libraryId: owner, rootId: destination.id, root: folder,
          sourceRootIds: [plan.source.storageRootId], files: operations, directory: directory, cleanupFolders: cleanup,
          originalMetadata: chapter.input, allowRename: true)
        return try FileOrganization.stage(prepared, in: directory)
      }
      try Task.checkCancellation()
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      _ = try await local.validateDestinationAsync(destination)
      try await session.update(chapter, input: plan.metadata)
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      try await FileTasks.perform { try FileOrganization.finish(staged, in: directory) }
    }
    guard owner == session.account?.ownerId,
      let updated = session.entities.first(where: { $0.id == chapter.id && !$0.deleted }) else { throw LoginError.invalidToken }
    return updated
  }
}

struct PageBatchWorkflowScreen: View {
  let request: PageBatchRequest
  let onCommitted: (LibraryEntity) -> Void
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @Environment(\.dismiss) private var dismiss
  @State private var language = ""
  @State private var alignment: [Int?] = []
  @State private var plan: PageBatchPlan?
  @State private var reviewing = false
  @State private var destinationId = ""
  @State private var busy = false
  @State private var failed = false
  @State private var status = ""
  private var currentPlan: PageBatchPlan { plan ?? request.plan }
  private var destinations: [LibraryEntity] { session.entities.filter(\.isArchiveDestination) }
  private var original: MediaVersion? {
    request.plan.metadata.media.first { $0.language == request.plan.metadata.originalLanguage }
      ?? request.plan.metadata.media.first
  }
  private var canonicalCount: Int { original.map { $0.pageAlignment?.count ?? $0.pageCount } ?? 0 }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SheetHeading(reviewing ? "Commit File Changes" : "Align Translation")
      Text(library.title(request.chapter)).font(.headline)
      if reviewing { commitReview } else { alignmentReview }
      if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
      HStack {
        Button(failed ? "Close" : "Cancel") { dismiss() }.disabled(busy)
        Spacer()
        if reviewing {
          if request.translating && !failed {
            Button("Back to Alignment") { reviewing = false }.disabled(busy)
          }
          Button(busy ? "Committing…" : "Commit") { commit() }
            .buttonStyle(.borderedProminent).disabled(busy || failed || destinationId.isEmpty)
        } else {
          Button("Confirm Alignment") {
            do {
              var next = request.plan
              try next.setTranslation(language: language, alignment: alignment)
              plan = next
              reviewing = true
              status = ""
            } catch { status = error.localizedDescription }
          }.buttonStyle(.borderedProminent).disabled(language.isEmpty || canonicalCount == 0)
        }
      }
    }.padding(24).frame(width: 760, height: 680).interactiveDismissDisabled(busy)
      .onAppear {
        reviewing = !request.translating
        alignment = (0..<canonicalCount).map { $0 < request.plan.selectedIndices.count ? $0 : nil }
        language = mediaLanguages.first { candidate in
          !request.chapter.media.contains { $0.language == candidate.code }
            && candidate.code == AppConfiguration.preferredLanguage
        }?.code ?? mediaLanguages.first { candidate in
          !request.chapter.media.contains { $0.language == candidate.code }
        }?.code ?? ""
        let currentRoot = request.chapter.media.first?.storageRootId
        let previous = UserDefaults.standard.string(forKey: "ArchiveDestination:" + (session.account?.ownerId ?? ""))
        destinationId = destinations.first { $0.id == currentRoot }?.id
          ?? destinations.first { $0.id == previous }?.id ?? destinations.first?.id ?? ""
      }
  }
  private var alignmentReview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Translation language", selection: $language) {
        ForEach(mediaLanguages.filter { candidate in !request.chapter.media.contains { $0.language == candidate.code } }, id: \.code) {
          Text($0.name).tag($0.code)
        }
      }
      Text("Selected pages keep their reading order. Match them to the remaining original pages; unmatched pages use the original.")
        .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(spacing: 16) {
          ForEach(alignment.indices, id: \.self) { canonical in
            HStack(spacing: 20) {
              if let original, let index = original.sourcePage(at: canonical) {
                MediaPagePreview(media: original, index: index).frame(width: 100, height: 140)
              }
              VStack(alignment: .leading) {
                Text("Original page \(canonical + 1)").font(.headline)
                Picker("Translation page", selection: Binding(
                  get: { alignment[canonical] ?? -1 }, set: { alignment[canonical] = $0 < 0 ? nil : $0 })) {
                  Text("Use original").tag(-1)
                  ForEach(request.plan.selectedIndices.indices, id: \.self) { Text("Selected page \($0 + 1)").tag($0) }
                }
              }.frame(maxWidth: .infinity)
              if let selected = alignment[canonical] {
                MediaPagePreview(media: request.plan.source, index: request.plan.selectedIndices[selected])
                  .frame(width: 100, height: 140)
              } else { Label("Original", systemImage: "arrow.uturn.backward").frame(width: 100, height: 140) }
            }
            Divider()
          }
        }
      }
    }.frame(maxHeight: .infinity)
  }
  private var commitReview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(request.translating ? "Move to" : "Recycle in", selection: $destinationId) {
        Text("Choose archive destination").tag("")
        ForEach(destinations) { Text($0.title).tag($0.id) }
      }.disabled(busy)
      Text("Source root: " + library.storageReference(request.plan.source, path: ".").rootLabel)
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Text(request.translating
        ? "Commit splits the selected pages into a new media language and organizes all language folders."
        : "Commit removes the selected pages from this version and keeps recoverable copies in Recycle. Shared originals stay in place.")
        .font(.callout).foregroundStyle(.secondary)
      if !request.translating, !currentPlan.metadata.media.contains(where: { $0.id == request.plan.source.id }) {
        Text(currentPlan.metadata.media.isEmpty
          ? "This removes the last media version and cleans up its empty chapter folder. The chapter stays in your library so you can add content again."
          : "This removes the entire media version and cleans up its empty language folder.")
          .font(.callout).foregroundStyle(.secondary)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(Array(request.plan.selectedPaths.enumerated()), id: \.offset) { offset, path in
            VStack(alignment: .leading, spacing: 5) {
              Text(path)
              if request.translating, let translation = currentPlan.metadata.media.first(where: { $0.id == currentPlan.translationId }) {
                Text("→ " + ((try? library.batchOrganizedPath(request.chapter, media: translation, count: currentPlan.metadata.media.count)) ?? "")
                  + "/" + (path as NSString).lastPathComponent)
              } else {
                Text("→ Recycle/PageEdits/" + request.id + "/" + String(offset + 1) + "-" + (path as NSString).lastPathComponent)
              }
            }.font(.caption.monospaced()).textSelection(.enabled)
            Divider()
          }
          if request.translating {
            Text("Remaining media folders").font(.headline)
            ForEach(currentPlan.metadata.media) { media in
              Text(media.languageLabel + " → " + ((try? library.batchOrganizedPath(request.chapter, media: media,
                count: currentPlan.metadata.media.count)) ?? "Invalid destination path"))
                .font(.caption.monospaced()).textSelection(.enabled)
            }
          }
        }
      }
    }.frame(maxHeight: .infinity)
  }
  private func commit() {
    busy = true
    status = ""
    Task {
      defer { busy = false }
      do {
        let updated = try await library.commitPageBatch(request, plan: currentPlan, destinationId: destinationId)
        onCommitted(updated)
        dismiss()
      } catch {
        failed = true
        status = error.localizedDescription + " Review Pending Organization before retrying if files were staged."
      }
    }
  }
}

struct AddImagesRequest: Identifiable {
  let id = UUID().uuidString.lowercased()
  let chapter: LibraryEntity
  let files: [ImportSourceAccess]
}

struct TranslationPagePlacement: Sendable {
  let mediaId: String
  let canonical: Int
  let count: Int
}

extension LibraryUIModel {
  func commitAddedImages(_ request: AddImagesRequest, language: String, destinationId: String,
    placement: TranslationPagePlacement? = nil,
    progress: @MainActor (String) -> Void = { _ in }) async throws -> LibraryEntity {
    guard canManage, let owner = session.account?.ownerId,
      let chapter = entity(request.chapter.id), chapter.revision == request.chapter.revision,
      let destination = entity(destinationId), destination.isArchiveDestination,
      !fileQueue.manages(chapter.id), !organizingChapterIds.contains(chapter.id),
      let directory = session.cacheDirectory?.appendingPathComponent("organization-journals")
    else { throw LoginError.server("The chapter changed or has active file work. Reopen All Pages.") }
    guard !(try await pendingFileOrganizationIds()).contains(chapter.id), !request.files.isEmpty else {
      throw LoginError.server("Review unfinished file work in Pending Organization first.")
    }
    organizingChapterIds.insert(chapter.id)
    defer { organizingChapterIds.remove(chapter.id) }
    progress("Checking destination…")
    let root = try await local.validateDestinationAsync(destination)
    let sourceRoots = try await local.referenceRoots(for: chapter.media)
    var metadata = chapter.input
    var files: [OrganizationFile] = []
    var relocations: [(root: URL, old: String, new: String)] = []
    var movedMedia: [MediaVersion] = []
    let count = chapter.media.count + (chapter.media.contains { $0.language == language } ? 0 : 1)
    // Reorganize existing versions in the same transaction when the first translation is added.
    for index in metadata.media.indices {
      let media = metadata.media[index]
      guard let source = sourceRoots[media.storageRootId] else { throw StorageError.unsafePath }
      let folder = try batchOrganizedPath(chapter, media: media, count: count)
      let paths = media.relativePaths.map { folder + "/" + ($0 as NSString).lastPathComponent }
      var moved = media
      moved.relativePaths = []
      for (old, new) in zip(media.relativePaths, paths) {
        // Preserved references need no filesystem access. Resolving every ancestor
        // of every existing page causes many SMB round trips for a one-page append.
        if media.storageRootId == destinationId && old == new { continue }
        if source.appendingPathComponent(old).standardizedFileURL != root.appendingPathComponent(new).standardizedFileURL {
          relocations.append((source, old, new))
          moved.relativePaths.append(old)
        }
      }
      if !moved.relativePaths.isEmpty { movedMedia.append(moved) }
      metadata.media[index].storageRootId = destinationId
      metadata.media[index].relativePaths = paths
    }
    // Only actual relocations can remove an original referenced by another comic.
    // An already-organized chapter must not contact unrelated/disconnected roots.
    if !relocations.isEmpty {
      progress("Preparing existing files…")
      let work = relocations
      let resolved = try await FileTasks.perform {
        try work.map { try PathPolicy.mutationPath($0.old, under: $0.root) }
      }
      let shared = try await local.sharedSources(resolved, excluding: Set(chapter.media.map(\.id)))
      let duplicates = Set(Dictionary(grouping: resolved, by: { $0.path.lowercased() }).filter { $0.value.count > 1 }.keys)
      let retained = Set(metadata.media.flatMap(\.relativePaths).map {
        root.appendingPathComponent($0).standardizedFileURL.path.lowercased()
      })
      files = zip(resolved, relocations).map { source, item in
        OrganizationFile(source: source, relativePath: item.new,
          keepSource: shared.contains(source.path) || duplicates.contains(source.path.lowercased())
            || retained.contains(source.path.lowercased()))
      }
    }
    let dummy = MediaVersion(language: language, kind: "images", storageRootId: destinationId, relativePaths: [], pageCount: 0)
    let folder = try batchOrganizedPath(chapter, media: dummy, count: count)
    let occupied = Set(metadata.media.flatMap(\.relativePaths).map { $0.lowercased() })
    let sources = request.files.map(\.url)
    let newPaths = try await FileTasks.perform {
      var used = occupied
      return try sources.map { url -> String in
        let name = try PathPolicy.component(url.lastPathComponent)
        var path = folder + "/" + name
        var suffix = 2
        while used.contains(path.lowercased()) || FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
          path = folder + "/" + url.deletingPathExtension().lastPathComponent + "-" + String(suffix) + "." + url.pathExtension
          suffix += 1
        }
        used.insert(path.lowercased())
        return path
      }
    }
    if let placement {
      guard newPaths.count == 1, (0..<placement.count).contains(placement.canonical) else { throw StorageError.unsafePath }
      if let index = metadata.media.firstIndex(where: { $0.id == placement.mediaId }) {
        let old = metadata.media[index]
        guard old.kind == "images", old.language == language, old.sourcePage(at: placement.canonical) == nil else {
          throw LoginError.server("The target translation changed. Existing translated pages were kept.")
        }
        metadata.media[index].relativePaths += newPaths
        metadata.media[index].pageCount = old.relativePaths.count + 1
        metadata.media[index].pageAlignment = (0..<placement.count).map {
          $0 == placement.canonical ? old.relativePaths.count : old.sourcePage(at: $0)
        }
      } else {
        guard !metadata.media.contains(where: { $0.language == language }) else {
          throw LoginError.server("Another translation now uses this language. Review the chapter before retrying.")
        }
        var media = MediaVersion(id: placement.mediaId, language: language, kind: "images",
          storageRootId: destinationId, relativePaths: newPaths, pageCount: 1)
        media.pageAlignment = (0..<placement.count).map { $0 == placement.canonical ? 0 : nil }
        metadata.media.append(media)
      }
    } else {
      metadata = try PageAppendPlan(metadata: metadata, language: language, rootId: destinationId, paths: newPaths).metadata
    }
    for (source, target) in zip(sources, newPaths) {
      // Selected external images are copied; their originals remain untouched.
      files.append(OrganizationFile(source: source, relativePath: target, keepSource: true))
    }
    let operations = files
    let bookmarks = Dictionary(request.files.map { ($0.url.path, $0.bookmark) }, uniquingKeysWith: { first, _ in first })
    let update = metadata
    let cleanup = operations.contains(where: { !$0.keepSource })
      ? EmptyMediaFolder.plan(media: movedMedia, roots: sourceRoots, chapterTitle: chapter.title) : []
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    progress("Copying added images…")
    let staged = try await FileTasks.perform {
      let prepared = try FileOrganization.prepare(entityId: chapter.id, revision: chapter.revision,
        metadata: update, libraryId: owner, rootId: destinationId, root: root,
        sourceRootIds: Array(sourceRoots.keys), files: operations, directory: directory, cleanupFolders: cleanup,
        sourceBookmarks: bookmarks, originalMetadata: chapter.input, allowRename: true)
      return try FileOrganization.stage(prepared, in: directory)
    }
    try Task.checkCancellation()
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    _ = try await local.validateDestinationAsync(destination)
    progress("Saving chapter…")
    try await session.update(chapter, input: update)
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    progress("Verifying files…")
    try await FileTasks.perform { try FileOrganization.finish(staged, in: directory) }
    guard let updated = entity(chapter.id) else { throw LoginError.invalidToken }
    return updated
  }
}

struct AddImagesScreen: View {
  let request: AddImagesRequest
  let initialLanguage: String
  let onCommitted: (LibraryEntity) -> Void
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @Environment(\.dismiss) private var dismiss
  @State private var language = ""
  @State private var destinationId = ""
  @State private var busy = false
  @State private var failed = false
  @State private var status = ""
  private var destinations: [LibraryEntity] { session.entities.filter(\.isArchiveDestination) }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SheetHeading("Add Images · Commit File Changes", inset: 0)
      Text(library.title(request.chapter)).font(.headline)
      Picker("Media language", selection: $language) {
        ForEach(mediaLanguages, id: \.code) { candidate in
          Text(candidate.name).tag(candidate.code).disabled(request.chapter.media.contains {
            $0.language == candidate.code && $0.kind != "images"
          })
        }
      }
      Picker("Archive destination", selection: $destinationId) {
        Text("Choose destination").tag("")
        ForEach(destinations) { Text($0.title).tag($0.id) }
      }
      Text("Images are appended in filename order. Commit copies them into the archive and creates any missing chapter or language folders. Existing filenames are never overwritten.")
        .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(Array(request.files.enumerated()), id: \.offset) { index, file in
            Text("\(index + 1). " + file.url.lastPathComponent).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
      HStack {
        Button(failed ? "Close" : "Cancel") { dismiss() }.disabled(busy)
        Spacer()
        Button(busy ? "Committing…" : "Commit") {
          busy = true
          Task {
            defer { busy = false }
            do {
              let updated = try await library.commitAddedImages(request, language: language, destinationId: destinationId)
              onCommitted(updated)
              dismiss()
            } catch {
              failed = true
              status = error.localizedDescription + " Review Pending Organization if files were staged."
            }
          }
        }.buttonStyle(.borderedProminent).disabled(busy || failed || language.isEmpty || destinationId.isEmpty)
      }
    }.padding(24).frame(width: 650, height: 540).interactiveDismissDisabled(busy)
      .onAppear {
        language = initialLanguage
        destinationId = destinations.first { $0.id == request.chapter.media.first?.storageRootId }?.id
          ?? destinations.first?.id ?? ""
      }
  }
}
