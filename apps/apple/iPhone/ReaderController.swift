import AVKit
import MangaCore
import PDFKit
import UIKit

final class ImagePageController: UIViewController, UIScrollViewDelegate {
  let url: URL
  let scroll = UIScrollView()
  let image = UIImageView()
  var initialized = false
  init(url: URL) {
    self.url = url
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    scroll.delegate = self
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 8
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.showsVerticalScrollIndicator = false
    scroll.showsHorizontalScrollIndicator = false
    view.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    image.image = UIImage(contentsOfFile: url.path)
    image.contentMode = .scaleAspectFit
    scroll.addSubview(image)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
    doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let bitmap = image.image, bitmap.size.height > 0 else { return }
    if scroll.zoomScale == 1 || !initialized {
      let h = view.bounds.height
      let w = max(view.bounds.width, h * bitmap.size.width / bitmap.size.height)
      image.frame = CGRect(x: 0, y: 0, width: w, height: h)
      scroll.contentSize = image.bounds.size
      scroll.contentOffset = CGPoint(x: max(0, (w - view.bounds.width) / 2), y: 0)
      initialized = true
    }
  }
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
  @objc func toggleZoom() { scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2, animated: true) }
}
final class PhoneReaderController: UIViewController, UIPageViewControllerDataSource,
  UIPageViewControllerDelegate
{
  let chapter: LibraryEntity
  var media: MediaVersion
  var urls: [URL]
  let session: AppSession
  let smb: SMBMedia
  var pager: UIPageViewController!
  var pageIndex = 0
  var document: PDFDocument?
  var controllers: [Int: UIViewController] = [:]
  init(chapter: LibraryEntity, media: MediaVersion, urls: [URL], session: AppSession, smb: SMBMedia)
  {
    self.chapter = chapter
    self.media = media
    self.urls = urls
    self.session = session
    self.smb = smb
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    pageIndex = min(
      media.pageCount - 1,
      session.states.first { $0.entityId == chapter.id && $0.pageIndex == nil }?.progress?.pageIndex
        ?? 0)
    pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    pager.dataSource = self
    pager.delegate = self
    addChild(pager)
    view.addSubview(pager.view)
    pager.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      pager.view.topAnchor.constraint(equalTo: view.topAnchor),
      pager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    pager.didMove(toParent: self)
    setup()
    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
    tap.cancelsTouchesInView = false
    view.addGestureRecognizer(tap)
  }
  func setup() {
    controllers = [:]
    document = media.kind == "pdf" ? urls.first.flatMap { PDFDocument(url: $0) } : nil
    pager.setViewControllers([page(pageIndex)], direction: .forward, animated: false)
    updateControls()
  }
  func page(_ index: Int) -> UIViewController {
    if let c = controllers[index] { return c }
    let vc: UIViewController
    if media.kind == "pdf" {
      vc = UIViewController()
      let pdf = PDFView()
      pdf.document = document
      pdf.displayMode = .singlePage
      pdf.autoScales = true
      pdf.backgroundColor = .black
      if let p = document?.page(at: index) { pdf.go(to: p) }
      vc.view = pdf
    } else if media.kind == "video" {
      let player = AVPlayerViewController()
      if let url = urls.first { player.player = AVPlayer(url: url) }
      vc = player
    } else if index < urls.count {
      vc = ImagePageController(url: urls[index])
    } else {
      vc = UIViewController()
      vc.view.backgroundColor = .black
    }
    controllers[index] = vc
    return vc
  }
  func index(_ vc: UIViewController) -> Int? { controllers.first { $0.value === vc }?.key }
  func pageViewController(
    _ pageViewController: UIPageViewController, viewControllerBefore vc: UIViewController
  ) -> UIViewController? {
    guard let i = index(vc), i > 0 else { return nil }
    return page(i - 1)
  }
  func pageViewController(
    _ pageViewController: UIPageViewController, viewControllerAfter vc: UIViewController
  ) -> UIViewController? {
    guard let i = index(vc), i + 1 < media.pageCount else { return nil }
    return page(i + 1)
  }
  func pageViewController(
    _ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController], transitionCompleted completed: Bool
  ) {
    guard completed, let vc = pager.viewControllers?.first, let i = index(vc) else { return }
    pageIndex = i
    updateControls()
    saveProgress()
    controllers = controllers.filter { abs($0.key - i) < 3 }
  }
  func updateControls() {
    title = "\(pageIndex+1) / \(media.pageCount)"
    navigationItem.largeTitleDisplayMode = .never
    let languages = UIMenu(
      children: chapter.media.map { v in
        UIAction(title: v.language, state: v.id == media.id ? .on : .off) { [weak self] _ in
          self?.switchLanguage(v)
        }
      })
    let actions = UIMenu(children: [
      UIAction(title: "Favorite page", image: UIImage(systemName: "heart")) { [weak self] _ in
        self?.toggle(star: false)
      },
      UIAction(title: "Star page", image: UIImage(systemName: "star")) { [weak self] _ in
        self?.toggle(star: true)
      },
    ])
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(image: UIImage(systemName: "globe"), menu: languages),
      UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: actions),
    ]
  }
  @objc func toggleControls() {
    navigationController?.setNavigationBarHidden(
      !(navigationController?.isNavigationBarHidden ?? false), animated: true)
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setNavigationBarHidden(false, animated: true)
    saveProgress()
  }
  func saveProgress() {
    let old = session.states.first { $0.entityId == chapter.id && $0.pageIndex == nil }
    Task {
      do {
        try await session.saveState(
          StateInput(
            entityId: chapter.id, favorite: old?.favorite ?? false, starred: old?.starred ?? false,
            progress: ReadingProgress(
              mediaId: media.id, pageIndex: pageIndex, completed: pageIndex == media.pageCount - 1))
        )
      } catch { session.status = error.localizedDescription }
    }
  }
  func toggle(star: Bool) {
    let old = session.states.first { $0.entityId == chapter.id && $0.pageIndex == pageIndex }
    Task {
      do {
        try await session.saveState(
          StateInput(
            entityId: chapter.id, pageIndex: pageIndex,
            favorite: star ? old?.favorite ?? false : !(old?.favorite ?? false),
            starred: star ? !(old?.starred ?? false) : old?.starred ?? false))
      } catch { session.status = error.localizedDescription }
    }
  }
  func switchLanguage(_ version: MediaVersion) {
    Task {
      do {
        let files = try await smb.download(version)
        let aligned =
          version.pageAlignment.flatMap { pageIndex < $0.count ? $0[pageIndex] : nil } ?? pageIndex
        media = version
        urls = files
        pageIndex = max(0, min(version.pageCount - 1, aligned))
        setup()
      } catch { session.status = error.localizedDescription }
    }
  }
}
