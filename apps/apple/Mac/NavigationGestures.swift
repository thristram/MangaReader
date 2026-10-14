import AppKit
import SwiftUI

// Observe native swipe events only in this window. Scroll views still own vertical scrolling.
struct MacNavigationGestures: NSViewRepresentable {
  var back: () -> Void
  var forward: () -> Void
  func makeNSView(context: Context) -> NavigationSwipeView {
    let view = NavigationSwipeView()
    view.back = back
    view.forward = forward
    return view
  }
  func updateNSView(_ view: NavigationSwipeView, context: Context) {
    view.back = back
    view.forward = forward
  }
}
final class NavigationSwipeView: NSView {
  var back: (() -> Void)?
  var forward: (() -> Void)?
  private var monitor: Any?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      return
    }
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
      guard let self, event.window === self.window, abs(event.deltaX) > abs(event.deltaY) else {
        return event
      }
      if event.deltaX > 0 { self.back?() } else { self.forward?() }
      return nil
    }
  }
  deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

// SwiftUI owns rows and selection. Use the public AppKit appearance setting so
// its blue source-list highlight does not cover the Music-style neutral row.
struct MacSidebarSelectionAppearance: NSViewRepresentable {
  func makeNSView(context: Context) -> SidebarAppearanceView { SidebarAppearanceView() }
  func updateNSView(_ view: SidebarAppearanceView, context: Context) { view.applyAppearance() }
}
final class SidebarAppearanceView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance()
  }
  func applyAppearance() {
    DispatchQueue.main.async { [weak self] in
      func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let result = table(in: child) { return result } }
        return nil
      }
      var ancestor = self?.superview
      for _ in 0..<8 {
        guard let view = ancestor else { return }
        if let list = table(in: view) {
          list.selectionHighlightStyle = .none
          return
        }
        ancestor = view.superview
      }
    }
  }
}
