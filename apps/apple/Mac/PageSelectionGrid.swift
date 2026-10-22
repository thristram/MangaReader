import AppKit
import SwiftUI

// AppKit owns click, Command/Shift selection and rubber-band selection.
struct MacPageSelectionGrid: NSViewRepresentable {
  let pages: [Int]
  @Binding var selection: Set<Int>
  var content: (Int) -> AnyView
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let layout = PageSelectionLayout()
    layout.itemSize = NSSize(width: 140, height: 215)
    layout.minimumInteritemSpacing = 18
    layout.minimumLineSpacing = 18
    layout.sectionInset = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
    let collection = NSCollectionView()
    collection.collectionViewLayout = layout
    collection.isSelectable = true
    collection.allowsMultipleSelection = true
    collection.allowsEmptySelection = true
    collection.backgroundColors = [.clear]
    collection.dataSource = context.coordinator
    collection.delegate = context.coordinator
    collection.register(PageSelectionItem.self, forItemWithIdentifier: .init("page"))
    collection.setAccessibilityLabel("Page selection")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 850, height: 400))
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = collection
    collection.frame = scroll.contentView.bounds
    collection.autoresizingMask = [.width]
    context.coordinator.collection = collection
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    let changed = coordinator.parent.pages != pages || !coordinator.configured
    coordinator.parent = self
    guard let collection = coordinator.collection else { return }
    coordinator.updating = true
    coordinator.configured = true
    if changed || collection.numberOfItems(inSection: 0) != pages.count { collection.reloadData() }
    collection.selectionIndexPaths = Set(pages.enumerated().compactMap {
      selection.contains($0.element) ? IndexPath(item: $0.offset, section: 0) : nil
    })
    for case let item as PageSelectionItem in collection.visibleItems() {
      if let path = collection.indexPath(for: item), pages.indices.contains(path.item) {
        item.configure(page: pages[path.item], content: content(pages[path.item]))
      }
    }
    coordinator.updating = false
  }
  final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var parent: MacPageSelectionGrid
    weak var collection: NSCollectionView?
    var updating = false
    var configured = false
    init(_ parent: MacPageSelectionGrid) { self.parent = parent }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { parent.pages.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
      let item = collectionView.makeItem(withIdentifier: .init("page"), for: path) as! PageSelectionItem
      let page = parent.pages[path.item]
      item.configure(page: page, content: parent.content(page))
      return item
    }
    private func selected(_ collection: NSCollectionView) {
      guard !updating else { return }
      parent.selection = Set(collection.selectionIndexPaths.compactMap {
        parent.pages.indices.contains($0.item) ? parent.pages[$0.item] : nil
      })
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) { selected(collectionView) }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt paths: Set<IndexPath>) { selected(collectionView) }
  }
}

final class PageSelectionLayout: NSCollectionViewFlowLayout {
  override func prepare() {
    guard let width = collectionView?.bounds.width, width > 0 else { return }
    // SwiftUI may briefly propose a zero/narrow size while installing a sheet.
    // Keep every intermediate native layout valid, then restore normal spacing.
    let inset = min(CGFloat(24), max(0, (width - 1) / 2))
    sectionInset = NSEdgeInsets(top: 20, left: inset, bottom: 24, right: inset)
    itemSize = NSSize(width: min(140, max(1, width - 2 * inset)), height: 215)
    super.prepare()
  }
}

final class PageSelectionItem: NSCollectionViewItem {
  private var page = 0
  private var pageContent = AnyView(Color.clear)
  private var host: NSHostingView<AnyView>?
  override var isSelected: Bool { didSet { render() } }
  override func loadView() {
    let host = NSHostingView(rootView: AnyView(Color.clear))
    host.sizingOptions = []
    self.host = host
    view = host
  }
  func configure(page: Int, content: AnyView) {
    self.page = page
    pageContent = content
    render()
  }
  private func render() {
    _ = view
    host?.rootView = AnyView(
      VStack(spacing: 8) {
        pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(alignment: .bottomTrailing) {
            if isSelected {
              Image(systemName: "checkmark").font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .background(.blue, in: Circle()).overlay(Circle().stroke(.white, lineWidth: 3))
                .padding(7)
            }
          }
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.blue : .clear, lineWidth: 2))
        Text("Page \(page + 1)").font(.caption)
      }.padding(3).allowsHitTesting(false))
    view.setAccessibilityElement(true)
    view.setAccessibilityLabel("Page \(page + 1)")
    view.setAccessibilityValue(isSelected ? "Selected" : "Not selected")
  }
}
