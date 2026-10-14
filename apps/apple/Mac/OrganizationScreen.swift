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
struct OrganizationScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @State private var records: [OrganizationRecord] = []
  @State private var selected: OrganizationRecord?
  @State private var recovering = false
  @State private var status = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text("File changes are reviewed before commit.").foregroundStyle(.secondary)
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise", action: load)
        }
        if records.isEmpty {
          ContentUnavailableView(
            "No pending file changes", systemImage: "folder.badge.checkmark",
            description: Text(
              "Reviewed import moves and recovery records appear here."))
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
          Text("Review Commit Recovery").font(.title2.bold())
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
  }
  private func load() {
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
  private func recover(_ record: OrganizationRecord) {
    recovering = true
    status = ""
    let owner = session.account?.ownerId
    Task {
      defer { recovering = false }
      do {
        guard FileManager.default.fileExists(atPath: record.destination),
          !FileManager.default.fileExists(atPath: record.source),
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
          current.revision == revision, session.account?.ownerId == owner
        else {
          throw LoginError.server(
            "Metadata changed since this plan. Review the journal before applying a new plan.")
        }
        let input = try JSONDecoder().decode(
          MetadataInput.self, from: JSONSerialization.data(withJSONObject: metadata))
        try await session.update(current, input: input)
        guard session.account?.ownerId == owner else { return }
        var journal =
          try JSONSerialization.jsonObject(with: Data(contentsOf: record.json)) as! [String: Any]
        journal["phase"] = "complete"
        try JSONSerialization.data(withJSONObject: journal).write(to: record.json, options: .atomic)
        status = "Metadata reconciled. Files were not moved again."
        load()
      } catch { status = error.localizedDescription }
    }
  }
}
