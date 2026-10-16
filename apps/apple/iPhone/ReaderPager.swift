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
    cachedPages = cachedPages.filter { abs($0.key - visibleIndex) <= 1 }
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { pageCount }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PhoneReaderCell
    let index = canonical(indexPath.item)
    let host = cachedPages[index] ?? PhoneReaderPageHost(index: index, content: content!(index))
    cachedPages[index] = host
    cell.attach(host, to: self, gap: gap)
    return cell
  }
  func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                      forItemAt indexPath: IndexPath) {
    (cell as? PhoneReaderCell)?.detach()
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
    pruneCache()
  }
  @objc private func tappedCanvas() { onCanvasTap?() }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === canvasTap
      && (otherGestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
  }
}

final class PhoneReaderCell: UICollectionViewCell {
  private var host: PhoneReaderPageHost?
  private var gap: CGFloat = 0
  func attach(_ host: PhoneReaderPageHost, to parent: UIViewController, gap: CGFloat) {
    if self.host !== host {
      detach()
      self.host = host
      parent.addChild(host)
      contentView.addSubview(host.view)
      host.didMove(toParent: parent)
    }
    self.gap = gap
    setNeedsLayout()
  }
  func detach() {
    host?.willMove(toParent: nil)
    host?.view.removeFromSuperview()
    host?.removeFromParent()
    host = nil
  }
  override func prepareForReuse() { super.prepareForReuse(); detach() }
  override func layoutSubviews() {
    super.layoutSubviews()
    host?.view.frame = CGRect(x: 0, y: 0, width: max(0, contentView.bounds.width - gap), height: contentView.bounds.height)
  }
}

final class PhoneReaderPageHost: UIHostingController<AnyView> {
  let index: Int
  init(index: Int, content: AnyView) {
    self.index = index
    super.init(rootView: content)
    sizingOptions = []
    safeAreaRegions = []
    view.backgroundColor = .black
  }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
