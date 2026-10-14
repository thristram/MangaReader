import AppKit
import MangaCore
import QuickLookThumbnailing

final class MacCard: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("ComicCard")
  let cover = NSImageView()
  let titleLabel = NSTextField(labelWithString: "")
  let subtitle = NSTextField(labelWithString: "")
  let download = NSButton()
  let edit = NSButton()
  var editAction: (() -> Void)?
  var downloadAction: (() -> Void)?
  override func loadView() {
    view = NSView()
    cover.imageScaling = .scaleProportionallyUpOrDown
    cover.wantsLayer = true
    cover.layer?.cornerRadius = 8
    cover.layer?.masksToBounds = true
    cover.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitle.textColor = .secondaryLabelColor
    subtitle.font = .systemFont(ofSize: 11)
    edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit chapter")
    edit.bezelStyle = .accessoryBarAction
    edit.target = self
    edit.action = #selector(editTapped)
    download.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Download")
    download.bezelStyle = .accessoryBarAction
    download.target = self
    download.action = #selector(downloadTapped)
    for v in [cover, titleLabel, subtitle, download, edit] {
      view.addSubview(v)
      v.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      cover.topAnchor.constraint(equalTo: view.topAnchor),
      cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      cover.heightAnchor.constraint(equalToConstant: 230),
      download.topAnchor.constraint(equalTo: cover.topAnchor, constant: 8),
      download.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -8),
      edit.topAnchor.constraint(equalTo: titleLabel.topAnchor),
      edit.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
      edit.widthAnchor.constraint(equalToConstant: 24),
      titleLabel.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 8),
      titleLabel.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
      titleLabel.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -4),
      subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      subtitle.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
      subtitle.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
    ])
  }
  @objc func editTapped() { editAction?() }
  @objc func downloadTapped() { downloadAction?() }
  func configure(entity: LibraryEntity, session: AppSession, media: LocalMedia) {
    titleLabel.stringValue = entity.title(in: AppConfiguration.preferredLanguage)
    subtitle.stringValue = entity.kind.rawValue.capitalized
    cover.image = NSImage(
      systemSymbolName: entity.kind == .author ? "person.crop.circle" : "book.closed",
      accessibilityDescription: nil)
    edit.isHidden = false
    download.isHidden = false
    let chapter =
      entity.kind == .chapter
      ? entity
      : session.visibleEntities(kind: .chapter).first {
        $0.workId == entity.id || $0.seriesId == entity.id
      }
    guard let version = chapter?.preferredMedia(AppConfiguration.preferredLanguage),
      let url = try? media.urls(for: version).first
    else { return }
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: NSSize(width: 400, height: 500), scale: 2, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
      DispatchQueue.main.async { self?.cover.image = rep?.nsImage ?? NSImage(contentsOf: url) }
    }
  }
}
final class MacLibraryController: NSSplitViewController, NSToolbarDelegate,
  NSCollectionViewDataSource, NSCollectionViewDelegate
{
  let session: AppSession
  let media: LocalMedia
  let grid = NSCollectionView()
  let heading = NSTextField(labelWithString: "Library")
  let status = NSTextField(wrappingLabelWithString: "")
  let search = NSSearchField()
  var rows: [LibraryEntity] = []
  var section = "Library"
  var work: LibraryEntity?
  var lastOwner: String?
  var readerWindows: [NSWindow] = []
  var importController: MacImportController?
  let content = NSViewController()
  let sidebar = NSViewController()
  init(session: AppSession) {
    self.session = session
    media = LocalMedia(session: session)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    super.loadView()
    sidebar.view = NSView()
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 12, bottom: 12, right: 12)
    sidebar.view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: sidebar.view.safeAreaLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
    ])
    let label = NSTextField(labelWithString: "MangaReader")
    label.font = .systemFont(ofSize: 17, weight: .semibold)
    stack.addArrangedSubview(label)
    for title in [
      "Library", "Continue Reading", "Favorites", "Starred", "Authors", "Series", "History",
      "Downloads", "Tags", "Statistics", "Import", "Connections", "Reading", "Ollama", "Sync",
    ] {
      let b = NSButton(title: title, target: self, action: #selector(navigate(_:)))
      b.bezelStyle = .accessoryBar
      b.alignment = .left
      b.identifier = NSUserInterfaceItemIdentifier(title)
      stack.addArrangedSubview(b)
      b.widthAnchor.constraint(equalToConstant: 190).isActive = true
    }
    let side = NSSplitViewItem(sidebarWithViewController: sidebar)
    side.minimumThickness = 220
    side.maximumThickness = 250
    addSplitViewItem(side)
    content.view = NSView()
    heading.font = .systemFont(ofSize: 28, weight: .bold)
    status.textColor = .secondaryLabelColor
    search.placeholderString = "Search your library"
    search.target = self
    search.action = #selector(searchChanged)
    let layout = NSCollectionViewFlowLayout()
    layout.itemSize = NSSize(width: 175, height: 290)
    layout.minimumInteritemSpacing = 24
    layout.minimumLineSpacing = 24
    layout.sectionInset = NSEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)
    grid.collectionViewLayout = layout
    grid.register(MacCard.self, forItemWithIdentifier: MacCard.identifier)
    grid.dataSource = self
    grid.delegate = self
    grid.isSelectable = true
    let scroll = NSScrollView()
    scroll.documentView = grid
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    for v in [heading, status, search, scroll] {
      content.view.addSubview(v)
      v.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor, constant: 20),
      heading.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 24),
      search.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -24),
      search.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      search.widthAnchor.constraint(equalToConstant: 250),
      status.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
      status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -24),
      scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 16),
      scroll.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
    ])
    addSplitViewItem(NSSplitViewItem(viewController: content))
    session.onChange = { [weak self] in self?.reload() }
    reload()
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    let toolbar = NSToolbar(identifier: "MangaReaderToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    view.window?.toolbar = toolbar
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .toggleSidebar, NSToolbarItem.Identifier("back"), .flexibleSpace,
      NSToolbarItem.Identifier("refresh"), NSToolbarItem.Identifier("import"),
      NSToolbarItem.Identifier("account"),
    ]
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: id)
    item.target = self
    switch id.rawValue {
    case "back":
      item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
      item.action = #selector(back)
    case "refresh":
      item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Sync")
      item.action = #selector(refresh)
    case "import":
      item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Import")
      item.action = #selector(importFiles)
    case "account":
      item.image = NSImage(
        systemSymbolName: "person.crop.circle", accessibilityDescription: "Sign in")
      item.action = #selector(accountAction)
    default: return nil
    }
    return item
  }
  @objc func accountAction() {
    if session.account == nil {
      session.login()
    } else {
      media.release()
      session.signOut()
    }
  }
  @objc func refresh() { Task { do { try await session.synchronize() } catch { show(error) } } }
  @objc func back() {
    work = nil
    reload()
  }
  @objc func searchChanged() { reload() }
  @objc func navigate(_ sender: NSButton) {
    section = sender.identifier!.rawValue
    work = nil
    if section == "Import" {
      importFiles()
      return
    }
    if ["Connections", "Reading", "Ollama", "Sync"].contains(section) {
      presentAsSheet(MacSettingsController(session: session, media: media, section: section))
      return
    }
    reload()
  }
  func reload() {
    if lastOwner != session.account?.ownerId {
      readerWindows.forEach { $0.close() }
      readerWindows = []
      search.stringValue = ""
      presentedViewControllers?.filter { $0 is MacEditController || $0 is MacImportController }
        .forEach { dismiss($0) }
      work = nil
      lastOwner = session.account?.ownerId
    }
    heading.stringValue = work?.title(in: AppConfiguration.preferredLanguage) ?? section
    status.stringValue = session.status
    guard session.account != nil else {
      rows = []
      grid.reloadData()
      return
    }
    if let work {
      rows = session.visibleEntities(kind: .chapter).filter { $0.workId == work.id }
    } else {
      switch section {
      case "Authors": rows = session.visibleEntities(kind: .author)
      case "Series": rows = session.visibleEntities(kind: .series)
      case "Tags": rows = session.visibleEntities(kind: .tag)
      case "Continue Reading", "History":
        let ids = Set(session.states.filter { $0.progress != nil }.map(\.entityId))
        rows = session.visibleEntities().filter { ids.contains($0.id) }
      case "Favorites", "Starred":
        let ids = Set(
          session.states.filter { section == "Favorites" ? $0.favorite : $0.starred }.map(
            \.entityId))
        rows = session.visibleEntities().filter { ids.contains($0.id) }
      case "Downloads":
        rows = []
        status.stringValue =
          "Mac reads original local or mounted SMB files. Offline download jobs are scheduled for the next milestone."
      case "Statistics":
        rows = []
        let visible = Set(session.visibleEntities().map(\.id))
        let states = session.states.filter { visible.contains($0.entityId) && $0.pageIndex == nil }
        status.stringValue =
          "\(states.filter { $0.progress?.completed == true }.count) completed chapters · \(states.filter { $0.favorite }.count) favorites"
      default:
        rows = session.visibleEntities().filter {
          $0.kind == .work || ($0.kind == .chapter && $0.workId == nil)
        }
      }
    }
    if !search.stringValue.isEmpty {
      rows = rows.filter {
        $0.title(in: AppConfiguration.preferredLanguage).localizedCaseInsensitiveContains(
          search.stringValue)
      }
    }
    grid.reloadData()
  }
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
    -> Int
  { rows.count }
  func collectionView(
    _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let item =
      collectionView.makeItem(withIdentifier: MacCard.identifier, for: indexPath) as! MacCard
    let entity = rows[indexPath.item]
    item.configure(entity: entity, session: session, media: media)
    item.editAction = { [weak self] in
      guard let self else { return }
      self.presentAsSheet(MacEditController(entity: entity, session: self.session))
    }
    item.downloadAction = { [weak self] in
      self?.show(
        LoginError.server(
          "Mac reads media in place. Download queues are not implemented in this milestone."))
    }
    return item
  }
  func collectionView(
    _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
  ) {
    guard let i = indexPaths.first?.item else { return }
    let entity = rows[i]
    if entity.kind == .work {
      work = entity
      reload()
    } else if entity.kind == .chapter {
      openReader(entity)
    } else if entity.kind == .author {
      section = "Library"
      rows = session.visibleEntities().filter {
        $0.authorId == entity.id && ($0.kind == .work || ($0.kind == .chapter && $0.workId == nil))
      }
      heading.stringValue = entity.title
      grid.reloadData()
    }
  }
  func openReader(_ chapter: LibraryEntity) {
    do {
      guard let version = chapter.preferredMedia(AppConfiguration.preferredLanguage) else {
        throw StorageError.emptyChapter
      }
      let urls = try media.urls(for: version)
      let controller = MacReaderController(
        chapter: chapter, version: version, urls: urls, session: session, media: media)
      let w = NSWindow(contentViewController: controller)
      w.title = chapter.title(in: AppConfiguration.preferredLanguage)
      w.setContentSize(NSSize(width: 1000, height: 800))
      w.styleMask.insert([.resizable, .miniaturizable])
      w.makeKeyAndOrderFront(nil)
      readerWindows.append(w)
    } catch { show(error) }
  }
  @objc func importFiles() {
    guard session.account != nil else {
      session.login()
      return
    }
    let controller = MacImportController(session: session, media: media)
    importController = controller
    presentAsSheet(controller)
  }
  func show(_ error: Error) {
    let a = NSAlert()
    a.messageText = "MangaReader"
    a.informativeText = error.localizedDescription
    if let w = view.window { a.beginSheetModal(for: w) } else { a.runModal() }
  }
}
