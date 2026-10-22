import SwiftUI
import UIKit

// UIKit owns finger tracking, paging, cancellation and deceleration. Cells host
// the shared SwiftUI media pages, without constructing a whole chapter of views.
struct PhoneReaderPager: UIViewControllerRepresentable {
  @Binding var index: Int
  let count: Int
  var rightToLeft = false
  var contentID: String
  var onTap: () -> Void = {}
  var onDismiss: () -> Void = {}
  var onDismissDrag: (CGFloat) -> Void = { _ in }
  var content: (Int) -> AnyView

  func makeUIViewController(context: Context) -> PhoneReaderPageController {
    let controller = PhoneReaderPageController()
    update(controller)
    return controller
  }
  func updateUIViewController(_ controller: PhoneReaderPageController, context: Context) { update(controller) }
  private func update(_ controller: PhoneReaderPageController) {
    controller.onPageSettled = { if index != $0 { index = $0 } }
    controller.onCanvasTap = onTap
    controller.onDismiss = onDismiss
    controller.onDismissDrag = onDismissDrag
    controller.configure(index: index, count: count, rightToLeft: rightToLeft,
                         contentID: contentID, content: content)
  }
}

final class PhoneReaderPageController: UIViewController, UICollectionViewDataSource,
  UICollectionViewDelegate, UIGestureRecognizerDelegate
{
  let layout = UICollectionViewFlowLayout()
  lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
  private(set) var cachedPages: [Int: PhoneReaderPageHost] = [:]
  private(set) var visibleIndex = 0
  private var pageCount = 0
  private var rightToLeft = false
  private var contentID = ""
  private var content: ((Int) -> AnyView)?
  private var requestedIndex = 0
  private var animating = false
  private var viewportSize = CGSize.zero
  private let gap: CGFloat = 16
  var pageStride: CGFloat { view.bounds.width + gap }
  var visibleHost: PhoneReaderPageHost? { cachedPages[visibleIndex] }
  var transitioning: Bool { animating || collectionView.isDragging || collectionView.isDecelerating }
  var onPageSettled: ((Int) -> Void)?
  var onCanvasTap: (() -> Void)?
  var onDismiss: (() -> Void)?
  var onDismissDrag: ((CGFloat) -> Void)?
  private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(draggedDown(_:)))
  private lazy var canvasTap = UITapGestureRecognizer(target: self, action: #selector(tappedCanvas))

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    view.clipsToBounds = true
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 0
    layout.minimumInteritemSpacing = 0
    collectionView.backgroundColor = .black
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.isPagingEnabled = true
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.showsVerticalScrollIndicator = false
    collectionView.semanticContentAttribute = .forceLeftToRight
    collectionView.register(PhoneReaderCell.self, forCellWithReuseIdentifier: "page")
    view.addSubview(collectionView)
    dismissPan.maximumNumberOfTouches = 1
    dismissPan.delegate = self
    collectionView.addGestureRecognizer(dismissPan)
    collectionView.panGestureRecognizer.require(toFail: dismissPan)
    collectionView.isDirectionalLockEnabled = true
    canvasTap.cancelsTouchesInView = false
    canvasTap.delegate = self
    collectionView.addGestureRecognizer(canvasTap)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    let resized = viewportSize != view.bounds.size
    viewportSize = view.bounds.size
    // Each physical page includes a trailing gap. Clip it at the viewport edge
    // so a resting image uses the complete screen width.
    collectionView.frame = CGRect(x: 0, y: 0, width: pageStride, height: view.bounds.height)
    if resized {
      animating = false
      layout.itemSize = collectionView.bounds.size
      layout.invalidateLayout()
      collectionView.layoutIfNeeded()
      showRequestedPage(animated: false)
    }
    restoreVisiblePages()
  }
  func position(for index: Int) -> Int { rightToLeft ? pageCount - 1 - index : index }
  private func canonical(_ position: Int) -> Int { rightToLeft ? pageCount - 1 - position : position }

  func configure(index: Int, count: Int, rightToLeft: Bool, contentID: String,
                 content: @escaping (Int) -> AnyView) {
    loadViewIfNeeded()
    let reload = pageCount != count || self.rightToLeft != rightToLeft || self.contentID != contentID
    pageCount = count
    self.rightToLeft = rightToLeft
    self.contentID = contentID
    self.content = content
    requestedIndex = min(max(0, index), max(0, count - 1))
    if reload {
      animating = false
      collectionView.visibleCells.compactMap { $0 as? PhoneReaderCell }.forEach { $0.detach() }
      cachedPages = [:]
      visibleIndex = requestedIndex
      collectionView.reloadData()
      view.setNeedsLayout()
      view.layoutIfNeeded()
      showRequestedPage(animated: false)
    } else {
      for (index, host) in cachedPages { host.rootView = content(index) }
      if !transitioning { showRequestedPage(animated: abs(requestedIndex - visibleIndex) == 1) }
    }
  }
  private func showRequestedPage(animated: Bool) {
    guard pageCount > 0, viewportSize.width > 0 else { return }
    collectionView.layoutIfNeeded()
    let offset = CGPoint(x: CGFloat(position(for: requestedIndex)) * pageStride, y: 0)
    guard abs(collectionView.contentOffset.x - offset.x) > 0.5 else {
      visibleIndex = requestedIndex
      pruneCache()
      return
    }
    animating = animated && collectionView.window != nil && !UIAccessibility.isReduceMotionEnabled
    collectionView.setContentOffset(offset, animated: animating)
    if !animating { visibleIndex = requestedIndex; pruneCache() }
  }
  private func pruneCache() {
    // Keep any still-displayed transition cell, even when the settled index has
    // moved. Evict other distant hosts as cells are created, not just on settle.
    cachedPages = cachedPages.filter { abs($0.key - visibleIndex) <= 1 || $0.value.attachedCell != nil }
  }
  private func attach(_ cell: PhoneReaderCell, at indexPath: IndexPath) {
    let index = canonical(indexPath.item)
    guard index >= 0, index < pageCount, let content else { return }
    let host = cachedPages[index] ?? PhoneReaderPageHost(index: index, content: content(index))
    cachedPages[index] = host
    cell.attach(host, to: self, gap: gap)
  }
  private func restoreVisiblePages() {
    for case let cell as PhoneReaderCell in collectionView.visibleCells {
      if let indexPath = collectionView.indexPath(for: cell) { attach(cell, at: indexPath) }
    }
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { pageCount }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PhoneReaderCell
    attach(cell, at: indexPath)
    pruneCache()
    return cell
  }
  func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                      forItemAt indexPath: IndexPath) {
    if let cell = cell as? PhoneReaderCell { attach(cell, at: indexPath) }
  }
  func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                      forItemAt indexPath: IndexPath) {
    guard let cell = cell as? PhoneReaderCell, cell.pageIndex == canonical(indexPath.item) else { return }
    let attachment = cell.attachment
    // A recycled cell can already represent the same index in a newer display
    // cycle. Wait until UIKit finishes updating its visible-cell bookkeeping.
    Task { @MainActor [weak self, weak cell] in
      guard let self, let cell, cell.attachment == attachment else { return }
      if self.collectionView.visibleCells.contains(where: { $0 === cell }) {
        self.restoreVisiblePages()
        return
      }
      cell.detach()
      self.pruneCache()
    }
  }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { animating = false }
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { settle() }
  }
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    animating = false
    settle()
  }
  private func settle() {
    guard pageCount > 0, pageStride > gap else { return }
    let position = min(max(0, Int((collectionView.contentOffset.x / pageStride).rounded())), pageCount - 1)
    let next = canonical(position)
    let previous = visibleIndex
    let externalRequest = requestedIndex != visibleIndex
    visibleIndex = next
    if externalRequest && requestedIndex != next {
      showRequestedPage(animated: false)
    } else {
      requestedIndex = next
      // Publish only settled pages; dragging back to the original page is a no-op.
      if next != previous { onPageSettled?(next) }
    }
    restoreVisiblePages()
    pruneCache()
  }
  @objc private func tappedCanvas() { onCanvasTap?() }
  var canDismissAtCurrentZoom: Bool {
    func fitted(_ view: UIView) -> Bool {
      if let viewport = view as? PhoneReadingViewport { return viewport.isAtMinimumZoom }
      return view.subviews.allSatisfy(fitted)
    }
    return visibleHost.map { fitted($0.view) } ?? true
  }
  func shouldBeginDismissal(velocity: CGPoint) -> Bool {
    velocity.y > 0 && velocity.y > abs(velocity.x) * 1.2 && !animating && !collectionView.isDecelerating && canDismissAtCurrentZoom
  }
  func updateDismissal(translation: CGPoint, velocity: CGPoint, state: UIGestureRecognizer.State) {
    let distance = max(0, translation.y)
    switch state {
    case .began, .changed: onDismissDrag?(distance)
    case .ended:
      if distance > 100 || (distance > 35 && velocity.y > 900) { onDismiss?() }
      else { onDismissDrag?(0) }
    case .cancelled, .failed: onDismissDrag?(0)
    default: break
    }
  }
  @objc private func draggedDown(_ gesture: UIPanGestureRecognizer) {
    updateDismissal(translation: gesture.translation(in: view), velocity: gesture.velocity(in: view), state: gesture.state)
  }
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer !== dismissPan || shouldBeginDismissal(velocity: dismissPan.velocity(in: view))
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === canvasTap
      && (otherGestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
  }
}

final class PhoneReaderCell: UICollectionViewCell {
  private var host: PhoneReaderPageHost?
  var pageIndex: Int? { host?.index }
  private(set) var attachment = UUID()
  private var gap: CGFloat = 0
  func attach(_ host: PhoneReaderPageHost, to parent: UIViewController, gap: CGFloat) {
    if self.host !== host || host.view.superview !== contentView {
      detach()
      // UIKit may request the same page before its old cell's end-display
      // callback arrives. Transfer ownership before moving the hosting view.
      host.attachedCell?.detach()
      self.host = host
      attachment = UUID()
      host.attachedCell = self
      parent.addChild(host)
      contentView.addSubview(host.view)
      host.didMove(toParent: parent)
    }
    self.gap = gap
    setNeedsLayout()
  }
  func detach() {
    guard let host else { return }
    self.host = nil
    attachment = UUID()
    guard host.attachedCell === self else { return }
    host.attachedCell = nil
    host.willMove(toParent: nil)
    host.view.removeFromSuperview()
    host.removeFromParent()
  }
  override func prepareForReuse() { super.prepareForReuse(); detach() }
  override func layoutSubviews() {
    super.layoutSubviews()
    host?.view.frame = CGRect(x: 0, y: 0, width: max(0, contentView.bounds.width - gap), height: contentView.bounds.height)
  }
}

final class PhoneReaderPageHost: UIHostingController<AnyView> {
  let index: Int
  weak var attachedCell: PhoneReaderCell?
  init(index: Int, content: AnyView) {
    self.index = index
    super.init(rootView: content)
    sizingOptions = []
    safeAreaRegions = []
    view.backgroundColor = .black
  }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
