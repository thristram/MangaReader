import AppKit
import Foundation
import MangaCore
import SwiftUI

struct OrganizationRecord: Identifiable, Sendable {
  var id: String
  var source: String
  var destination: String
  var phase: String
  var json: URL
}
struct RecycleRecord: Identifiable, Sendable {
  let journal: RecycleJournal
  let directory: URL
  var id: String { journal.id }
}
private struct OrganizationSnapshot: Sendable {
  let records: [OrganizationRecord]
  let plans: [OrganizationJournal]
  let recycle: [RecycleRecord]
}
struct OrganizationScreen: View {
  var page: LibraryPage = .organization
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @State private var records: [OrganizationRecord] = []
  @State private var selected: OrganizationRecord?
  @State private var languagePlans: [OrganizationJournal] = []
  @State private var selectedPlan: OrganizationJournal?
  @State private var recycleRecords: [RecycleRecord] = []
  @State private var selectedRecycle: RecycleRecord?
  @State private var recovering = false
  @State private var status = ""
  @State private var recoveryFailed = false
  @State private var refreshToken = 0
  @State private var loading = false
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        if page == .organization || page == .fileManagement { FileQueuePanel(queue: library.fileQueue) }
        if page == .organization || page == .unorganized {
          TemporaryOrganizationPanel(queue: library.fileQueue, refreshToken: refreshToken, onFinished: load)
        }
        if page != .unorganized {
        HStack {
          Text(page == .commitHistory ? "File commits and recovery history." : "Background imports and file recovery.").foregroundStyle(.secondary)
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise", action: load)
        }
        if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        if loading { ProgressView("Loading file history…") }
        if !loading && records.isEmpty && recycleRecords.isEmpty && languagePlans.isEmpty
          && (page == .commitHistory || library.fileQueue.items.isEmpty)
          && (page != .organization || library.temporaryOrganizationRows().isEmpty)
        {
          ContentUnavailableView(
            "No pending file changes", systemImage: "folder.badge.checkmark",
            description: Text(
              "Reviewed import moves and recovery records appear here."))
        }
        ForEach(languagePlans) { plan in
          HStack {
            VStack(alignment: .leading, spacing: 6) {
              Text(plan.metadata.title).font(.headline)
              Text("File organization · \(plan.files.count) files · " + (plan.phase == "complete" ? "completed" : "recovery available")).font(
                .caption
              ).foregroundStyle(.secondary)
            }
            Spacer()
            if plan.phase != "complete" {
              Button("Review") {
                status = ""
                recoveryFailed = false
                selectedPlan = plan
              }.disabled(loading || !library.organizingChapterIds.isEmpty)
            } else { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
          }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        ForEach(recycleRecords) { record in
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Label(["complete", "rolledBack"].contains(record.journal.phase)
                ? "Comic deletion · " + record.journal.phase : "Comic deletion needs review", systemImage: "trash").font(.headline)
              Spacer()
              if !["complete", "rolledBack"].contains(record.journal.phase) {
                Button("Review") { selectedRecycle = record }.disabled(!library.organizingChapterIds.isEmpty)
              }
            }
            Text(library.entity(record.journal.entityId).map(library.title) ?? "Deleted comic")
              .foregroundStyle(.secondary)
            Text("\(record.journal.entries.count) file records").font(.caption)
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
            .quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        ForEach(records) { record in
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Label(
                record.phase == "complete" ? "Commit Complete" : "Review Required",
                systemImage: record.phase == "complete"
                  ? "checkmark.circle" : "exclamationmark.triangle"
              ).font(.headline)
              Spacer()
              if record.phase != "complete" {
                Button("Review & Recover") { selected = record }.disabled(!library.organizingChapterIds.isEmpty)
              }
            }
            Text(record.source).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Image(systemName: "arrow.down").foregroundStyle(.pink)
            Text(record.destination).font(.system(.caption, design: .monospaced)).textSelection(
              .enabled)
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
            .quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        }
        if page == .unorganized && library.temporaryOrganizationRows().isEmpty {
          ContentUnavailableView("Everything is organized", systemImage: "folder.badge.checkmark")
        }
      }.padding(28)
    }.onAppear(perform: load)
      .onChange(of: page) { _, _ in load() }
      .onChange(of: library.organizingChapterIds) { _, active in if active.isEmpty { load() } }
      .sheet(item: $selected) { record in
        VStack(alignment: .leading, spacing: 20) {
          Text("Review Commit Recovery").font(.system(size: 23, weight: .semibold))
          Text(
            "Inspect source and destination before reconciling metadata. No retry moves or overwrites files."
          ).foregroundStyle(.secondary)
          GroupBox("Source") {
            Text(record.source).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }
          GroupBox("Destination") {
            Text(record.destination).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }
          Button("Show Destination in Finder") {
            NSWorkspace.shared.selectFile(record.destination, inFileViewerRootedAtPath: "")
          }
          if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
          HStack {
            Button("Close") { selected = nil }
            Spacer()
            Button(recovering ? "Reconciling…" : "Reconcile Metadata", action: { recover(record) })
              .buttonStyle(.borderedProminent).disabled(
                recovering || record.phase != "filesMoved_metadataPending")
          }
        }.padding(28).frame(width: 650)
      }
      .sheet(item: $selectedPlan) { plan in
        VStack(alignment: .leading, spacing: 20) {
          SheetHeading("Resume File Organization")
          Text(
            "Finish this file plan, update the chapter, then remove verified source files. Recycle copies and unrelated files are preserved."
          ).foregroundStyle(.secondary)
          Text(plan.metadata.title).font(.headline)
          Text(plan.root).font(.caption.monospaced()).textSelection(.enabled)
          Text("\(plan.files.count) files · \(plan.metadata.media.count) media versions")
          if !status.isEmpty {
            Label(status, systemImage: recoveryFailed ? "exclamationmark.triangle" : "checkmark.circle")
              .font(.callout).foregroundStyle(recoveryFailed ? Color.red : Color.secondary)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
          HStack {
            Button("Close") { selectedPlan = nil }.disabled(recovering)
            Spacer()
            Button(recovering ? "Resuming…" : "Resume & Finish") { recoverLanguages(plan) }
              .buttonStyle(.borderedProminent).disabled(recovering || !library.organizingChapterIds.isEmpty)
          }
        }.padding(28).frame(width: 600)
      }
      .sheet(item: $selectedRecycle) { record in
        VStack(alignment: .leading, spacing: 20) {
          Text("Review Comic Deletion").font(.system(size: 23, weight: .semibold))
          Text(
            "Files remain inside this library. Restore their original paths or finish removing the comic’s library record."
          )
          .foregroundStyle(.secondary)
          ScrollView {
            ForEach(record.journal.entries.indices, id: \.self) { index in
              let entry = record.journal.entries[index]
              VStack(alignment: .leading, spacing: 6) {
                Text(entry.source)
                Label(entry.destination, systemImage: "trash")
              }.font(.caption.monospaced()).textSelection(.enabled).padding(.vertical, 5)
            }
          }.frame(maxHeight: 230)
          if !status.isEmpty { Text(status).font(.caption) }
          HStack {
            Button("Close") { selectedRecycle = nil }.disabled(recovering)
            Spacer()
            Button("Restore Files") { recoverRecycle(record, restore: true) }.disabled(recovering)
            Button("Finish Delete", role: .destructive) { recoverRecycle(record, restore: false) }
              .disabled(recovering)
          }
        }.padding(28).frame(width: 650)
      }
  }
  private func load() {
    refreshToken += 1
    let token = refreshToken
    let owner = session.account?.ownerId
    guard let cache = session.cacheDirectory else { return }
    let history = page == .commitHistory
    let pendingOnly = page == .fileManagement
    loading = true
    Task {
      do {
        let snapshot = try await FileTasks.perform { () -> OrganizationSnapshot in
          let fm = FileManager.default
          func files(_ name: String) throws -> [URL] {
            let folder = cache.appendingPathComponent(name)
            guard fm.fileExists(atPath: folder.path) else { return [] }
            return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
              .filter { $0.pathExtension == "json" }
              .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                  > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
              }
          }
          let plans = try files("organization-journals").compactMap { url -> OrganizationJournal? in
            guard let data = try? Data(contentsOf: url), let plan = try? JSONDecoder().decode(OrganizationJournal.self, from: data),
              history || plan.phase != "complete" else { return nil }
            return plan
          }
          let recycleDirectory = cache.appendingPathComponent("delete-journals")
          let recycle = try files("delete-journals").compactMap { url -> RecycleRecord? in
            guard let data = try? Data(contentsOf: url), let journal = try? JSONDecoder().decode(RecycleJournal.self, from: data),
              history || !["complete", "rolledBack"].contains(journal.phase) else { return nil }
            return RecycleRecord(journal: journal, directory: recycleDirectory)
          }
          let records = try files("commit-journals").compactMap { url -> OrganizationRecord? in
            guard !url.lastPathComponent.contains("-metadata"), let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = value["id"] as? String, let phase = value["phase"] as? String,
              !pendingOnly || phase != "complete" else { return nil }
            return OrganizationRecord(id: id, source: value["source"] as? String ?? "",
              destination: value["destination"] as? String ?? "", phase: phase, json: url)
          }
          return OrganizationSnapshot(records: records, plans: plans, recycle: recycle)
        }
        guard owner == session.account?.ownerId, token == refreshToken else { return }
        records = snapshot.records
        languagePlans = snapshot.plans
        recycleRecords = snapshot.recycle
        loading = false
      } catch {
        guard owner == session.account?.ownerId, token == refreshToken else { return }
        status = error.localizedDescription
        loading = false
      }
    }
  }
  private func recoverLanguages(_ plan: OrganizationJournal) {
    guard library.canManage, library.organizingChapterIds.isEmpty else {
      recoveryFailed = true
      status = "Another file operation is active. Wait for it to finish before resuming this plan."
      return
    }
    recovering = true
    recoveryFailed = false
    status = ""
    Task {
      defer { recovering = false }
      do {
        try await library.resumeOrganizationPlan(plan)
        status = "Files organized."
        selectedPlan = nil
        load()
      } catch {
        recoveryFailed = true
        status = error.localizedDescription
      }
    }
  }
  private func recover(_ record: OrganizationRecord) {
    recovering = true
    status = ""
    let owner = session.account?.ownerId
    Task {
      defer { recovering = false }
      do {
        try await session.synchronize()
        guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
        let moveJournal = try JSONDecoder().decode(
          MoveJournal.self, from: Data(contentsOf: record.json))
        guard FileManager.default.fileExists(atPath: record.destination),
          moveJournal.removeSourceAfterCommit == true
            || !FileManager.default.fileExists(atPath: record.source),
          record.phase == "filesMoved_metadataPending"
        else {
          throw LoginError.server(
            "Source or destination changed. Inspect the journal and files before recovery.")
        }
        let payloadURL = record.json.deletingLastPathComponent().appendingPathComponent(
          record.id + "-metadata.json")
        let payload =
          try JSONSerialization.jsonObject(with: Data(contentsOf: payloadURL)) as? [String: Any]
        guard let id = payload?["entityId"] as? String, let revision = payload?["revision"] as? Int,
          let metadata = payload?["metadata"],
          let current = session.entities.first(where: { $0.id == id && !$0.deleted }),
          session.account?.ownerId == owner
        else {
          throw LoginError.server(
            "Metadata changed since this plan. Review the journal before applying a new plan.")
        }
        let input = try JSONDecoder().decode(
          MetadataInput.self, from: JSONSerialization.data(withJSONObject: metadata))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let alreadyCommitted = try encoder.encode(current.input) == encoder.encode(input)
        guard alreadyCommitted || current.revision == revision else {
          throw LoginError.server(
            "This comic changed. Review its metadata before recovering this move.")
        }
        var roots = Set(input.media.map(\.storageRootId))
        if moveJournal.removeSourceAfterCommit == true,
          let sourceRoot = payload?["sourceRootId"] as? String
        {
          roots.insert(sourceRoot)
        }
        var leased: [URL] = []
        defer { leased.forEach { $0.stopAccessingSecurityScopedResource() } }
        for id in roots {
          let root = try library.local.rootURL(id)
          if root.startAccessingSecurityScopedResource() { leased.append(root) }
        }
        for media in input.media { _ = try library.local.urls(for: media) }
        if !alreadyCommitted { try await session.update(current, input: input) }
        guard session.account?.ownerId == owner else { return }
        let directory = record.json.deletingLastPathComponent()
        try await FileTasks.perform { try FileCommit.finish(moveJournal, in: directory) }
        library.fileQueue.finishRecoveredChapter(id)
        status = "Move completed. Metadata and verified files match."
        load()
      } catch { status = error.localizedDescription }
    }
  }
  private func recoverRecycle(_ record: RecycleRecord, restore: Bool) {
    recovering = true
    status = ""
    let owner = session.account?.ownerId
    Task {
      defer { recovering = false }
      do {
        try await session.synchronize()
        guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
        var leased: [URL] = []
        defer { leased.forEach { $0.stopAccessingSecurityScopedResource() } }
        for entry in record.journal.entries {
          guard entry.libraryId == owner else { throw LoginError.invalidToken }
          let url = try library.local.rootURL(entry.rootId)
          guard
            url.resolvingSymlinksInPath().path
              == URL(fileURLWithPath: entry.root).resolvingSymlinksInPath().path
          else { throw StorageError.unsafePath }
          if url.startAccessingSecurityScopedResource() { leased.append(url) }
        }
        let current = session.entities.first { $0.id == record.journal.entityId && !$0.deleted }
        if restore {
          try await FileTasks.perform {
            try FileRecycle.rollback(record.journal, in: record.directory)
          }
          status = "Original file paths restored."
        } else {
          let shared = session.entities.filter { !$0.deleted && $0.id != record.journal.entityId }
            .flatMap(\.media)
          guard
            !record.journal.entries.contains(where: { entry in
              shared.contains {
                $0.storageRootId == entry.rootId
                  && $0.relativePaths.contains {
                    $0.precomposedStringWithCanonicalMapping.lowercased()
                      == entry.source.precomposedStringWithCanonicalMapping.lowercased()
                  }
              }
            })
          else {
            throw LoginError.server(
              "These files are now used by another comic. Restore the files and review the comic before deleting again."
            )
          }
          if let current {
            guard current.revision == record.journal.revision else {
              throw LoginError.server(
                "This comic changed. Restore its files and review it before deleting again.")
            }
          }
          let resumed = try await FileTasks.perform {
            try FileRecycle.resume(record.journal, in: record.directory)
          }
          guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
          if let current { try await session.delete(current) }
          try await FileTasks.perform {
            try FileRecycle.finish(resumed, in: record.directory)
          }
          status = "Comic removed. Its archived files remain in Recycle."
        }
        load()
      } catch { status = error.localizedDescription }
    }
  }

}

struct FileQueuePanel: View {
  @ObservedObject var queue: ImportFileQueue
  var body: some View {
    if !queue.items.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        Text("File Management Queue").font(.title2.bold())
        ForEach(queue.items.sorted { $0.addedAt > $1.addedAt }) { item in
          HStack {
            Image(
              systemName: item.completed
                ? "checkmark.circle"
                : item.failed ? "exclamationmark.triangle" : "folder.badge.gearshape"
            )
            .foregroundStyle(item.failed ? Color.orange : Color.pink)
            VStack(alignment: .leading, spacing: 5) {
              Text(item.title).font(.headline)
              Text(item.status == "Running" ? queue.detail : item.status).font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if item.status == "Running" { ProgressView().controlSize(.small) }
            if item.failed {
              Button("Retry") { queue.retry(item.id) }
              Button("Remove from Queue", systemImage: "xmark.circle") { queue.removeFailed(item.id) }
                .help("Remove this failed queue entry. File recovery records remain in Commit History.")
            }
          }
        }
      }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

struct MediaLanguageReview: Identifiable {
  let id = UUID()
  let chapter: LibraryEntity
  let plan: MediaLanguageChangePlan
}
struct MediaLanguageCommitFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message + " Review Pending Organization before retrying." }
}
extension LibraryUIModel {
  func commitMediaLanguageChange(_ review: MediaLanguageReview) async throws -> LibraryEntity {
    guard canManage, let owner = session.account?.ownerId,
      let current = entity(review.chapter.id), current.revision == review.chapter.revision,
      !fileQueue.manages(current.id), !organizingChapterIds.contains(current.id)
    else {
      throw LoginError.server(
        "This chapter changed or has a pending import. Reopen it after that work finishes.")
    }
    let plan = review.plan
    guard let oldDirectory = plan.sourceDirectory, let newDirectory = plan.destinationDirectory
    else {
      try await session.update(current, input: plan.metadata)
      guard owner == session.account?.ownerId,
        let updated = session.entities.first(where: { $0.id == current.id && !$0.deleted })
      else {
        throw LoginError.invalidToken
      }
      return updated
    }
    guard let destination = entity(plan.rootId), destination.isArchiveDestination else {
      throw LoginError.server(
        "Connect this version's archive folder in Media Storage before changing its language.")
    }
    let root = try await local.validateDestinationAsync(destination)
    let contents = try await FileTasks.perform {
      _ = try PathPolicy.mutationPath(oldDirectory, under: root)
      let target = try PathPolicy.mutationPath(newDirectory, under: root)
      guard !FileManager.default.fileExists(atPath: target.path) else { throw StorageError.collision }
      var files: [OrganizationFile] = []
      var cleanup: [EmptyMediaFolder] = []
      var folders: [String] = []
      func scan(_ before: String, _ after: String) throws {
        try Task.checkCancellation()
        let folder = try PathPolicy.mutationPath(before, under: root)
        cleanup.append(EmptyMediaFolder(root: root, relativePath: before))
        folders.append(after)
        for entry in try FileManager.default.contentsOfDirectory(at: folder,
          includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
          let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
          guard values.isSymbolicLink != true else { throw StorageError.unsafePath }
          let old = before + "/" + entry.lastPathComponent
          let new = after + "/" + entry.lastPathComponent
          if values.isDirectory == true { try scan(old, new) }
          else {
            guard values.isRegularFile == true else { throw StorageError.unsupportedMove }
            files.append(OrganizationFile(source: try PathPolicy.mutationPath(old, under: root),
              relativePath: new, keepSource: false))
          }
        }
      }
      try scan(oldDirectory, newDirectory)
      return (files, cleanup, folders)
    }
    do {
      try await organizeChapterFiles(current, destination: destination,
        metadata: plan.metadata, recomputePaths: false, supplementalFiles: contents.0,
        cleanupFolders: contents.1, destinationFolders: contents.2)
      guard owner == session.account?.ownerId,
        let updated = session.entities.first(where: { $0.id == current.id && !$0.deleted })
      else { throw LoginError.invalidToken }
      return updated
    } catch {
      throw MediaLanguageCommitFailure(message: error.localizedDescription)
    }
  }
}

struct MediaLanguageCommitScreen: View {
  let review: MediaLanguageReview
  let onCommitted: (LibraryEntity) -> Void
  @EnvironmentObject private var library: LibraryUIModel
  @Environment(\.dismiss) private var dismiss
  @State private var busy = false
  @State private var recoveryRequired = false
  @State private var status = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      SheetHeading("Change Media Language")
      Text(review.plan.metadata.title).font(.headline)
      Text(review.plan.fromLanguage.uppercased() + " → " + review.plan.toLanguage.uppercased())
        .font(.title2.weight(.semibold))
      if let old = review.plan.sourceDirectory, let new = review.plan.destinationDirectory {
        GroupBox("Current Folder") {
          Text(old).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("After Commit") {
          Text(new).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(
          "Files are verified before saving the chapter and removing the old folder. Shared originals are kept."
        )
        .font(.callout).foregroundStyle(.secondary)
      } else {
        Text(
          "This chapter has one media version. Its folder has no language suffix; only the media language changes."
        )
        .foregroundStyle(.secondary)
      }
      Text("Commit also saves your current chapter edits.").font(.caption).foregroundStyle(
        .secondary)
      if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
      HStack {
        Button(recoveryRequired ? "Close" : "Cancel") { dismiss() }.disabled(busy)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(busy ? "Committing…" : "Commit") {
          busy = true
          Task {
            defer { busy = false }
            do { onCommitted(try await library.commitMediaLanguageChange(review)) } catch {
              status = error.localizedDescription
              recoveryRequired = error is MediaLanguageCommitFailure
            }
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(busy || recoveryRequired)
      }
    }.padding(28).frame(width: 620).interactiveDismissDisabled(busy)
  }
}

extension LibraryUIModel {
  func resumeOrganizationPlan(_ initial: OrganizationJournal) async throws {
    var plan = initial
    guard canManage, !organizingChapterIds.contains(plan.entityId), !fileQueue.manages(plan.entityId) else {
      throw LoginError.server("This chapter has active file work. Retry after it finishes.")
    }
    organizingChapterIds.insert(plan.entityId)
    defer { organizingChapterIds.remove(plan.entityId) }
    let owner = session.account?.ownerId
    try await session.synchronize()
    guard owner == session.account?.ownerId, owner == plan.libraryId,
      let directory = session.cacheDirectory?.appendingPathComponent("organization-journals"),
      let current = session.entities.first(where: { $0.id == plan.entityId && !$0.deleted })
    else { throw LoginError.invalidToken }
    let journalId = plan.id
    plan = try await FileTasks.perform { try FileOrganization.read(journalId, in: directory) }
    guard owner == session.account?.ownerId, plan.libraryId == owner, plan.entityId == initial.entityId
    else { throw LoginError.invalidToken }
    if plan.phase == "complete" {
      fileQueue.finishRecoveredChapter(plan.entityId)
      try await translationQueue.recordRecoveredCommit(plan)
      return
    }
    let root = try local.rootURL(plan.rootId)
    guard root.standardizedFileURL.path == plan.root else { throw StorageError.unsafePath }
    var leased: [URL] = []
    var roots: [String: URL] = [:]
    defer { leased.forEach { $0.stopAccessingSecurityScopedResource() } }
    for id in Set(plan.sourceRootIds + [plan.rootId]) {
      let folder = try local.rootURL(id)
      roots[id] = folder
      if folder.startAccessingSecurityScopedResource() { leased.append(folder) }
    }
    if plan.originalMetadata == nil,
      case .conflict = try plan.recovery(current: current.input, revision: current.revision),
      let context = translationQueue.legacyRecovery(for: plan) {
      let legacy = plan
      let referenceRoots = roots
      if let recovered = try await FileTasks.perform({
        guard let recovered = try legacy.recoveringLegacyImageAddition(current: current.input, mediaId: context.mediaId,
          language: context.language, canonical: context.canonical, count: context.count,
          cachedSource: context.cachedSource, roots: referenceRoots) else { return nil as OrganizationJournal? }
        return try FileOrganization.recordRecovery(legacy, recovered: recovered, in: directory)
      }) { plan = recovered }
    }
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    let update: MetadataInput?
    switch try plan.recovery(current: current.input, revision: current.revision) {
    case .committed: update = nil
    case .update(let metadata): update = metadata
    case .conflict:
      if plan.originalMetadata == nil {
        throw LoginError.server("This older file commit has no original metadata snapshot, and the chapter changed before recovery. Review File Management Queue before retrying. Cached translations are retained.")
      }
      throw LoginError.server("This chapter's files, page order or folder metadata changed since this commit was prepared. Review File Management Queue before retrying. Cached translations are retained.")
    }
    let committed = update == nil
    if !committed {
      for (path, bookmark) in plan.sourceBookmarks ?? [:] {
        var stale = false
        let file = try URL(resolvingBookmarkData: bookmark,
          options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
          bookmarkDataIsStale: &stale)
        guard file.standardizedFileURL.path == path else { throw StorageError.unsafePath }
        if file.startAccessingSecurityScopedResource() { leased.append(file) }
      }
    }
    let resumable = plan
    let staged =
      committed
      ? resumable : try await FileTasks.perform { try FileOrganization.stage(resumable, in: directory) }
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    if let update { try await session.update(current, input: update) }
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    try await FileTasks.perform { try FileOrganization.finish(staged, in: directory) }
    fileQueue.finishRecoveredChapter(plan.entityId)
    try await translationQueue.recordRecoveredCommit(staged)
  }
}
