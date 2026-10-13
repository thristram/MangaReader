import AVKit
import AppKit
import MangaCore
import PDFKit

final class ReaderImageView: NSScrollView {
  let imageView = NSImageView()
  var zoom: CGFloat = 1
  init(url: URL) {
    super.init(frame: .zero)
    drawsBackground = false
    hasHorizontalScroller = true
    hasVerticalScroller = true
    imageView.image = NSImage(contentsOf: url)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    documentView = imageView
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    guard let image = imageView.image, image.size.height > 0 else { return }
    let height = contentSize.height * zoom
    imageView.frame = NSRect(
      x: 0, y: 0, width: max(contentSize.width, height * image.size.width / image.size.height),
      height: max(contentSize.height, height))
  }
  override func magnify(with event: NSEvent) {
    zoom = max(1, min(8, zoom * (1 + event.magnification)))
    needsLayout = true
  }
}
final class MacReaderController: NSViewController, NSPageControllerDelegate {
  let chapter: LibraryEntity
  var version: MediaVersion
  var urls: [URL]
  let session: AppSession
  let media: LocalMedia
  let pages = NSPageController()
  let position = NSTextField(labelWithString: "")
  var pdf: PDFView?
  let language = NSPopUpButton()
  var pageIndex = 0
  var saved = false
  init(
    chapter: LibraryEntity, version: MediaVersion, urls: [URL], session: AppSession,
    media: LocalMedia
  ) {
    self.chapter = chapter
    self.version = version
    self.urls = urls
    self.session = session
    self.media = media
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    let controls = NSStackView(views: [
      NSButton(
        image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!,
        target: self, action: #selector(previous)), position,
      NSButton(
        image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!,
        target: self, action: #selector(next)),
      NSButton(
        image: NSImage(systemSymbolName: "heart", accessibilityDescription: "Favorite page")!,
        target: self, action: #selector(favorite)),
      NSButton(
        image: NSImage(systemSymbolName: "star", accessibilityDescription: "Star page")!,
        target: self, action: #selector(star)), language,
    ])
    controls.spacing = 12
    language.addItems(withTitles: chapter.media.map(\.language))
    language.selectItem(withTitle: version.language)
    language.target = self
    language.action = #selector(changeLanguage)
    position.textColor = .white
    pages.delegate = self
    pages.transitionStyle = .horizontalStrip
    addChild(pages)
    view.addSubview(pages.view)
    view.addSubview(controls)
    pages.view.translatesAutoresizingMaskIntoConstraints = false
    controls.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      pages.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pages.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pages.view.topAnchor.constraint(equalTo: view.topAnchor),
      pages.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    ])
    setup()
  }
  func setup() {
    pdf = nil
    pageIndex =
      session.states.first { $0.entityId == chapter.id && $0.pageIndex == nil }?.progress?.pageIndex
      ?? 0
    if version.kind == "pdf", let url = urls.first {
      let p = PDFView()
      p.document = PDFDocument(url: url)
      p.autoScales = true
      p.displayMode = .singlePage
      p.backgroundColor = .black
      let vc = NSViewController()
      vc.view = p
      pdf = p
      pages.arrangedObjects = ["pdf"]
      pages.delegate = self
      pages.selectedIndex = 0
    } else {
      pages.arrangedObjects = urls.map(\.absoluteString)
      pages.selectedIndex = min(pageIndex, max(0, urls.count - 1))
    }
    updatePosition()
  }
  func pageController(_ pageController: NSPageController, identifierFor object: Any) -> String {
    String(describing: object)
  }
  func pageController(
    _ pageController: NSPageController, viewControllerForIdentifier identifier: String
  ) -> NSViewController {
    let vc = NSViewController()
    if let pdf {
      vc.view = pdf
      return vc
    }
    guard let url = URL(string: identifier) else {
      vc.view = NSView()
      return vc
    }
    if version.kind == "video" {
      let player = AVPlayerView()
      player.player = AVPlayer(url: url)
      vc.view = player
    } else {
      vc.view = ReaderImageView(url: url)
    }
    return vc
  }
  func pageControllerDidEndLiveTransition(_ pageController: NSPageController) {
    pageController.completeTransition()
    pageIndex = pageController.selectedIndex
    updatePosition()
    saveProgress()
  }
  func updatePosition() { position.stringValue = "\(pageIndex+1) / \(version.pageCount)" }
  @objc func previous() { turn(-1) }
  @objc func next() { turn(1) }
  func turn(_ delta: Int) {
    let next = max(0, min(version.pageCount - 1, pageIndex + delta))
    guard next != pageIndex else { return }
    pageIndex = next
    if let pdf, let p = pdf.document?.page(at: next) {
      pdf.go(to: p)
    } else {
      pages.animator().selectedIndex = min(next, max(0, urls.count - 1))
      pages.completeTransition()
    }
    updatePosition()
    saveProgress()
  }
  override func swipe(with event: NSEvent) {
    if event.deltaX != 0 { turn(event.deltaX > 0 ? -1 : 1) }
  }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123: previous()
    case 124: next()
    default: super.keyDown(with: event)
    }
  }
  func saveProgress() {
    let old = session.states.first { $0.entityId == chapter.id && $0.pageIndex == nil }
    let input = StateInput(
      entityId: chapter.id, favorite: old?.favorite ?? false, starred: old?.starred ?? false,
      progress: ReadingProgress(
        mediaId: version.id, pageIndex: pageIndex, completed: pageIndex == version.pageCount - 1))
    Task { try? await session.saveState(input) }
  }
  @objc func favorite() { toggle(star: false) }
  @objc func star() { toggle(star: true) }
  func toggle(star: Bool) {
    let old = session.states.first { $0.entityId == chapter.id && $0.pageIndex == pageIndex }
    let input = StateInput(
      entityId: chapter.id, pageIndex: pageIndex,
      favorite: star ? old?.favorite ?? false : !(old?.favorite ?? false),
      starred: star ? !(old?.starred ?? false) : old?.starred ?? false)
    Task {
      do { try await session.saveState(input) } catch {
        position.stringValue = error.localizedDescription
      }
    }
  }
  @objc func changeLanguage() {
    guard let lang = language.titleOfSelectedItem,
      let new = chapter.media.first(where: { $0.language == lang })
    else { return }
    do {
      let oldIndex = pageIndex
      let urls = try media.urls(for: new)
      let aligned =
        new.pageAlignment.flatMap { oldIndex < $0.count ? $0[oldIndex] : nil } ?? oldIndex
      version = new
      self.urls = urls
      setup()
      pageIndex = max(0, min(new.pageCount - 1, aligned))
      if let pdf, let p = pdf.document?.page(at: pageIndex) {
        pdf.go(to: p)
      } else {
        pages.selectedIndex = min(pageIndex, max(0, urls.count - 1))
      }
      updatePosition()
    } catch { position.stringValue = error.localizedDescription }
  }
}
