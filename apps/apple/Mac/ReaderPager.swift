import AppKit
import MangaCore
import SwiftUI

// NSPageController supplies the interactive trackpad transition used by native Mac readers.
struct MacReaderPager: NSViewControllerRepresentable {
  @Binding var index: Int
  var count: Int
  var rightToLeft = false
  var onTogglePlayback: (() -> Void)?
  private var pages: [Int] { rightToLeft ? Array((0..<count).reversed()) : Array(0..<count) }
  var content: (Int) -> AnyView
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSViewController(context: Context) -> NSPageController {
    let controller = ReaderPageController()
    controller.onHorizontalScroll = { [weak coordinator = context.coordinator] step in
      guard let coordinator else { return }
      let delta = coordinator.parent.rightToLeft ? -step : step
      coordinator.parent.index = min(
        max(0, coordinator.parent.index + delta), max(0, coordinator.parent.count - 1))
    }
    controller.onKeyboardPage = { [weak coordinator = context.coordinator] step in
      guard let coordinator else { return }
      coordinator.parent.index = min(
        max(0, coordinator.parent.index + step), max(0, coordinator.parent.count - 1))
    }
    controller.onTogglePlayback = onTogglePlayback
    controller.transitionStyle = .horizontalStrip
    context.coordinator.updating = true
    controller.delegate = context.coordinator
    controller.arrangedObjects = pages
    controller.selectedIndex = pages.firstIndex(of: index) ?? 0
    context.coordinator.updating = false
    controller.installScrollMonitor()
    return controller
  }
  static func dismantleNSViewController(_ controller: NSPageController, coordinator: Coordinator) {
    (controller as? ReaderPageController)?.removeScrollMonitor()
  }
  func updateNSViewController(_ controller: NSPageController, context: Context) {
    context.coordinator.parent = self
    (controller as? ReaderPageController)?.onTogglePlayback = onTogglePlayback
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
  var onHorizontalScroll: ((Int) -> Void)?
  var onKeyboardPage: ((Int) -> Void)?
  var onTogglePlayback: (() -> Void)?
  private var scrollMonitor: Any?
  private var keyMonitor: Any?
  private var gesture = HorizontalPageGesture()
  override func viewDidAppear() {
    super.viewDidAppear()
    installScrollMonitor()
  }
  func installScrollMonitor() {
    if keyMonitor == nil {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.handleReaderKey(event)
      }
    }
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self, event.window === self.view.window,
        self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)),
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
      else { return event }
      // Trackpads retain their native interactive transition. Magic Mouse sends
      // precise horizontal wheel events without a trackpad gesture phase.
      guard event.phase.isEmpty else { return event }
      if !event.momentumPhase.isEmpty { return nil }
      let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
      if let step = self.gesture.consume(
        dx: Double(event.scrollingDeltaX) * scale,
        dy: Double(event.scrollingDeltaY) * scale, time: event.timestamp)
      {
        self.onHorizontalScroll?(step)
      }
      return nil
    }
  }
  // Observe only this reader's window, without making the image a focusable
  // control. Sheets, text editing and modified shortcuts keep normal AppKit keys.
  func handleReaderKey(_ event: NSEvent) -> NSEvent? {
    guard let window = view.window, event.window === window, window.isKeyWindow,
      window.attachedSheet == nil, view.superview != nil,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    else { return event }
    if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
    switch event.keyCode {
    case 124, 125: onKeyboardPage?(1)
    case 123, 126: onKeyboardPage?(-1)
    case 49 where onTogglePlayback != nil: onTogglePlayback?()
    default: return event
    }
    return nil
  }
  override func viewDidDisappear() {
    super.viewDidDisappear()
    removeScrollMonitor()
  }
  func removeScrollMonitor() {
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    scrollMonitor = nil
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    gesture = HorizontalPageGesture()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    selectedViewController?.view.frame = view.bounds
  }
}
