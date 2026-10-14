import MangaCore
import SwiftUI
import UniformTypeIdentifiers

struct MetadataBackup: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  @MainActor init(session: AppSession) throws {
    struct Backup: Encodable {
      var schemaVersion = 1
      var entities: [LibraryEntity]
      var states: [PersonalState]
    }
    data = try JSONEncoder().encode(Backup(entities: session.entities, states: session.states))
  }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
struct LibrarySettingsScreen: View {
  let page: LibraryPage
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @AppStorage("ShowNSFW") private var showNSFW = false
  @AppStorage("ContentLanguage") private var language = "zh"
  @AppStorage("ReaderDirection") private var direction = "ltr"
  @AppStorage("ReaderDescription") private var description = false
  @AppStorage("OllamaURL") private var host = "http://localhost:11434"
  @AppStorage("OllamaModel") private var model = ""
  @AppStorage("OllamaPrompt") private var prompt = OllamaTranslator.defaultPrompt
  @AppStorage("FinderFavoriteColor") private var favoriteColor = 6
  @AppStorage("FinderStarColor") private var starColor = 5
  @State private var connection: LibraryEntity?
  @State private var bindingRoot: LibraryEntity?
  @State private var choosingFolder = false
  @State private var exporting = false
  @State private var backup: MetadataBackup?
  @State private var models: [String] = []
  @State private var testing = false
  @State private var connectionStatus = ""
  var body: some View {
    Form {
      switch page {
      case .settings:
        Section("Appearance") {
          LabeledContent("Interface language", value: "English")
          LabeledContent("Appearance", value: "Follow system")
        }
        Section("Content") {
          Toggle("Show NSFW content", isOn: $showNSFW)
          Text("Hidden content is excluded from your library, search, history and downloads.").font(
            .caption
          ).foregroundStyle(.secondary)
        }
        #if os(iOS)
          Section("Settings") {
            ForEach([LibraryPage.reading, .connections, .sync, .downloads]) { page in
              NavigationLink(value: LibraryRoute.page(page)) {
                Label(page.title, systemImage: page.symbol)
              }
            }
          }
        #endif
      case .reading:
        Section("Language") {
          Picker("Preferred manga language", selection: $language) {
            ForEach(contentLanguages, id: \.code) { Text($0.name).tag($0.code) }
          }
          Text(
            "Unavailable media uses the original version, then any available version. Titles and descriptions fall back independently."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Reader") {
          Picker("Reading direction", selection: $direction) {
            Text("Left to right").tag("ltr")
            Text("Right to left").tag("rtl")
          }
          Toggle("Show chapter description", isOn: $description)
          LabeledContent("Default image display", value: "Fill window height")
        }
        Section("Content") { Toggle("Show NSFW content", isOn: $showNSFW) }
      case .translation:
        Section("Local Ollama") {
          TextField("Service URL", text: $host)
          TextField("Model", text: $model)
          HStack {
            Button(testing ? "Connecting…" : "Test Connection", action: testOllama).disabled(
              testing)
            if !models.isEmpty {
              Menu("Installed Models") {
                ForEach(models, id: \.self) { name in Button(name) { model = name } }
              }
            }
          }
          if !connectionStatus.isEmpty {
            Text(connectionStatus).font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("System Prompt") {
          TextEditor(text: $prompt).scrollContentBackground(.hidden).font(.body).frame(
            minHeight: 160)
          Button("Restore Default") { prompt = OllamaTranslator.defaultPrompt }
          Text(
            "Translate buttons use your preferred manga language and save text separately from media."
          ).font(.caption).foregroundStyle(.secondary)
        }
      case .connections, .storage:
        Section("Media Storage") {
          ForEach(session.entities.filter { $0.kind == .storageRoot && !$0.deleted }) { root in
            VStack(alignment: .leading, spacing: 12) {
              Label(
                root.title, systemImage: root.storageKind == "smb" ? "network" : "externaldrive"
              ).font(.headline)
              HStack {
                #if os(macOS)
                  Button("Choose Local or Mounted SMB Folder…") {
                    bindingRoot = root
                    choosingFolder = true
                  }
                #endif
                Button("SMB Connection…") { connection = root }
              }.controlSize(.small)
              if let url = try? library.local.rootURL(root.id) {
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
            }.padding(.vertical, 6)
          }
          if session.entities.filter({ $0.kind == .storageRoot && !$0.deleted }).isEmpty {
            Text("Import a collection on your Mac to add its storage location.").foregroundStyle(
              .secondary)
          }
          if library.canManage {
            Button("New Storage Location", systemImage: "plus") { library.create(.storageRoot) }
          }
        }
        Section {
          Text(
            "SMB credentials stay in Keychain on this device. Connect to the same share and relative base folder used by your library."
          ).font(.caption).foregroundStyle(.secondary)
        }
      case .sync:
        Section("Account") {
          Label("Signed in with Thristram", systemImage: "person.crop.circle.badge.checkmark")
          Button("Sign Out", role: .destructive) {
            library.reset()
            session.signOut()
          }
        }
        Section("Automatic Sync") {
          Label(
            session.status,
            systemImage: session.status == "Library synced" ? "checkmark.icloud" : "icloud")
          Text(
            "Titles, descriptions, translations, tags, favorites, stars and reading progress sync across your devices."
          )
          Button(
            "Sync Now", systemImage: "arrow.triangle.2.circlepath", action: library.synchronize)
          Text(
            "While open, the library refreshes every 30 seconds. Metadata changes currently require a connection."
          ).font(.caption).foregroundStyle(.secondary)
        }
      case .files:
        Section("Finder Tags") {
          Text(
            "Finder tag syncing is coming soon. These colors are saved for later use."
          ).font(.caption).foregroundStyle(.secondary)
          Picker("Favorites", selection: $favoriteColor) {
            ForEach(finderColors, id: \.value) { Text($0.name).tag($0.value) }
          }
          Picker("Starred", selection: $starColor) {
            ForEach(finderColors, id: \.value) { Text($0.name).tag($0.value) }
          }
        }
        Section("Backup") {
          Button("Export Library Metadata…", systemImage: "square.and.arrow.up") {
            do {
              backup = try MetadataBackup(session: session)
              exporting = true
            } catch { library.show(error) }
          }
          Text(
            "Includes library metadata and reading state. Media files and credentials are kept separately."
          ).font(.caption).foregroundStyle(.secondary)
          NavigationLink(value: LibraryRoute.page(.organization)) {
            Label("Review File Organization", systemImage: "folder.badge.gearshape")
          }
        }
      default: EmptyView()
      }
    }
    .formStyle(.grouped)
    .sheet(item: $connection) { SMBConnectionScreen(root: $0).environmentObject(library) }
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      do {
        if let root = bindingRoot {
          try library.local.bind(root, to: result.get())
          library.revision += 1
        }
      } catch { library.show(error) }
      bindingRoot = nil
    }
    .fileExporter(
      isPresented: $exporting, document: backup, contentType: .json,
      defaultFilename: "MangaReader-library.json"
    ) { result in if case .failure(let error) = result { library.show(error) } }
    .onChange(of: language) { _, _ in library.visibilityChanged() }
  }
  private func testOllama() {
    testing = true
    Task {
      defer { testing = false }
      do {
        models = try await OllamaTranslator.models(host: host)
        connectionStatus = "Connected · \(models.count) installed models"
      } catch { connectionStatus = error.localizedDescription }
    }
  }
}
let contentLanguages = [
  (code: "zh", name: "中文"), (code: "en", name: "English"), (code: "ja", name: "日本語"),
  (code: "ko", name: "한국어"), (code: "und", name: "Unspecified"),
]
let finderColors = [
  (value: 6, name: "Red"), (value: 7, name: "Orange"), (value: 5, name: "Yellow"),
  (value: 2, name: "Green"), (value: 4, name: "Blue"), (value: 3, name: "Purple"),
  (value: 1, name: "Gray"),
]

struct SMBConnectionScreen: View {
  let root: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  @Environment(\.dismiss) private var dismiss
  @State private var server = "smb://"
  @State private var share = ""
  @State private var base = ""
  @State private var username = ""
  @State private var password = ""
  @State private var error = ""
  var body: some View {
    NavigationStack {
      Form {
        Section("NAS") {
          TextField("Server · smb://nas.local", text: $server)
          TextField("Share", text: $share)
          TextField("Base folder (optional)", text: $base)
        }
        Section("Sign In") {
          TextField("Username", text: $username)
          SecureField("Password", text: $password)
        }
        Section {
          Label("SMB3 encryption required", systemImage: "lock.shield")
          Text("Credentials are saved only on this device.").font(.caption).foregroundStyle(
            .secondary)
        }
        if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
      }.formStyle(.grouped).navigationTitle(root.title)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save Connection") {
              do {
                try library.smb.configure(
                  rootId: root.id,
                  connection: .init(
                    server: server, share: share, basePath: base, username: username,
                    password: password, encrypted: true))
                dismiss()
              } catch { self.error = error.localizedDescription }
            }.disabled(share.isEmpty || username.isEmpty)
          }
        }
    }
    #if os(macOS)
      .frame(width: 560, height: 510)
    #endif
    .onAppear {
      if let connection = try? library.smb.connection(rootId: root.id) {
        server = connection.server
        share = connection.share
        base = connection.basePath
        username = connection.username
        password = connection.password
      }
    }
  }
}
