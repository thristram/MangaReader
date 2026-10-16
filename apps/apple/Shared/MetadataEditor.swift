import MangaCore
import SwiftUI

struct TranslateButton: View {
  let entity: LibraryEntity
  let field: String
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @State private var translating = false
  var body: some View {
    Button {
      translating = true
      let language = AppConfiguration.preferredLanguage
      let owner = session.account?.ownerId
      Task {
        defer { translating = false }
        do {
          guard owner == session.account?.ownerId else { return }
          let text = try await OllamaTranslator.translate(
            title: field == "title" ? entity.title : "",
            description: field == "description" ? entity.description : "", language: language)
          guard owner == session.account?.ownerId, let current = library.entity(entity.id) else {
            return
          }
          guard
            field == "title"
              ? current.title == entity.title : current.description == entity.description
          else { throw LoginError.server("The source changed during translation. Try again.") }
          var input = current.input
          var translated = input.localizations[language] ?? LocalizedText()
          if field == "title" {
            translated.title = text.title
          } else {
            translated.description = text.description
          }
          input.localizations[language] = translated
          try await session.update(current, input: input)
        } catch { library.show(error) }
      }
    } label: {
      if translating {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: "character.bubble")
      }
    }
    .buttonStyle(.borderless).disabled(translating).help(
      "Translate \(field) to \(AppConfiguration.preferredLanguage)"
    )
    .accessibilityLabel("Translate " + field)
  }
}
struct TagTokenPicker: View {
  @Binding var selected: [String]
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var library: LibraryUIModel
  @State private var query = ""
  @State private var focused = false
  @State private var creating = false
  private var tags: [LibraryEntity] { session.catalog.visible(kind: .tag, showNSFW: true) }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 7) {
          ForEach(selected, id: \.self) { id in
            if let tag = session.catalog.entity(id, showNSFW: true) {
              HStack(spacing: 6) {
                Text(tag.title)
                Button("Remove " + tag.title, systemImage: "xmark") {
                  selected.removeAll { $0 == id }
                }.labelStyle(.iconOnly).buttonStyle(.plain)
              }
              .font(.caption).padding(.horizontal, 9).padding(.vertical, 5).background(
                .pink.opacity(0.13), in: Capsule())
            }
          }
        }
      }
      TextField("Search or create a tag", text: $query, onEditingChanged: { focused = $0 })
        .fullFieldFocus()
        .textFieldStyle(.roundedBorder).onSubmit(createTag)
      if focused || !query.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(
            tags.lazy.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
              .prefix(8)
          ) { tag in
            Button {
              if !selected.contains(tag.id) { selected.append(tag.id) }
              query = ""
              focused = false
            } label: {
              HStack {
                Circle().fill(tag.nsfw ? .orange : .pink).frame(width: 8, height: 8)
                Text(tag.title)
                Spacer()
                if selected.contains(tag.id) { Image(systemName: "checkmark") }
              }.padding(8)
            }.buttonStyle(.plain)
          }
          if !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !tags.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame })
          {
            Button("Create “\(query)”", systemImage: "plus", action: createTag).padding(8).disabled(
              creating)
          }
        }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }
  private func createTag() {
    let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !creating else { return }
    if let existing = tags.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
      if !selected.contains(existing.id) { selected.append(existing.id) }
      query = ""
      return
    }
    creating = true
    let owner = session.account?.ownerId
    Task {
      defer { creating = false }
      do {
        guard owner == session.account?.ownerId else { return }
        var input = MetadataInput(kind: .tag, title: name)
        input.nsfw = name.lowercased() == "nsfw"
        let tag = try await session.create(input)
        selected.append(tag.id)
        query = ""
        focused = false
      } catch { library.show(error) }
    }
  }
}
struct EntitySearchField: View {
  let label: String
  let kind: EntityKind
  @Binding var selected: String?
  var create: ((String) -> Void)?
  @EnvironmentObject private var session: AppSession
  @State private var query = ""
  @State private var expanded = false
  private var choices: [LibraryEntity] {
    session.catalog.search(kind: kind, query: query, limit: 7, showNSFW: AppConfiguration.showNSFW)
  }
  private var selectedTitle: String {
    session.catalog.entity(selected, showNSFW: AppConfiguration.showNSFW)?.title ?? ""
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(label, text: $query, onEditingChanged: { expanded = $0 }).fullFieldFocus()
        .textFieldStyle(
          .roundedBorder)
      if expanded {
        VStack(alignment: .leading, spacing: 0) {
          Button("None") {
            selected = nil
            query = ""
            expanded = false
          }.padding(7)
          ForEach(
            choices
          ) { entity in
            Button(entity.title) {
              selected = entity.id
              query = entity.title
              expanded = false
            }.padding(7)
          }
          if let create, !query.isEmpty {
            Button("Create “\(query)”", systemImage: "plus") {
              create(query)
              expanded = false
            }.padding(7)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).background(
          .quaternary, in: RoundedRectangle(cornerRadius: 8))
      }
    }.onAppear { query = selectedTitle }
      .onChange(of: selected) { _, _ in query = selectedTitle }
      .onChange(of: selectedTitle) { _, title in if !expanded { query = title } }
      .onChange(of: session.metadataGeneration) { _, _ in
        if let id = selected, session.catalog.entity(id, showNSFW: true) == nil {
          selected = nil
          query = ""
        }
      }
  }
}
struct SourceLinksEditor: View {
  @Binding var links: [SourceLink]
  @State private var rows: [UUID] = []
  @FocusState private var focusedSource: UUID?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(rows, id: \.self) { id in
        HStack {
          Picker("Site", selection: field(id, site: true)) {
            Text("Pixiv").tag("pixiv")
            Text("FANBOX").tag("fanbox")
            Text("Patreon").tag("patreon")
            Text("e-hentai").tag("ehentai")
          }.labelsHidden().frame(width: 120)
          TextField("", text: field(id, site: false))
            .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
            .focused($focusedSource, equals: id).onTapGesture { focusedSource = id }
            .accessibilityLabel("Source link")
          Button("Remove Link", systemImage: "minus.circle") {
            if let index = rows.firstIndex(of: id), links.indices.contains(index) {
              links.remove(at: index)
              rows.remove(at: index)
            }
          }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
      }
      Button("Add Source Link", systemImage: "plus") {
        links.append(.init(site: SourceLink.nextUnusedSite(in: links), value: ""))
        let id = UUID()
        rows.append(id)
        focusedSource = id
      }.disabled(links.count >= SourceLink.supportedSites.count)
    }.onAppear(perform: reconcileRows).onChange(of: links.count) { _, _ in reconcileRows() }
  }
  private func reconcileRows() {
    if rows.count > links.count { rows = Array(rows.prefix(links.count)) }
    while rows.count < links.count { rows.append(UUID()) }
  }
  private func field(_ id: UUID, site: Bool) -> Binding<String> {
    Binding(
      get: {
        guard let index = rows.firstIndex(of: id), links.indices.contains(index) else { return "" }
        return site ? links[index].site : links[index].value
      },
      set: { value in
        guard let index = rows.firstIndex(of: id), links.indices.contains(index) else { return }
        if site { links[index].site = value } else { links[index].value = value }
      })
  }
}
struct MetadataEditor: View {
  let request: EditorRequest
  var onSave: ((LibraryEntity) -> Void)?
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @Environment(\.dismiss) private var dismiss
  @State private var input: MetadataInput
  @State private var textLanguage: String
  @State private var saving = false
  @State private var translating = false
  @State private var status = ""
  @State private var pageOverview = false
  @State private var creating: EditorRequest?
  @State private var editingRevision: Int?
  #if os(macOS)
    @State private var mediaLanguageReview: MediaLanguageReview?
  #endif
  init(request: EditorRequest, onSave: ((LibraryEntity) -> Void)? = nil) {
    self.request = request
    self.onSave = onSave
    _input = State(
      initialValue: request.entity?.input
        ?? MetadataInput(
          kind: request.kind, title: request.initialTitle,
          originalLanguage: AppConfiguration.preferredLanguage,
          storageKind: request.kind == .storageRoot ? "local" : nil))
    if request.kind == .author {
      var author =
        request.entity?.input ?? MetadataInput(kind: .author, title: request.initialTitle)
      for site in SourceLink.supportedSites
      where !author.sources.contains(where: { $0.site == site }) {
        author.sources.append(.init(site: site, value: ""))
      }
      _input = State(initialValue: author)
    }
    _editingRevision = State(initialValue: request.entity?.revision)
    _textLanguage = State(
      initialValue: request.entity?.originalLanguage ?? AppConfiguration.preferredLanguage)
  }
  private var title: Binding<String> { localizedField(title: true) }
  private var description: Binding<String> { localizedField(title: false) }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        SheetHeading((request.entity == nil ? "New " : "Edit ") + kindName(request.kind))
        Form {
          if input.kind == .author {
            Section("Name") {
              TextField("Name", text: $input.title).labelsHidden().textFieldStyle(.plain)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 32)
                .fullFieldFocus()
            }
            Section("External source links (optional)") { SourceLinksEditor(links: $input.sources) }
          } else if input.kind == .storageRoot {
            Section("Destination") { TextField("Name", text: $input.title).fullFieldFocus() }
            Section {
              Text(
                "Add a local folder or SMB connection after saving. Destinations are created only here, never during import."
              ).font(.callout).foregroundStyle(.secondary)
            }
          } else {
            Section("Title & Description") {
              Picker("Text language", selection: $textLanguage) {
                ForEach(contentLanguages, id: \.code) { Text($0.name).tag($0.code) }
              }
              HStack {
                TextField("Title", text: title).fullFieldFocus()
                Button("Translate Title", systemImage: "character.bubble") {
                  translate(field: "title")
                }
                .labelStyle(.iconOnly).disabled(translating)
              }
              HStack(alignment: .top) {
                TextEditor(text: description).scrollContentBackground(.hidden).frame(minHeight: 95)
                  .fullFieldFocus()
                Button("Translate Description", systemImage: "character.bubble") {
                  translate(field: "description")
                }.labelStyle(.iconOnly).disabled(translating)
              }
              Text(
                "Missing translations use the original text. Translating text keeps the same comic pages."
              ).font(.caption).foregroundStyle(.secondary)
            }
          }
          if ![EntityKind.author, .tag, .storageRoot].contains(input.kind) {
            Section("Collection") {
              EntitySearchField(
                label: "Search authors", kind: .author, selected: $input.authorId,
                create: { creating = .init(kind: .author, initialTitle: $0) })
              EntitySearchField(
                label: "Series (optional)", kind: .series, selected: $input.seriesId,
                create: { creating = .init(kind: .series, initialTitle: $0) })
              if input.kind == .chapter {
                EntitySearchField(
                  label: "Comic (optional)", kind: .work, selected: $input.workId,
                  create: { creating = .init(kind: .work, initialTitle: $0) })
              }
            }
          }
          if ![EntityKind.author, .storageRoot].contains(input.kind) {
            Section("Tags & Visibility") {
              TagTokenPicker(selected: $input.tagIds)
              Toggle("NSFW · hide by default", isOn: $input.nsfw)
            }
            Section("Source Links") {
              SourceLinksEditor(links: $input.sources)
            }
          }
          if input.kind == .chapter, let chapter = request.entity {
            Section("Chapter Content") {
              ForEach(input.media) { version in
                HStack {
                  Label(
                    version.languageLabel,
                    systemImage: version.kind == "video" ? "play.rectangle" : "photo.stack")
                  Spacer()
                  #if os(macOS)
                    Picker("Media language", selection: mediaLanguageBinding(version)) {
                      if !mediaLanguages.contains(where: { $0.code == version.language }) {
                        Text(version.languageLabel).tag(version.language)
                      }
                      ForEach(mediaLanguages, id: \.code) { language in
                        Text(language.name).tag(language.code).disabled(
                          input.media.contains {
                            $0.id != version.id
                              && $0.language.lowercased() == language.code.lowercased()
                          })
                      }
                    }.labelsHidden().pickerStyle(.menu)
                      .accessibilityLabel("Media language · " + version.languageLabel)
                      .disabled(saving || translating)
                  #endif
                  Text("\(version.pageCount) pages").foregroundStyle(.secondary)
                }
              }
              Button("Page Order…", systemImage: "square.grid.3x3") { pageOverview = true }
              if !chapter.media.isEmpty {
                Text(
                  "Changing a media language opens a file commit review. Text translations keep their own language."
                ).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          if !status.isEmpty { Section { Text(status).font(.callout).foregroundStyle(.secondary) } }
        }.formStyle(.grouped)
      }
      .navigationTitle("")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(saving || translating)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "Saving…" : "Save", action: save).disabled(
            saving || translating || input.title.trimmingCharacters(in: .whitespaces).isEmpty
          ).keyboardShortcut(.defaultAction)
        }
      }
      .sheet(isPresented: $pageOverview) {
        if let original = request.entity,
          let chapter = session.entities.first(where: { $0.id == original.id && !$0.deleted })
        {
          ChapterOverviewScreen(
            chapter: chapter, editing: true,
            onSaved: { updated in
              input.media = updated.media
              editingRevision = updated.revision
            }
          ).environmentObject(library).environmentObject(session)
        }
      }
    }
    .tint(.pink)
    .sheet(item: $creating) { nested in
      MetadataEditor(
        request: nested,
        onSave: { created in
          switch created.kind {
          case .author: input.authorId = created.id
          case .series: input.seriesId = created.id
          case .work: input.workId = created.id
          default: break
          }
        }
      ).environmentObject(library).environmentObject(session)
    }
    #if os(macOS)
      .sheet(item: $mediaLanguageReview) { review in
        MediaLanguageCommitScreen(review: review) { updated in
          input = updated.input
          editingRevision = updated.revision
          status = "Media language updated."
          mediaLanguageReview = nil
        }.environmentObject(library)
      }
      .frame(
        width: request.kind == .author ? 500 : request.kind == .storageRoot ? 460 : 660,
        height: request.kind == .author ? 460 : request.kind == .storageRoot ? 320 : 720)
    #endif
  }
  #if os(macOS)
    private func mediaLanguageBinding(_ version: MediaVersion) -> Binding<String> {
      Binding(
        get: { version.language },
        set: { language in
          guard language != version.language else { return }
          do {
            guard let current = try currentForSave() else { return }
            var metadata = cleanedInput
            metadata.media = current.media
            mediaLanguageReview = MediaLanguageReview(
              chapter: current,
              plan: try MediaLanguageChangePlan(
                metadata: metadata, mediaId: version.id, language: language))
          } catch { status = error.localizedDescription }
        })
    }
  #endif
  private func localizedField(title: Bool) -> Binding<String> {
    Binding(
      get: {
        if textLanguage == input.originalLanguage { return title ? input.title : input.description }
        return
          (title
          ? input.localizations[textLanguage]?.title
          : input.localizations[textLanguage]?.description) ?? ""
      },
      set: { value in
        if textLanguage == input.originalLanguage {
          if title { input.title = value } else { input.description = value }
        } else {
          var text = input.localizations[textLanguage] ?? LocalizedText()
          if title {
            text.title = value.isEmpty ? nil : value
          } else {
            text.description =
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
          }
          input.localizations[textLanguage] = text
        }
      })
  }
  private var cleanedInput: MetadataInput {
    var value = input
    if value.kind == .author {
      value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    value.sources.removeAll { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return value
  }
  private func currentForSave() throws -> LibraryEntity? {
    guard let original = request.entity else { return nil }
    guard let current = session.entities.first(where: { $0.id == original.id && !$0.deleted }),
      current.revision == editingRevision
    else {
      throw LoginError.server(
        "This item changed on another screen or device. Close and reopen the editor to review the latest version."
      )
    }
    return current
  }
  private func save() {
    saving = true
    let owner = session.account?.ownerId
    Task {
      defer { saving = false }
      do {
        guard owner == session.account?.ownerId else { return }
        if [.chapter, .work, .series].contains(input.kind), input.authorId == nil {
          input.authorId =
            session.entities.first {
              $0.kind == .author && !$0.deleted && $0.title == "other author"
            }?.id
          if input.authorId == nil {
            input.authorId = try await session.create(.init(kind: .author, title: "other author"))
              .id
          }
          guard owner == session.account?.ownerId else { return }
        }
        if let current = try currentForSave() {
          try await session.update(current, input: cleanedInput)
          if let updated = session.entities.first(where: { $0.id == current.id }) {
            onSave?(updated)
          }
        } else {
          let created = try await session.create(cleanedInput)
          onSave?(created)
        }
        dismiss()
      } catch { status = error.localizedDescription }
    }
  }
  private func translate(field: String) {
    translating = true
    status = "Translating…"
    let language = AppConfiguration.preferredLanguage
    let owner = session.account?.ownerId
    let sourceTitle = input.title
    let sourceDescription = input.description
    Task {
      defer { translating = false }
      do {
        guard owner == session.account?.ownerId else { return }
        let text = try await OllamaTranslator.translate(
          title: field == "title" ? input.title : "",
          description: field == "description" ? input.description : "", language: language)
        guard owner == session.account?.ownerId else { return }
        guard field == "title" ? input.title == sourceTitle : input.description == sourceDescription
        else { throw LoginError.server("The source changed during translation. Try again.") }
        var localized = input.localizations[language] ?? LocalizedText()
        if field == "title" {
          localized.title = text.title
        } else {
          localized.description = text.description
        }
        input.localizations[language] = localized
        textLanguage = language
        if let current = try currentForSave() {
          try await session.update(current, input: cleanedInput)
          editingRevision = session.entities.first { $0.id == current.id }?.revision
          status = "Translation saved · \(language)"
        } else {
          status = "Translation added · Save to create this item"
        }
      } catch { status = error.localizedDescription }
    }
  }
}
func kindName(_ kind: EntityKind) -> String {
  switch kind {
  case .work: "Comic"
  case .storageRoot: "Storage Location"
  default: kind.rawValue.capitalized
  }
}

struct SheetHeading: View {
  let title: String
  var inset: CGFloat = 20
  init(_ title: String, inset: CGFloat = 20) {
    self.title = title
    self.inset = inset
  }
  var body: some View {
    Text(title).font(.system(size: 23, weight: .semibold))
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, inset)
      .padding(.top, 18).padding(.bottom, 6)
  }
}
private struct FullFieldFocus: ViewModifier {
  @FocusState private var focused: Bool
  func body(content: Content) -> some View {
    content.focused($focused).contentShape(Rectangle()).onTapGesture { focused = true }
  }
}
extension View {
  func fullFieldFocus() -> some View { modifier(FullFieldFocus()) }
}
