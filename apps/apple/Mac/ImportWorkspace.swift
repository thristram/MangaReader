import Foundation
import MangaCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ImportWorkspaceModel: ObservableObject {
  let library: LibraryUIModel
  @Published var queue: [ImportCandidate] = []
  @Published var index = 0
  @Published var input = MetadataInput(
    kind: .chapter, title: "", originalLanguage: AppConfiguration.preferredLanguage)
  @Published var translationOf: String?
  @Published var pageAlignment: [Int?] = []
  private var processing: Task<Void, Never>?
  @Published var busy = false
  @Published var status = ""
  @Published var result = ""
  @Published var destination: URL?
  @Published var review = false
  var leases: [URL] = []
  init(library: LibraryUIModel) { self.library = library }
  var current: ImportCandidate? { queue.indices.contains(index) ? queue[index] : nil }
  func managedPath() throws -> String {
    let author = library.session.entities.first { $0.id == input.authorId }?.title
    let work = library.session.entities.first { $0.id == input.workId }
    let series = library.session.entities.first { $0.id == (input.seriesId ?? work?.seriesId) }?
      .title
    return try PathPolicy.chapterPath(
      author: author, series: series, work: work?.title, chapter: input.title,
      language: input.originalLanguage, mediaLanguageCount: 1)
  }
  var proposedPath: String {
    (try? managedPath()) ?? "Use names without /, \\, or : before moving files."
  }
  func append(_ urls: [URL]) {
    for url in urls {
      _ = url.startAccessingSecurityScopedResource()
      leases.append(url)
      do { queue.append(contentsOf: try ImportScanner.scan(url)) } catch {
        status = error.localizedDescription
      }
    }
    if input.title.isEmpty { select(index) }
  }
  func select(_ index: Int) {
    guard queue.indices.contains(index) else { return }
    self.index = index
    translationOf = nil
    pageAlignment = []
    result = ""
    input = MetadataInput(
      kind: .chapter, title: queue[index].title,
      originalLanguage: AppConfiguration.preferredLanguage)
    status = queue[index].warnings.joined(separator: " ")
  }
  func close() {
    processing?.cancel()
    processing = nil
    leases.forEach { $0.stopAccessingSecurityScopedResource() }
    leases = []
  }
  func process(move: Bool) {
    guard !busy, let candidate = current, !input.title.trimmingCharacters(in: .whitespaces).isEmpty
    else { return }
    busy = true
    status = "Adding chapter…"
    let owner = library.session.account?.ownerId
    processing = Task {
      defer {
        busy = false
        processing = nil
      }
      @MainActor func checkOwner() throws {
        try Task.checkCancellation()
        guard owner != nil, owner == library.session.account?.ownerId else {
          throw LoginError.invalidToken
        }
      }
      do {
        try checkOwner()
        if move { _ = try managedPath() }
        guard move == false || (destination != nil && candidate.warnings.isEmpty) else {
          throw LoginError.server("Choose a managed folder before committing the move.")
        }
        let session = library.session
        if let translationOf, library.entity(translationOf) == nil {
          throw LoginError.server(
            "The original chapter is unavailable or hidden. Choose another chapter.")
        }
        var metadata = input
        if let translationOf,
          let original = session.visibleEntities(kind: .chapter).first(where: {
            $0.id == translationOf
          })
        {
          metadata.authorId = original.authorId
          metadata.workId = original.workId
          metadata.seriesId = original.seriesId
        }
        if metadata.authorId == nil {
          let existing = session.entities.first {
            $0.kind == .author && !$0.deleted && $0.title == "other author"
          }
          if let existing {
            metadata.authorId = existing.id
          } else {
            metadata.authorId = try await session.create(
              .init(kind: .author, title: "other author")
            ).id
          }
        }
        if metadata.seriesId == nil {
          metadata.seriesId = session.entities.first { $0.id == metadata.workId }?.seriesId
        }
        try checkOwner()
        let folder =
          candidate.kind == "images"
          ? candidate.source : candidate.source.deletingLastPathComponent()
        let root = try await session.create(
          .init(kind: .storageRoot, title: folder.lastPathComponent, storageKind: "local"))
        try checkOwner()
        try library.local.bind(root, to: folder)
        let count =
          candidate.kind == "pdf"
          ? PDFDocument(url: candidate.source)?.pageCount ?? 1
          : candidate.kind == "video" ? 1 : candidate.pages.count
        var version = MediaVersion(
          language: metadata.originalLanguage, kind: candidate.kind, storageRootId: root.id,
          relativePaths: candidate.pages.map(\.lastPathComponent), pageCount: count)
        var chapter: LibraryEntity
        if let translationOf,
          let original = session.entities.first(where: { $0.id == translationOf && !$0.deleted })
        {
          guard !original.media.contains(where: { $0.language == version.language }) else {
            throw LoginError.server(
              "This chapter already has that media language. Choose another language.")
          }
          version.pageAlignment =
            pageAlignment.isEmpty
            ? (0..<(original.media.first?.pageCount ?? 0)).map { $0 < count ? $0 : nil }
            : pageAlignment
          var combined = original.input
          combined.media.append(version)
          try await session.update(original, input: combined)
          chapter = session.entities.first { $0.id == original.id } ?? original
        } else {
          metadata.media = [version]
          chapter = try await session.create(metadata)
        }
        guard owner == session.account?.ownerId else { return }
        if move, let destination {
          let managed = try await session.create(
            .init(kind: .storageRoot, title: "Managed Library", storageKind: "local"))
          try checkOwner()
          try library.local.bind(managed, to: destination)
          let path = try managedPath()
          let relative =
            candidate.kind == "images" ? path : path + "/" + candidate.source.lastPathComponent
          guard let journals = session.cacheDirectory?.appendingPathComponent("commit-journals")
          else { throw LoginError.invalidToken }
          var update = chapter.input
          guard let position = update.media.firstIndex(where: { $0.id == version.id }) else {
            throw LoginError.server("The imported media is missing from metadata.")
          }
          update.media[position].storageRootId = managed.id
          update.media[position].relativePaths =
            candidate.kind == "images"
            ? candidate.pages.map { path + "/" + $0.lastPathComponent } : [relative]
          let recovery = try JSONSerialization.data(withJSONObject: [
            "entityId": chapter.id, "revision": chapter.revision,
            "metadata": JSONSerialization.jsonObject(with: JSONEncoder().encode(update)),
          ])
          try checkOwner()
          let journal = try FileCommit.move(
            source: candidate.source, destinationRelativePath: relative, root: destination,
            journalDirectory: journals, recoveryPayload: recovery)
          try await session.update(chapter, input: update)
          try FileCommit.finish(journal, in: journals)
        }
        result =
          "Added “\(candidate.title)”"
          + (move ? " and moved its files." : ". Original files kept in place.")
        queue.remove(at: index)
        if !queue.isEmpty {
          select(min(index, queue.count - 1))
        } else {
          input.title = ""
          status = "Import complete"
        }
        review = false
      } catch {
        status =
          error.localizedDescription
          + " If files moved, review Pending Organization before retrying."
      }
    }
  }
}

struct ImportScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View { ImportWorkspace(library: library) }
}
struct ImportWorkspace: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var library: LibraryUIModel
  @StateObject private var model: ImportWorkspaceModel
  @State private var choosing = false
  @State private var pickerDestination = false
  @State private var dragging = false
  @State private var creating: EditorRequest?
  @State private var alignment = false
  init(library: LibraryUIModel) {
    _model = StateObject(wrappedValue: ImportWorkspaceModel(library: library))
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Button {
          pickerDestination = false
          choosing = true
        } label: {
          HStack(spacing: 18) {
            Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.pink)
            VStack(alignment: .leading, spacing: 6) {
              Text("Drop folders, PDFs or videos").font(.title3.bold())
              Text("Drop anywhere on this page, or click to choose files.").foregroundStyle(
                .secondary)
            }
            Spacer()
            Image(systemName: "plus.circle").font(.title2)
          }.padding(24).frame(maxWidth: .infinity).background(
            dragging ? Color.pink.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 14)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 14).strokeBorder(
              .secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [6])))
        }.buttonStyle(.plain)
        if let candidate = model.current {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
              ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                Button {
                  model.select(index)
                } label: {
                  VStack(spacing: 6) {
                    FileThumbnail(url: item.pages.first).frame(width: 64, height: 84).clipShape(
                      RoundedRectangle(cornerRadius: 6))
                    Text("\(index + 1) · " + item.kind.capitalized).font(.caption2)
                  }
                  .padding(6).background(
                    index == model.index ? .pink.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(model.busy)
              }
            }
          }
          ViewThatFits(in: .horizontal) {
            reviewContent(candidate).frame(minWidth: 720)
            reviewContent(candidate, stacked: true)
          }.disabled(model.busy)
          if !model.status.isEmpty {
            Label(model.status, systemImage: "info.circle").font(.callout).foregroundStyle(
              .secondary)
          }
          Divider()
          HStack {
            Button("Skip for Now") { model.select((model.index + 1) % model.queue.count) }.disabled(
              model.busy)
            Spacer()
            Button("Add without Moving") { model.process(move: false) }.disabled(
              model.busy || model.input.title.isEmpty)
            Button("Add to Library & Move Files") {
              pickerDestination = true
              choosing = true
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
              .disabled(
                model.busy || model.input.title.isEmpty || !candidate.warnings.isEmpty
                  || model.translationOf != nil)
          }
          if model.translationOf != nil {
            Text(
              "Translation import currently keeps source files in place. Moving an existing multi-language chapter requires a separate organization plan."
            ).font(.caption).foregroundStyle(.secondary)
          }
        } else if !model.result.isEmpty {
          ContentUnavailableView(
            "Import complete", systemImage: "checkmark.circle", description: Text(model.result))
        } else {
          ContentUnavailableView(
            "Build your library", systemImage: "photo.stack",
            description: Text(
              "Folders become image chapters. Each PDF, WebM or MP4 becomes one chapter."))
        }
      }.padding(28)
    }
    .onDrop(of: [UTType.fileURL], isTargeted: $dragging) { providers in
      guard !model.busy else { return false }
      for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          if let url { Task { @MainActor in model.append([url]) } }
        }
      }
      return true
    }
    .fileImporter(
      isPresented: $choosing,
      allowedContentTypes: pickerDestination
        ? [.folder] : [.folder, .pdf, .movie, UTType(filenameExtension: "webm") ?? .movie],
      allowsMultipleSelection: !pickerDestination
    ) { result in
      do {
        let urls = try result.get()
        if pickerDestination, let url = urls.first {
          _ = url.startAccessingSecurityScopedResource()
          model.leases.append(url)
          model.destination = url
          model.review = true
        } else {
          model.append(urls)
        }
      } catch { model.status = error.localizedDescription }
    }
    .sheet(item: $creating) { request in
      MetadataEditor(
        request: request,
        onSave: { created in
          if created.kind == .author {
            model.input.authorId = created.id
          } else if created.kind == .work {
            model.input.workId = created.id
          }
        }
      ).environmentObject(library).environmentObject(session)
    }
    .sheet(isPresented: $alignment) {
      TranslationAlignmentScreen(
        candidate: model.current, original: library.entity(model.translationOf),
        mapping: $model.pageAlignment
      ).environmentObject(library)
    }
    .sheet(isPresented: $model.review) {
      NavigationStack {
        VStack(alignment: .leading, spacing: 22) {
          Label("Review File Move", systemImage: "folder.badge.gearshape").font(.title2.bold())
          Text("Review the destination, then commit to add this chapter and move its files.")
            .foregroundStyle(.secondary)
          GroupBox("Source") {
            Text(model.current?.source.path ?? "").frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          Image(systemName: "arrow.down").foregroundStyle(.pink)
          GroupBox("Destination") {
            Text((model.destination?.path ?? "") + "/" + model.proposedPath).frame(
              maxWidth: .infinity, alignment: .leading
            ).textSelection(.enabled)
          }
          Text(
            "Existing files are never overwritten. Source and destination must be on the same volume."
          ).font(.caption).foregroundStyle(.secondary)
          if !model.status.isEmpty { Text(model.status).font(.caption) }
          HStack {
            Button("Cancel") { model.review = false }.disabled(model.busy)
            Spacer()
            Button(model.busy ? "Committing…" : "Commit & Add to Library") {
              model.process(move: true)
            }.buttonStyle(.borderedProminent).disabled(model.busy)
          }
        }.padding(28).frame(width: 620)
      }
    }
    .onChange(of: model.input.workId) { _, id in
      if let work = library.entity(id) {
        model.input.authorId = work.authorId
        model.input.seriesId = work.seriesId
      }
    }
    .onChange(of: model.translationOf) { _, _ in
      model.pageAlignment = []
      if model.translationOf != nil { alignment = true }
    }
    .onDisappear { model.close() }
  }
  private func reviewContent(_ candidate: ImportCandidate, stacked: Bool = false) -> some View {
    let layout =
      stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 30))
    return layout {
      VStack(alignment: .leading, spacing: 16) {
        FileThumbnail(
          url: candidate.pages.first,
          symbol: candidate.kind == "video" ? "play.rectangle" : "book.closed"
        ).aspectRatio(0.75, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
        Text(candidate.source.lastPathComponent).font(.headline)
        Text("\(candidate.pages.count) media files · naturally sorted").font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          ForEach(Array(candidate.pages.prefix(4)), id: \.self) { url in
            FileThumbnail(url: url).frame(width: 55, height: 74).clipShape(
              RoundedRectangle(cornerRadius: 5))
          }
        }
        Divider()
        Label("After organization", systemImage: "folder").font(.headline)
        Text(model.proposedPath).font(.system(.caption, design: .monospaced)).foregroundStyle(
          .secondary
        ).textSelection(.enabled)
      }.frame(width: stacked ? nil : 260).frame(maxWidth: stacked ? 300 : nil)
      VStack(alignment: .leading, spacing: 18) {
        Text("Chapter \(model.index + 1) of \(model.queue.count)").font(.title2.bold())
        field("Chapter Name") {
          TextField("Chapter name", text: $model.input.title).textFieldStyle(.roundedBorder)
        }
        field("Author") {
          EntitySearchField(
            label: "Search existing authors", kind: .author, selected: $model.input.authorId,
            create: { creating = .init(kind: .author, initialTitle: $0) })
        }
        field("Comic (optional)") {
          EntitySearchField(
            label: "Search or create a comic", kind: .work, selected: $model.input.workId,
            create: { creating = .init(kind: .work, initialTitle: $0) })
        }
        Picker("Media language", selection: $model.input.originalLanguage) {
          ForEach(contentLanguages, id: \.code) { Text($0.name).tag($0.code) }
        }
        field("Chapter Description") {
          TextEditor(text: $model.input.description).scrollContentBackground(.hidden).frame(
            height: 95
          ).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        field("Tags") { TagTokenPicker(selected: $model.input.tagIds) }
        Toggle("NSFW · hide by default", isOn: $model.input.nsfw)
        field("Source IDs") {
          VStack(spacing: 10) {
            ForEach(["pixiv", "fanbox", "ehentai"], id: \.self) { site in
              TextField(site.capitalized + " ID / URL", text: source(site)).textFieldStyle(
                .roundedBorder)
            }
          }
        }
        DisclosureGroup("Add as a media translation") {
          EntitySearchField(
            label: "Original chapter", kind: .chapter, selected: $model.translationOf)
          if model.translationOf != nil {
            Button("Align Page Order…", systemImage: "square.split.2x1") { alignment = true }
            Text("Media translations are separate from title and description translations.").font(
              .caption
            ).foregroundStyle(.secondary)
          }
        }
      }.frame(maxWidth: .infinity)
    }
  }
  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.subheadline.weight(.medium))
      content()
    }
  }
  private func source(_ site: String) -> Binding<String> {
    Binding(
      get: { model.input.sources.first { $0.site == site }?.value ?? "" },
      set: { value in
        model.input.sources.removeAll { $0.site == site }
        if !value.isEmpty { model.input.sources.append(.init(site: site, value: value)) }
      })
  }
}
struct TranslationAlignmentScreen: View {
  var candidate: ImportCandidate?
  var original: LibraryEntity?
  @Binding var mapping: [Int?]
  @EnvironmentObject private var library: LibraryUIModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: [Int?] = []
  private var importedCount: Int {
    guard let candidate else { return 0 }
    return candidate.kind == "pdf"
      ? PDFDocument(url: candidate.source)?.pageCount ?? 0 : candidate.pages.count
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          Text(
            "Match each original page with its translated page. Unmatched pages use the original. Extra import pages stay in the source; only matched pages enter the reading order."
          ).foregroundStyle(.secondary)
          if let original, let media = original.media.first, let candidate {
            let originals = library.cachedURLs(media) ?? []
            ForEach(draft.indices, id: \.self) { index in
              HStack(spacing: 24) {
                PagePreview(
                  url: media.kind == "images"
                    ? (index < originals.count ? originals[index] : nil) : originals.first,
                  kind: media.kind, index: index
                ).frame(width: 115, height: 155)
                VStack(alignment: .leading, spacing: 10) {
                  Text("Original page \(index + 1)").font(.headline)
                  Picker(
                    "Translation",
                    selection: Binding(
                      get: { draft[index] ?? -1 }, set: { draft[index] = $0 < 0 ? nil : $0 })
                  ) {
                    Text("Use original").tag(-1)
                    ForEach(0..<importedCount, id: \.self) {
                      Text("Imported page \($0 + 1)").tag($0)
                    }
                  }
                }.frame(maxWidth: .infinity)
                if let page = draft[index] {
                  PagePreview(
                    url: candidate.kind == "images" ? candidate.pages[page] : candidate.pages.first,
                    kind: candidate.kind, index: page
                  ).frame(width: 115, height: 155)
                } else {
                  Label("Original", systemImage: "arrow.uturn.backward").frame(
                    width: 115, height: 155
                  ).foregroundStyle(.secondary)
                }
              }
              Divider()
            }
          }
        }.padding(24)
      }.navigationTitle("Align Translation")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Use Alignment") {
              mapping = draft
              dismiss()
            }.buttonStyle(.borderedProminent)
          }
        }
    }.frame(width: 650, height: 650)
      .onAppear {
        draft =
          mapping.isEmpty
          ? (0..<(original?.media.first?.pageCount ?? 0)).map { $0 < importedCount ? $0 : nil }
          : mapping
      }
  }
}
