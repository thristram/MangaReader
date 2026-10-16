import AppKit
import Foundation
import MangaCore
import SwiftUI

struct OrganizationRecord: Identifiable {
  var id: String
  var source: String
  var destination: String
  var phase: String
  var json: URL
}
struct RecycleRecord: Identifiable {
  let journal: RecycleJournal
  let directory: URL
  var id: String { journal.id }
}
struct OrganizationScreen: View {
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
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        FileQueuePanel(queue: library.fileQueue)
        HStack {
          Text("Background imports and file recovery.").foregroundStyle(.secondary)
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise", action: load)
        }
        if records.isEmpty && recycleRecords.isEmpty && languagePlans.isEmpty
          && library.fileQueue.items.isEmpty
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
              Text("Language folders · \(plan.files.count) files · recovery available").font(
                .caption
              ).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { selectedPlan = plan }
          }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        ForEach(recycleRecords) { record in
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Label("Comic deletion needs review", systemImage: "trash").font(.headline)
              Spacer()
              Button("Review") { selectedRecycle = record }
            }
            Text(library.entity(record.journal.entityId).map(library.title) ?? "Deleted comic")
              .foregroundStyle(.secondary)
            Text("\(record.journal.entries.count) files in Recycle").font(.caption)
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
              if record.phase != "complete" { Button("Review & Recover") { selected = record } }
            }
            Text(record.source).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Image(systemName: "arrow.down").foregroundStyle(.pink)
            Text(record.destination).font(.system(.caption, design: .monospaced)).textSelection(
              .enabled)
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
            .quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
      }.padding(28)
    }.onAppear(perform: load)
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
          SheetHeading("Resume Language Organization")
          Text(
            "Finish organizing every language folder, update the chapter, then remove verified source files. Existing unrelated files are preserved."
          ).foregroundStyle(.secondary)
          Text(plan.metadata.title).font(.headline)
          Text(plan.root).font(.caption.monospaced()).textSelection(.enabled)
          Text("\(plan.files.count) files · \(plan.metadata.media.count) media versions")
          if !status.isEmpty { Text(status).font(.caption) }
          HStack {
            Button("Close") { selectedPlan = nil }.disabled(recovering)
            Spacer()
            Button(recovering ? "Resuming…" : "Resume & Finish") { recoverLanguages(plan) }
              .buttonStyle(.borderedProminent).disabled(recovering)
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
    if let directory = session.cacheDirectory?.appendingPathComponent("organization-journals"),
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    {
      languagePlans = urls.compactMap { url in
        guard let data = try? Data(contentsOf: url),
          let plan = try? JSONDecoder().decode(OrganizationJournal.self, from: data),
          plan.phase != "complete"
        else { return nil }
        return plan
      }
    } else {
      languagePlans = []
    }
    if let directory = session.cacheDirectory?.appendingPathComponent("delete-journals"),
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    {
      recycleRecords = files.compactMap { url in
        guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
          let journal = try? JSONDecoder().decode(RecycleJournal.self, from: data),
          journal.phase != "complete", journal.phase != "rolledBack"
        else { return nil }
        return RecycleRecord(journal: journal, directory: directory)
      }
    } else {
      recycleRecords = []
    }

    guard let folder = session.cacheDirectory?.appendingPathComponent("commit-journals"),
      let files = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil)
    else {
      records = []
      return
    }
    records = files.filter {
      $0.pathExtension == "json" && !$0.lastPathComponent.contains("-metadata")
    }.compactMap { url in
      guard let data = try? Data(contentsOf: url),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let id = value["id"] as? String, let phase = value["phase"] as? String
      else { return nil }
      return OrganizationRecord(
        id: id, source: value["source"] as? String ?? "",
        destination: value["destination"] as? String ?? "", phase: phase, json: url)
    }.sorted { $0.id > $1.id }
  }
  private func recoverLanguages(_ plan: OrganizationJournal) {
    recovering = true
    status = ""
    let owner = session.account?.ownerId
    Task {
      defer { recovering = false }
      do {
        try await session.synchronize()
        guard owner == session.account?.ownerId, owner == plan.libraryId,
          let directory = session.cacheDirectory?.appendingPathComponent("organization-journals"),
          let current = session.entities.first(where: { $0.id == plan.entityId && !$0.deleted })
        else { throw LoginError.invalidToken }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let committed = try encoder.encode(current.input) == encoder.encode(plan.metadata)
        guard committed || current.revision == plan.revision else {
          throw LoginError.server("The chapter changed. Review its metadata before recovery.")
        }
        let root = try library.local.rootURL(plan.rootId)
        guard root.standardizedFileURL.path == plan.root else { throw StorageError.unsafePath }
        var leased: [URL] = []
        defer { leased.forEach { $0.stopAccessingSecurityScopedResource() } }
        for id in Set(plan.sourceRootIds + [plan.rootId]) {
          let folder = try library.local.rootURL(id)
          if folder.startAccessingSecurityScopedResource() { leased.append(folder) }
        }
        let staged =
          committed
          ? plan : try await FileTasks.perform { try FileOrganization.stage(plan, in: directory) }
        guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
        if !committed { try await session.update(current, input: plan.metadata) }
        guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
        try await FileTasks.perform { try FileOrganization.finish(staged, in: directory) }
        library.fileQueue.finishRecoveredChapter(plan.entityId)
        status = "Language folders organized."
        load()
      } catch { status = error.localizedDescription }
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
        ForEach(queue.items) { item in
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
            if item.failed { Button("Retry") { queue.retry(item.id) } }
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
      !fileQueue.manages(current.id)
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
    guard let destination = entity(plan.rootId), destination.isArchiveDestination,
      let journals = session.cacheDirectory?.appendingPathComponent("commit-journals")
    else {
      throw LoginError.server(
        "Connect this version's archive folder in Media Storage before changing its language.")
    }
    let root = try await local.validateDestinationAsync(destination)
    let source = try await FileTasks.perform {
      try PathPolicy.mutationPath(oldDirectory, under: root)
    }
    let accessing = root.startAccessingSecurityScopedResource()
    defer { if accessing { root.stopAccessingSecurityScopedResource() } }
    // A folder may also back another chapter or another media version. Keep
    // its originals whenever any such reference still points into that folder.
    let prefix = source.standardizedFileURL.path.lowercased() + "/"
    let referencedMedia = session.entities.filter { !$0.deleted }.flatMap { other in
      other.media.filter { other.id != current.id || $0.id != plan.mediaId }
    }
    let referenceRoots = try await local.referenceRoots(for: referencedMedia)
    let keepSource = try await FileTasks.perform {
      var roots = [String: URL]()
      for (id, connected) in referenceRoots {
        roots[id] = connected.resolvingSymlinksInPath().standardizedFileURL
      }
      for media in referencedMedia {
        try Task.checkCancellation()
        guard let otherRoot = roots[media.storageRootId] else { continue }
        if media.relativePaths.contains(where: {
          otherRoot.appendingPathComponent($0).standardizedFileURL.path.lowercased().hasPrefix(
            prefix)
        }) {
          return true
        }
      }
      return false
    }
    let payload = try JSONSerialization.data(withJSONObject: [
      "entityId": current.id, "revision": current.revision,
      "sourceRootId": plan.rootId, "destinationRootId": plan.rootId,
      "metadata": JSONSerialization.jsonObject(with: JSONEncoder().encode(plan.metadata)),
    ])
    try await FileTasks.perform {
      _ = try PathPolicy.mutationPath(oldDirectory, under: root)
      let target = try PathPolicy.mutationPath(newDirectory, under: root)
      guard !FileManager.default.fileExists(atPath: target.path) else {
        throw StorageError.collision
      }
    }
    guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
    do {
      let shared = keepSource
      let receipt = try await FileTasks.perform {
        try FileCommit.move(
          source: source, destinationRelativePath: newDirectory, root: root,
          journalDirectory: journals, recoveryPayload: payload, copyBeforeCommit: true,
          keepSource: shared)
      }
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      _ = try await local.validateDestinationAsync(destination)
      try await session.update(current, input: plan.metadata)
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      _ = try await local.validateDestinationAsync(destination)
      try await FileTasks.perform { try FileCommit.finish(receipt, in: journals) }
      guard let updated = session.entities.first(where: { $0.id == current.id && !$0.deleted })
      else {
        throw LoginError.invalidToken
      }
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
