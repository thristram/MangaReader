import Foundation
import MangaCore
import SwiftUI

struct TextTranslationJob: Codable, Identifiable, Sendable {
  var id = UUID()
  let owner: String
  var entityId: String?
  let draftId: UUID?
  let title: String
  let field: String
  let language: String
  let source: String
  let previousTranslation: String?
  var settings: OllamaTranslator.Settings
  var chunks: [String]
  var outputs: [String?]
  var status = "queued"
  var error = ""
  var addedAt = Date()
  var finished: Int { outputs.compactMap { $0 }.count }
  var result: String? { finished == chunks.count ? outputs.compactMap { $0 }.joined() : nil }
  var active: Bool { ["queued", "running", "saving"].contains(status) }
}

private actor TextTranslationStore {
  private var versions: [String: Int] = [:]
  func save(_ jobs: [TextTranslationJob], directory: URL, version: Int) throws {
    guard version >= versions[directory.path, default: 0] else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(jobs).write(to: directory.appendingPathComponent("text-translations.json"), options: .atomic)
    versions[directory.path] = version
  }
  func load(_ directory: URL) throws -> [TextTranslationJob] {
    let file = directory.appendingPathComponent("text-translations.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try JSONDecoder().decode([TextTranslationJob].self, from: Data(contentsOf: file))
  }
}

@MainActor final class TextTranslationQueue: ObservableObject {
  @Published private(set) var jobs: [TextTranslationJob] = []
  @Published var showingJobs = false
  private weak var library: LibraryUIModel?
  private let transport: URLSession
  private let store = TextTranslationStore()
  private var task: Task<Void, Never>?
  private var epoch = UUID()
  private var version = 0
  private var restoredOwner: String?
  init(library: LibraryUIModel, transport: URLSession = .shared) { self.library = library; self.transport = transport }
  var activeCount: Int { jobs.filter(\.active).count }
  func active(entity: String, field: String, language: String) -> TextTranslationJob? {
    jobs.first { $0.entityId == entity && $0.field == field && $0.language == language && $0.active }
  }
  func reset() {
    epoch = UUID(); task?.cancel(); task = nil; restoredOwner = nil; jobs = []; showingJobs = false
  }
  func attachDraft(_ draft: UUID, entity: LibraryEntity) {
    for index in jobs.indices where jobs[index].draftId == draft && jobs[index].entityId == nil {
      let source = jobs[index].field == "title" ? entity.title : entity.description
      if source == jobs[index].source { jobs[index].entityId = entity.id }
    }
    checkpoint()
  }
  func restore() async {
    guard let session = library?.session, let owner = session.account?.ownerId,
      let directory = session.cacheDirectory, restoredOwner != owner else { return }
    restoredOwner = owner
    let generation = epoch
    do {
      let saved = try await store.load(directory)
      guard epoch == generation, session.account?.ownerId == owner else { return }
      // A just-enqueued job may already exist while disk restore was suspended.
      let existing = Set(jobs.map(\.id))
      jobs += saved.filter { $0.owner == owner && !existing.contains($0.id) }.map {
        var job = $0
        if job.active { job.status = "queued" }
        return job
      }
      start()
    } catch { if epoch == generation { library?.show(error) } }
  }
  @discardableResult func enqueue(entity: LibraryEntity?, draft: UUID? = nil,
    title: String, field: String, source: String, language: String,
    draftTranslation: LocalizedText? = nil,
    defaults: UserDefaults = .standard) async throws -> UUID {
    guard ["title", "description"].contains(field), let session = library?.session,
      let owner = session.account?.ownerId, session.account?.scopes.contains("manga:manage") == true
    else { throw LoginError.invalidToken }
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw LoginError.server("There is no source text to translate.") }
    let limit = field == "title" ? 500 : 500000
    guard source.utf16.count <= limit else {
      throw LoginError.server("Source \(field) exceeds \(limit.formatted()) UTF-16 code units. Split this text before translating.")
    }
    await restore()
    if let entity, let current = active(entity: entity.id, field: field, language: language) { return current.id }
    let generation = epoch, settings = OllamaTranslator.Settings(defaults: defaults)
    guard !settings.model.isEmpty else { throw LoginError.server("Choose an Ollama model in Translation settings.") }
    let chunks = try await Task.detached { try TextChunker.chunks(source, maximum: settings.maximumCharacters) }.value
    guard epoch == generation, session.account?.ownerId == owner else { throw CancellationError() }
    if let entity, let current = active(entity: entity.id, field: field, language: language) { return current.id }
    let old: LocalizedText?
    if let entity { old = entity.localizations[language] } else { old = draftTranslation }
    let job = TextTranslationJob(owner: owner, entityId: entity?.id, draftId: draft,
      title: title, field: field, language: language, source: source,
      previousTranslation: field == "title" ? old?.title : old?.description,
      settings: settings, chunks: chunks, outputs: Array(repeating: nil, count: chunks.count))
    jobs.insert(job, at: 0)
    do { try await persist() }
    catch { jobs.removeAll { $0.id == job.id }; throw error }
    start(); return job.id
  }
  func cancel(_ id: UUID) {
    let wasRunning = jobs.first { $0.id == id }.map { ["running", "saving"].contains($0.status) } ?? false
    change(id) { $0.status = "cancelled"; $0.error = "Cancelled. Completed chunks are retained." }
    if wasRunning { task?.cancel() }
    checkpoint()
  }
  func retry(_ id: UUID) {
    guard jobs.first(where: { $0.id == id })?.active == false else { return }
    change(id) { $0.status = "queued"; $0.error = "" }
    checkpoint(); start()
  }
  func remove(_ id: UUID) {
    cancel(id); jobs.removeAll { $0.id == id }; checkpoint()
  }
  func restart(_ id: UUID) async throws {
    guard let job = jobs.first(where: { $0.id == id }), !job.active else { return }
    let settings = OllamaTranslator.Settings(), generation = epoch
    let chunks = try await Task.detached { try TextChunker.chunks(job.source, maximum: settings.maximumCharacters) }.value
    guard generation == epoch else { throw CancellationError() }
    change(id) { $0.settings = settings; $0.chunks = chunks; $0.outputs = Array(repeating: nil, count: chunks.count); $0.status = "queued"; $0.error = "" }
    try await persist(); start()
  }
  private func change(_ id: UUID, _ update: (inout TextTranslationJob) -> Void) {
    guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }; update(&jobs[i])
  }
  private func persist() async throws {
    guard let directory = library?.session.cacheDirectory else { throw LoginError.invalidToken }
    version += 1
    try await store.save(jobs, directory: directory, version: version)
  }
  private func checkpoint() {
    guard let directory = library?.session.cacheDirectory else { return }
    version += 1
    let values = jobs, snapshotVersion = version, generation = epoch
    Task {
      do { try await store.save(values, directory: directory, version: snapshotVersion) }
      catch { if epoch == generation { library?.show(error) } }
    }
  }
  private func start() {
    guard task == nil else { return }
    let generation = epoch
    task = Task {
      defer {
        if epoch == generation { task = nil; if jobs.contains(where: { $0.status == "queued" }) { start() } }
      }
      while !Task.isCancelled, epoch == generation, let job = jobs.last(where: { $0.status == "queued" }) {
        do {
          change(job.id) { $0.status = "running" }; try await persist()
          for index in job.chunks.indices {
            try validate(job, generation: generation)
            if jobs.first(where: { $0.id == job.id })?.outputs[index] != nil { continue }
            let text = try await OllamaTranslator.translateChunk(job.chunks[index], language: job.language, settings: job.settings, session: transport)
            try validate(job, generation: generation)
            change(job.id) { $0.outputs[index] = text }; try await persist()
          }
          try validate(job, generation: generation)
          change(job.id) { $0.status = "saving" }
          try await publish(job.id, generation: generation)
          try validate(job, generation: generation)
          change(job.id) { $0.status = "completed"; $0.error = "" }; try await persist()
        } catch {
          guard epoch == generation else { return }
          if let status = jobs.first(where: { $0.id == job.id })?.status, ["running", "saving"].contains(status) {
            change(job.id) { $0.status = "failed"; $0.error = error.localizedDescription }
          }
          do { try await persist() } catch { library?.show(error) }
        }
      }
    }
  }
  private func validate(_ job: TextTranslationJob, generation: UUID) throws {
    try Task.checkCancellation()
    guard generation == epoch, library?.session.account?.ownerId == job.owner,
      jobs.first(where: { $0.id == job.id })?.active == true else { throw CancellationError() }
  }
  private func publish(_ id: UUID, generation: UUID) async throws {
    guard let job = jobs.first(where: { $0.id == id }), let output = job.result else { return }
    guard let entityID = job.entityId else { return } // Draft: result stays available for Save/copy.
    guard let library else { throw CancellationError() }
    for attempt in 0..<2 {
      try validate(job, generation: generation)
      guard let current = library.session.entities.first(where: { $0.id == entityID && !$0.deleted })
      else { throw LoginError.server("This item was deleted. The translated chunks are retained.") }
      guard (job.field == "title" ? current.title : current.description) == job.source else {
        throw LoginError.server("The source text changed. Cached translations are retained; review before starting a new job.")
      }
      var input = current.input, localized = input.localizations[job.language] ?? LocalizedText()
      let previous = job.field == "title" ? localized.title : localized.description
      if previous == output { return } // Reconcile a save whose response was lost.
      guard previous == job.previousTranslation else {
        throw LoginError.server("This translation was edited while the job ran. Cached output is retained; the newer text was not overwritten.")
      }
      if job.field == "title" { localized.title = output } else { localized.description = output }
      input.localizations[job.language] = localized
      do { try await library.session.update(current, input: input); return }
      catch let error as APIError where error.status == 409 && attempt == 0 {
        try await library.session.reloadEntity(entityID)
      }
    }
  }
}

struct TextTranslationJobsView: View {
  @ObservedObject var queue: TextTranslationQueue
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    LazyVStack(alignment: .leading, spacing: 16) {
      if queue.jobs.isEmpty { Text("No text translation jobs").foregroundStyle(.secondary) }
      ForEach(queue.jobs.filter { $0.entityId.map { library.entity($0) != nil } ?? true }) { job in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(job.title).font(.headline).lineLimit(2)
            Spacer()
            Text(job.language.uppercased()).font(.caption)
            if job.active { Button("Cancel") { queue.cancel(job.id) } }
            else if job.status != "completed" { Button("Retry") { queue.retry(job.id) } }
            if !job.active { Button("Remove", role: .destructive) { queue.remove(job.id) } }
          }
          ProgressView(value: Double(job.finished), total: Double(max(1, job.chunks.count)))
          Text("\(job.field.capitalized) · \(job.finished) / \(job.chunks.count) chunks · \(job.status.capitalized)")
            .font(.caption).foregroundStyle(.secondary)
          if !job.error.isEmpty {
            Text(job.error).foregroundStyle(.orange).textSelection(.enabled)
            Button("Restart with current settings") { Task { do { try await queue.restart(job.id) } catch { library.show(error) } } }
          }
          if let result = job.result {
            ShareLink(item: result) { Label(job.entityId == nil ? "Share translated draft" : "Share translated text", systemImage: "square.and.arrow.up") }
          }
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
      }
    }.task { await queue.restore() }
  }
}

struct TextTranslationQueueSheet: View {
  @ObservedObject var queue: TextTranslationQueue
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView { TextTranslationJobsView(queue: queue).padding(20) }
        .navigationTitle("Text Translation Queue")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    #if os(macOS)
      .frame(minWidth: 560, minHeight: 420)
    #endif
  }
}

struct TextTranslationQueueButton: View {
  @ObservedObject var queue: TextTranslationQueue
  @State private var showing = false
  var body: some View {
    Button { showing = true } label: {
      Label(queue.activeCount > 0 ? "Translations (\(queue.activeCount))" : "Text Translation Queue", systemImage: "character.bubble")
    }.sheet(isPresented: $showing) { TextTranslationQueueSheet(queue: queue) }
  }
}

struct TextTranslationProgress: View {
  @ObservedObject var queue: TextTranslationQueue
  let entityId: String?
  let draftId: UUID
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(queue.jobs.filter { job in job.active && (entityId.map { job.entityId == $0 } ?? (job.draftId == draftId)) }) { job in
        ProgressView("\(job.field.capitalized): \(job.finished) / \(job.chunks.count) chunks", value: Double(job.finished), total: Double(max(1, job.chunks.count)))
      }
      TextTranslationQueueButton(queue: queue)
    }
  }
}
