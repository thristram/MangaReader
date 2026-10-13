import AppKit
import MangaCore
import PDFKit
import QuickLookThumbnailing

final class ImportDropView: NSView {
  var dropped: (([URL]) -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard
      let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)
        as? [URL]
    else { return false }
    dropped?(urls)
    return true
  }
}
final class MacImportController: NSViewController {
  let session: AppSession
  let media: LocalMedia
  var queue: [ImportCandidate] = []
  let cover = NSImageView()
  let titleField = NSTextField()
  let author = NSComboBox()
  let comic = NSComboBox()
  let descriptionField = NSTextField()
  let language = NSTextField(string: "zh")
  let tag = NSComboBox()
  let pixiv = NSTextField()
  let fanbox = NSTextField()
  let ehentai = NSTextField()
  let status = NSTextField(wrappingLabelWithString: "Drop folders anywhere on this page.")
  var tags: [String] = []
  var roots: [URL] = []
  var busy = false
  var managedRoot: LibraryEntity?
  let commit = NSButton()
  let addOnly = NSButton()
  init(session: AppSession, media: LocalMedia) {
    self.session = session
    self.media = media
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    let drop = ImportDropView(frame: NSRect(x: 0, y: 0, width: 780, height: 770))
    drop.dropped = { [weak self] in self?.append($0) }
    view = drop
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: view.topAnchor),
    ])
    let heading = NSTextField(labelWithString: "Import & Identify")
    heading.font = .systemFont(ofSize: 24, weight: .bold)
    stack.addArrangedSubview(heading)
    let choose = NSButton(
      title: "Drop folders here, or choose files…", target: self, action: #selector(choose))
    choose.bezelStyle = .rounded
    choose.widthAnchor.constraint(equalToConstant: 720).isActive = true
    stack.addArrangedSubview(choose)
    cover.imageScaling = .scaleProportionallyUpOrDown
    cover.heightAnchor.constraint(equalToConstant: 220).isActive = true
    cover.widthAnchor.constraint(equalToConstant: 720).isActive = true
    stack.addArrangedSubview(cover)
    stack.addArrangedSubview(status)
    author.addItems(
      withObjectValues: session.entities.filter { $0.kind == .author && !$0.deleted }.map(\.title))
    author.completes = true
    comic.addItems(
      withObjectValues: session.entities.filter { $0.kind == .work && !$0.deleted }.map(\.title))
    comic.completes = true
    tag.addItems(
      withObjectValues: session.entities.filter { $0.kind == .tag && !$0.deleted }.map(\.title))
    tag.completes = true
    for (label, field) in [
      ("Chapter", titleField), ("Author — search or create", author),
      ("Comic — optional, search or create", comic), ("Chapter description", descriptionField),
      ("Media language code", language),
    ] {
      let row = NSStackView(views: [NSTextField(labelWithString: label), field])
      field.widthAnchor.constraint(equalToConstant: 470).isActive = true
      stack.addArrangedSubview(row)
    }
    stack.addArrangedSubview(
      NSStackView(views: [
        NSButton(title: "New author…", target: self, action: #selector(newAuthor)),
        NSButton(title: "Create comic in series…", target: self, action: #selector(newComic)),
      ]))
    tag.placeholderString = "Search tags or create"
    tag.widthAnchor.constraint(equalToConstant: 470).isActive = true
    stack.addArrangedSubview(
      NSStackView(views: [
        tag, NSButton(title: "Add / Create tag", target: self, action: #selector(addTag)),
      ]))
    for (label, field) in [
      ("Pixiv ID", pixiv), ("Fanbox post ID", fanbox),
      ("e-hentai gallery URL or ID/token", ehentai),
    ] {
      field.placeholderString = label
      field.widthAnchor.constraint(equalToConstant: 220).isActive = true
    }
    stack.addArrangedSubview(NSStackView(views: [pixiv, fanbox, ehentai]))
    commit.title = "Add to Library & Move Files"
    commit.bezelStyle = .rounded
    commit.keyEquivalent = "\r"
    commit.target = self
    commit.action = #selector(moveAndAdd)
    addOnly.title = "Add without moving"
    addOnly.target = self
    addOnly.action = #selector(addWithoutMoving)
    stack.addArrangedSubview(
      NSStackView(views: [
        NSButton(title: "Close", target: self, action: #selector(close)), addOnly, commit,
      ]))
  }
  @objc func close() { dismiss(self) }
  @objc func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    append(panel.urls)
  }
  func append(_ urls: [URL]) {
    do {
      for url in urls {
        _ = url.startAccessingSecurityScopedResource()
        roots.append(url)
        queue += try ImportScanner.scan(url)
      }
      showCurrent()
    } catch { status.stringValue = error.localizedDescription }
  }
  func showCurrent() {
    guard let current = queue.first else {
      status.stringValue = "All selected chapters have been processed."
      cover.image = nil
      commit.isEnabled = false
      addOnly.isEnabled = false
      return
    }
    titleField.stringValue = current.title
    descriptionField.stringValue = ""
    tags = []
    status.stringValue =
      "\(current.pages.count) media files · \(queue.count) chapters remaining. "
      + current.warnings.joined(separator: " ")
    commit.isEnabled = current.warnings.isEmpty
    addOnly.isEnabled = true
    if let url = current.pages.first {
      let request = QLThumbnailGenerator.Request(
        fileAt: url, size: NSSize(width: 640, height: 220), scale: 2,
        representationTypes: .thumbnail)
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
        DispatchQueue.main.async { self?.cover.image = rep?.nsImage ?? NSImage(contentsOf: url) }
      }
    }
  }
  @objc func newAuthor() {
    let a = NSAlert()
    a.messageText = "New author"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
    a.accessoryView = field
    a.addButton(withTitle: "Create")
    a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
    Task {
      do {
        let e = try await session.create(MetadataInput(kind: .author, title: field.stringValue))
        author.addItem(withObjectValue: e.title)
        author.stringValue = e.title
      } catch { status.stringValue = error.localizedDescription }
    }
  }
  @objc func newComic() {
    let a = NSAlert()
    a.messageText = "Create comic"
    let name = NSTextField(string: comic.stringValue)
    name.placeholderString = "Comic title"
    let series = NSComboBox()
    series.addItems(
      withObjectValues: session.entities.filter { $0.kind == .series && !$0.deleted }.map(\.title))
    series.placeholderString = "Series (optional)"
    let stack = NSStackView(views: [name, series])
    stack.orientation = .vertical
    stack.frame = NSRect(x: 0, y: 0, width: 350, height: 75)
    name.widthAnchor.constraint(equalToConstant: 340).isActive = true
    series.widthAnchor.constraint(equalToConstant: 340).isActive = true
    a.accessoryView = stack
    a.addButton(withTitle: "Create")
    a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn, !name.stringValue.isEmpty else { return }
    Task {
      do {
        let author = try await resolveAuthor()
        let seriesName = series.stringValue
        let existing = session.entities.first {
          $0.kind == .series && !$0.deleted && $0.title == seriesName
        }
        var seriesId = existing?.id
        if seriesId == nil && !seriesName.isEmpty {
          seriesId = try await session.create(
            MetadataInput(kind: .series, title: seriesName, authorId: author.id)
          ).id
        }
        let work = try await session.create(
          MetadataInput(
            kind: .work, title: name.stringValue, authorId: author.id, seriesId: seriesId))
        comic.addItem(withObjectValue: work.title)
        comic.stringValue = work.title
      } catch { status.stringValue = error.localizedDescription }
    }
  }
  @objc func addTag() {
    let name = tag.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    Task {
      do {
        var input = MetadataInput(kind: .tag, title: name)
        input.nsfw = name.lowercased() == "nsfw"
        let found = session.entities.first {
          $0.kind == .tag && !$0.deleted && $0.title.caseInsensitiveCompare(name) == .orderedSame
        }
        let id: String
        if let found { id = found.id } else { id = try await session.create(input).id }
        if !tags.contains(id) { tags.append(id) }
        tag.stringValue = ""
        status.stringValue =
          "Selected tags: "
          + tags.compactMap { id in session.entities.first { $0.id == id }?.title }.joined(
            separator: ", ")
      } catch { status.stringValue = error.localizedDescription }
    }
  }
  func resolveAuthor() async throws -> LibraryEntity {
    let name = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = name.isEmpty ? "other author" : name
    if let e = session.entities.first(where: {
      $0.kind == .author && !$0.deleted && $0.title == title
    }) {
      return e
    }
    return try await session.create(MetadataInput(kind: .author, title: title))
  }
  @objc func moveAndAdd() { process(move: true) }
  @objc func addWithoutMoving() { process(move: false) }
  func process(move: Bool) {
    guard !busy, let current = queue.first else { return }
    busy = true
    commit.isEnabled = false
    addOnly.isEnabled = false
    var destination: URL?
    if move {
      let panel = NSOpenPanel()
      panel.message = "Choose the managed library root. This action commits the import."
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      guard panel.runModal() == .OK, let url = panel.url else {
        busy = false
        showCurrent()
        return
      }
      destination = url
      _ = url.startAccessingSecurityScopedResource()
      roots.append(url)
    }
    Task { await importChapter(current, destination: destination) }
  }
  private func importChapter(_ current: ImportCandidate, destination: URL?) async {
    do {
      let resolvedAuthor = try await resolveAuthor()
      let comicName = comic.stringValue
      var work: LibraryEntity? = session.entities.first { entity in
        entity.kind == .work && !entity.deleted && entity.title == comicName
          && entity.authorId == resolvedAuthor.id
      }
      if work == nil && !comicName.isEmpty {
        let input = MetadataInput(kind: .work, title: comicName, authorId: resolvedAuthor.id)
        work = try await session.create(input)
      }
      let sourceFolder =
        current.kind == "images" ? current.source : current.source.deletingLastPathComponent()
      let rootInput = MetadataInput(
        kind: .storageRoot, title: sourceFolder.lastPathComponent, storageKind: "local")
      let sourceRoot = try await session.create(rootInput)
      try media.bind(sourceRoot, to: sourceFolder)
      let count: Int
      if current.kind == "pdf" {
        count = PDFDocument(url: current.source)?.pageCount ?? 1
      } else if current.kind == "video" {
        count = 1
      } else {
        count = current.pages.count
      }
      let version = MediaVersion(
        language: language.stringValue, kind: current.kind, storageRootId: sourceRoot.id,
        relativePaths: current.pages.map(\.lastPathComponent), pageCount: count)
      var input = MetadataInput(
        kind: .chapter, title: titleField.stringValue, originalLanguage: language.stringValue,
        description: descriptionField.stringValue, authorId: resolvedAuthor.id,
        seriesId: work?.seriesId, workId: work?.id, media: [version])
      input.tagIds = tags
      for (site, field) in [("pixiv", pixiv), ("fanbox", fanbox), ("ehentai", ehentai)] {
        if !field.stringValue.isEmpty {
          input.sources.append(.init(site: site, value: field.stringValue))
        }
      }
      let chapter = try await session.create(input)
      if let destination {
        let managedInput = MetadataInput(
          kind: .storageRoot, title: "Managed library", storageKind: "local")
        let root = try await session.create(managedInput)
        try media.bind(root, to: destination)
        let seriesTitle: String? = work?.seriesId.flatMap { id in
          session.entities.first { $0.id == id }?.title
        }
        let path = try PathPolicy.chapterPath(
          author: resolvedAuthor.title, series: seriesTitle, work: work?.title,
          chapter: input.title, language: language.stringValue, mediaLanguageCount: 1)
        let relative =
          current.kind == "images" ? path : path + "/" + current.source.lastPathComponent
        guard let journals = session.cacheDirectory?.appendingPathComponent("commit-journals")
        else { throw LoginError.invalidToken }
        var updated = chapter.input
        updated.media[0].storageRootId = root.id
        updated.media[0].relativePaths =
          current.kind == "images"
          ? current.pages.map { path + "/" + $0.lastPathComponent } : [relative]
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updated))
        let recovery = try JSONSerialization.data(withJSONObject: [
          "entityId": chapter.id, "revision": chapter.revision, "metadata": metadata,
        ])
        let journal = try FileCommit.move(
          source: current.source, destinationRelativePath: relative, root: destination,
          journalDirectory: journals, recoveryPayload: recovery)
        try await session.update(chapter, input: updated)
        try FileCommit.finish(journal, in: journals)
      }
      queue.removeFirst()
      busy = false
      showCurrent()
    } catch {
      busy = false
      status.stringValue =
        error.localizedDescription
        + " If files moved, inspect the account commit journal before retrying."
      addOnly.isEnabled = false
      commit.isEnabled = false
    }
  }
  override func viewDidDisappear() {
    super.viewDidDisappear()
    for root in roots { root.stopAccessingSecurityScopedResource() }
    roots = []
  }
}
