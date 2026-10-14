import AppKit
import SwiftUI

// NSPageController supplies the interactive trackpad transition used by native Mac readers.
struct MacReaderPager: NSViewControllerRepresentable {
  @Binding var index: Int
  var count: Int
  var rightToLeft = false
  private var pages: [Int] { rightToLeft ? Array((0..<count).reversed()) : Array(0..<count) }
  var content: (Int) -> AnyView
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSViewController(context: Context) -> NSPageController {
    let controller = ReaderPageController()
    controller.transitionStyle = .horizontalStrip
    context.coordinator.updating = true
    controller.delegate = context.coordinator
    controller.arrangedObjects = pages
    controller.selectedIndex = pages.firstIndex(of: index) ?? 0
    context.coordinator.updating = false
    return controller
  }
  func updateNSViewController(_ controller: NSPageController, context: Context) {
    context.coordinator.parent = self
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    if controller.arrangedObjects.count != count
      || (controller.arrangedObjects.first as? Int) != pages.first
    {
      controller.arrangedObjects = pages
    }
    let target = min(index, max(0, count - 1))
    let position = pages.firstIndex(of: target) ?? 0
    if controller.selectedIndex != position { controller.selectedIndex = position }
    if let hosting = controller.selectedViewController as? NSHostingController<AnyView> {
      hosting.rootView = content(target)
    }
  }
  final class Coordinator: NSObject, NSPageControllerDelegate {
    var parent: MacReaderPager
    var updating = false
    init(_ parent: MacReaderPager) { self.parent = parent }
    func pageController(_ pageController: NSPageController, frameFor object: Any?) -> NSRect {
      pageController.view.bounds
    }
    func pageController(_ pageController: NSPageController, identifierFor object: Any) -> String {
      "manga-page"
    }
    func pageController(
      _ pageController: NSPageController, viewControllerForIdentifier identifier: String
    ) -> NSViewController {
      let hosting = NSHostingController(rootView: AnyView(Color.black))
      hosting.sizingOptions = []
      hosting.view.autoresizingMask = [.width, .height]
      return hosting
    }
    func pageController(
      _ pageController: NSPageController, prepare viewController: NSViewController,
      with object: Any?
    ) {
      guard let index = object as? Int,
        let hosting = viewController as? NSHostingController<AnyView>
      else { return }
      hosting.rootView = parent.content(index)
      hosting.view.frame = pageController.view.bounds
    }
    func pageController(_ pageController: NSPageController, didTransitionTo object: Any) {
      if !updating, let index = object as? Int, parent.index != index { parent.index = index }
    }
    func pageControllerDidEndLiveTransition(_ pageController: NSPageController) {
      pageController.completeTransition()
      if !updating, let page = pageController.arrangedObjects[pageController.selectedIndex] as? Int,
        parent.index != page
      {
        parent.index = page
      }
    }
  }
}

// NSPageController can prepare its first hosted page before SwiftUI assigns the
// viewport size. Keep the live page sized to the final container on every layout.
final class ReaderPageController: NSPageController {
  override func viewDidLayout() {
    super.viewDidLayout()
    selectedViewController?.view.frame = view.bounds
  }
}
