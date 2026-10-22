import MangaCore
import SwiftUI

struct ImageTranslationOptionsFields: View {
  @Binding var options: MangaImageTranslationOptions
  var body: some View {
    Section("Translation") {
      Picker("Translator", selection: $options.translator) {
        ForEach(MangaImageTranslationOptions.translators, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
      }
      Picker("Target language", selection: $options.targetLanguage) {
        ForEach(MangaImageTranslationOptions.languages, id: \.api) { Text($0.name).tag($0.api) }
      }
    }
    Section("Detection & Rendering") {
      Picker("Detection resolution", selection: $options.detectionSize) {
        ForEach(MangaImageTranslationOptions.detectionSizes, id: \.self) { Text("\($0) px").tag($0) }
      }
      Picker("Text detector", selection: $options.detector) {
        ForEach(MangaImageTranslationOptions.detectors, id: \.self) { Text($0 == "ctd" ? "CTD" : $0.capitalized).tag($0) }
      }
      Picker("Render text direction", selection: $options.direction) {
        ForEach(MangaImageTranslationOptions.directions, id: \.self) { Text($0.capitalized).tag($0) }
      }
      TextField("Unclip ratio", value: $options.unclipRatio, format: .number).help("Greater than 0, up to 10. Default: 2.3")
      TextField("Box threshold", value: $options.boxThreshold, format: .number).help("0–1. Default: 0.7")
    }
    Section("Inpainting") {
      Picker("Inpainting size", selection: $options.inpaintingSize) {
        ForEach(MangaImageTranslationOptions.inpaintingSizes, id: \.self) { Text("\($0) px").tag($0) }
      }
      Picker("Inpainter", selection: $options.inpainter) {
        ForEach(MangaImageTranslationOptions.inpainters, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
      }
      TextField("Mask dilation offset", value: $options.maskDilationOffset, format: .number).help("0–200. Default: 30")
    }
  }
}

struct MangaImageTranslationSettingsScreen: View {
  @AppStorage("ImageTranslationURL") private var baseURL = MangaImageTranslationService.defaultBaseURL
  @State private var options = MangaImageTranslationOptions.load()
  @State private var testing = false
  @State private var status = ""
  var body: some View {
    Form {
      Section("Image Translation Service") {
        TextField("Service base URL", text: $baseURL).fullFieldFocus()
        HStack {
          Button(testing ? "Connecting…" : "Test Connection") {
            testing = true
            let endpoint = baseURL
            Task {
              defer { testing = false }
              do {
                try await MangaImageTranslationService(baseURL: endpoint).testConnection()
                if endpoint == baseURL { status = "Connected · image translation API available." }
              } catch { if endpoint == baseURL { status = error.localizedDescription } }
            }
          }.disabled(testing)
          if testing { ProgressView().controlSize(.small) }
        }
        if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
        Text("Run manga-image-translator separately. The Mac sends pages directly to this URL. Translator models and provider credentials are configured on that service.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ImageTranslationOptionsFields(options: $options)
      Section {
        Text("These defaults also appear in Translate Manga. Valid changes are saved automatically. Existing queued jobs keep the settings they started with.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Restore Default Options") { options = MangaImageTranslationOptions() }
      }
    }.formStyle(.grouped)
      .onChange(of: options) { _, next in
        do { try next.save(); status = "Default translation options saved." }
        catch { status = error.localizedDescription }
      }
  }
}

struct TranslateMangaScreen: View {
  let chapter: LibraryEntity
  let onQueued: () -> Void
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @Environment(\.dismiss) private var dismiss
  @AppStorage("ImageTranslationURL") private var baseURL = MangaImageTranslationService.defaultBaseURL
  @State private var options = MangaImageTranslationOptions.load()
  @State private var sourceId = ""
  @State private var destinationId = ""
  @State private var connecting = false
  @State private var connected = false
  @State private var enqueuing = false
  @State private var status = ""
  private var source: MediaVersion? { chapter.media.first { $0.id == sourceId } }
  private var optionsValid: Bool { (try? options.validate()) != nil }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SheetHeading("Translate Manga", inset: 24)
      Text(library.title(chapter)).font(.headline).padding(.horizontal, 24).padding(.bottom, 8)
      Form {
        Section("Source & Destination") {
          Picker("Source media", selection: $sourceId) {
            ForEach(chapter.media.filter { $0.kind != "video" }) { Text($0.languageLabel + " · \($0.pageCount) pages").tag($0.id) }
          }
          Picker("Move translated pages to", selection: $destinationId) {
            Text("Choose archive destination").tag("")
            ForEach(session.entities.filter(\.isArchiveDestination)) { Text($0.title).tag($0.id) }
          }
          LabeledContent("Service", value: baseURL).textSelection(.enabled)
          HStack {
            if connecting { ProgressView().controlSize(.small) }
            Label(connected ? "Connected" : "Service unavailable", systemImage: connected ? "checkmark.circle" : "exclamationmark.triangle")
              .foregroundStyle(connected ? Color.secondary : Color.orange)
            Spacer()
            Button("Test Connection") { Task { await connect() } }.disabled(connecting || enqueuing)
          }
          if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
        }
        ImageTranslationOptionsFields(options: $options)
        Section {
          Text("Translate unfinished pages in the background. Each successful page is added to the target language and organized automatically. Existing translated pages stay unchanged; other pages fall back to the original. Closing this window does not stop a queued job.")
            .font(.callout).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped).disabled(enqueuing)
      Divider()
      HStack {
        Button("Cancel") { dismiss() }.disabled(enqueuing)
        Spacer()
        Button(enqueuing ? "Adding to Queue…" : "Translate Manga") {
          guard let source else { return }
          enqueuing = true
          Task {
            defer { enqueuing = false }
            do {
              _ = try await library.translationQueue.enqueue(chapter: chapter, source: source,
                options: options, baseURL: baseURL, destinationId: destinationId)
              onQueued()
              dismiss()
            } catch { status = error.localizedDescription }
          }
        }.buttonStyle(.borderedProminent)
          .disabled(!connected || connecting || enqueuing || source == nil || destinationId.isEmpty || !optionsValid)
      }.padding(20)
    }.frame(width: 680, height: 800).interactiveDismissDisabled(enqueuing)
      .onAppear {
        sourceId = chapter.media.first { $0.language == chapter.originalLanguage && $0.kind != "video" }?.id
          ?? chapter.media.first { $0.kind != "video" }?.id ?? ""
        let destinations = session.entities.filter(\.isArchiveDestination)
        destinationId = destinations.first { $0.id == chapter.media.first?.storageRootId }?.id ?? destinations.first?.id ?? ""
      }
      .task(id: baseURL) { await connect() }
      .onChange(of: options) { _, next in
        do { try next.save() } catch { status = error.localizedDescription }
      }
  }
  private func connect() async {
    let endpoint = baseURL
    connecting = true
    connected = false
    defer { connecting = false }
    do {
      try await MangaImageTranslationService(baseURL: endpoint).testConnection()
      try Task.checkCancellation()
      if endpoint == baseURL { connected = true; status = "" }
    } catch { if endpoint == baseURL { status = error.localizedDescription } }
  }
}

struct MangaTranslationQueueScreen: View {
  @ObservedObject var queue: MangaTranslationQueue
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @AppStorage("ShowNSFW") private var showNSFW = false
  @State private var chapterId: String?
  private var groups: [(String, [MangaTranslationJob])] {
    Dictionary(grouping: queue.jobs.filter { library.entity($0.chapterId) != nil }, by: \.chapterId).map { ($0.key, $0.value.sorted { $0.addedAt > $1.addedAt }) }
      .sorted { ($0.1.first?.addedAt ?? .distantPast) > ($1.1.first?.addedAt ?? .distantPast) }
  }
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if groups.isEmpty {
          ContentUnavailableView("No translation jobs", systemImage: "character.bubble",
            description: Text("Choose Translate Manga in Edit Chapter to translate image or PDF pages."))
        }
        ForEach(groups, id: \.0) { chapter, jobs in
          VStack(alignment: .leading, spacing: 14) {
            Button { chapterId = chapter } label: {
              Label(jobs.first?.title ?? "Chapter", systemImage: "photo.stack").font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ForEach(jobs) { job in
              VStack(alignment: .leading, spacing: 9) {
                HStack {
                  Text(job.options.mediaLanguage.uppercased()).font(.headline)
                  Text(job.addedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                  Spacer()
                  if job.status == "running" { ProgressView().controlSize(.small) }
                  if job.status == "failed" { Button("Retry") { queue.retry(job.id) } }
                  if job.status == "completed" { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if !job.description.isEmpty { Text(job.description).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                ProgressView(value: job.progress)
                Text("\(job.finishedCount) / \(job.pages.count) pages · " + job.detail).font(.caption).foregroundStyle(.secondary)
                if !job.error.isEmpty { Text(job.error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
              }
            }
          }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
      }.padding(28)
    }.task { await queue.restore() }
      .onChange(of: showNSFW) { _, _ in closeHiddenChapter() }
      .onChange(of: session.metadataGeneration) { _, _ in closeHiddenChapter() }
      .sheet(isPresented: Binding(get: { chapterId != nil }, set: { if !$0 { chapterId = nil } })) {
        if let chapterId, library.entity(chapterId) != nil { MangaTranslationPagesScreen(queue: queue, chapterId: chapterId) }
      }
  }
  private func closeHiddenChapter() {
    if let chapterId, library.entity(chapterId) == nil { self.chapterId = nil }
  }
}
struct TranslationPagePreviewRequest: Identifiable {
  let id = UUID()
  let job: MangaTranslationJob
  let page: MangaTranslationPage
}
struct MangaTranslationPagesScreen: View {
  @ObservedObject var queue: MangaTranslationQueue
  let chapterId: String
  @EnvironmentObject private var library: LibraryUIModel
  @Environment(\.dismiss) private var dismiss
  @State private var preview: TranslationPagePreviewRequest?
  private var jobs: [MangaTranslationJob] { queue.jobs.filter { $0.chapterId == chapterId } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(jobs.first?.title ?? "Translated Pages").font(.title2.bold())
        Spacer()
        Button("Close") { dismiss() }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          ForEach(jobs) { job in
            Text(job.options.mediaLanguage.uppercased() + " · " + job.detail).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 20) {
              ForEach(job.pages.filter { $0.cachedName != nil || $0.status == "existing" }) { page in
                Button { preview = TranslationPagePreviewRequest(job: job, page: page) } label: {
                  VStack {
                    if let url = queue.outputURL(job: job, page: page) {
                      PagePreview(url: url, kind: "images", index: 0, contentMode: .fit)
                        .frame(height: 190).background(.black.opacity(0.2))
                    } else if let media = library.entity(chapterId)?.media.first(where: { $0.id == job.targetMediaId }),
                      let index = media.sourcePage(at: page.canonical) {
                      MediaPagePreview(media: media, index: index).frame(height: 190)
                    }
                    Text("Page \(page.canonical + 1)").font(.caption)
                    Text(page.status == "committed" || page.status == "existing" ? "In library" : "Cached · awaiting file commit")
                      .font(.caption2).foregroundStyle(.secondary)
                  }
                }.buttonStyle(.plain)
              }
            }
            ForEach(job.pages.filter { !$0.error.isEmpty }) { page in
              Text("Page \(page.canonical + 1): " + page.error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
          }
        }
      }
    }.padding(24).frame(width: 820, height: 650)
      .sheet(item: $preview) { request in TranslationOutputPreview(queue: queue, request: request) }
  }
}
struct TranslationOutputPreview: View {
  @ObservedObject var queue: MangaTranslationQueue
  let request: TranslationPagePreviewRequest
  @EnvironmentObject private var library: LibraryUIModel
  @Environment(\.dismiss) private var dismiss
  @State private var url: URL?
  @State private var error = ""
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Page \(request.page.canonical + 1) · " + request.job.options.mediaLanguage.uppercased()).font(.headline)
        Spacer()
        Button("Close") { dismiss() }
      }
      if let url { NativeReadingPage(url: url, onSwipe: { _ in }).background(.black) }
      else if !error.isEmpty { Text(error).foregroundStyle(.orange) }
      else { ProgressView("Loading translated page…").frame(maxHeight: .infinity) }
    }.padding(20).frame(width: 850, height: 700)
      .task {
        if let cached = queue.outputURL(job: request.job, page: request.page) { url = cached; return }
        do {
          guard let media = library.entity(request.job.chapterId)?.media.first(where: { $0.id == request.job.targetMediaId }),
            let index = media.sourcePage(at: request.page.canonical) else { throw StorageError.emptyChapter }
          url = try await library.mediaURL(media, index: index)
        } catch { self.error = error.localizedDescription }
      }
  }
}

struct OrganizationSidebarStatus: View {
  let page: LibraryPage
  @ObservedObject var fileQueue: ImportFileQueue
  @ObservedObject var translationQueue: MangaTranslationQueue
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    Group {
      if page == .unorganized {
        let count = library.temporaryOrganizationRows().count
        if count > 0 { Text("\(count)").font(.caption.bold()).monospacedDigit() }
      } else if page == .fileManagement {
        if fileQueue.pendingCount > 0 {
          ProgressView().controlSize(.mini).accessibilityLabel("File tasks pending")
        } else if fileQueue.hasErrors {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("File tasks failed")
        }
      } else if page == .translationQueue {
        if translationQueue.pendingCount > 0 {
          ProgressView().controlSize(.mini).accessibilityLabel("Translations pending")
        } else if translationQueue.hasErrors {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Translations failed")
        }
      }
    }
  }
}
