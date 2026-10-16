import AppKit
import SwiftUI

/// Finder's sandbox extension must be consumed in the native dragging callback.
/// Reading the global drag pasteboard from a later SwiftUI callback is not equivalent.
struct ImportDropHost<Content: View>: NSViewRepresentable {
  var enabled: Bool
  @Binding var targeted: Bool
  var receive: (ImportSourceAccess) -> Void
  var failure: (Error) -> Void
  @ViewBuilder var content: () -> Content
  func makeNSView(context: Context) -> ImportDropHostingView {
    let view = ImportDropHostingView(rootView: AnyView(content()))
    view.sizingOptions = []
    updateNSView(view, context: context)
    return view
  }
  func updateNSView(_ view: ImportDropHostingView, context: Context) {
    view.rootView = AnyView(content())
    view.accepting = enabled
    view.targeted = { targeted = $0 }
    view.receive = receive
    view.failure = failure
  }
}
final class ImportDropHostingView: NSHostingView<AnyView> {
  var accepting = true
  var targeted: (Bool) -> Void = { _ in }
  var receive: (ImportSourceAccess) -> Void = { _ in }
  var failure: (Error) -> Void = { _ in }
  required init(rootView: AnyView) {
    super.init(rootView: rootView)
    registerForDraggedTypes([.fileURL])
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let accepted =
      accepting
      && sender.draggingPasteboard.canReadObject(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    targeted(accepted)
    return accepted ? .copy : []
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { targeted(false) }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepting }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { targeted(false) }
    return accept(sender.draggingPasteboard)
  }
  override func concludeDragOperation(_ sender: NSDraggingInfo?) { targeted(false) }
  @discardableResult func accept(_ pasteboard: NSPasteboard) -> Bool {
    guard accepting else { return false }
    let urls =
      pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    var accepted = false
    for url in urls {
      do {
        // Capture every grant here, before scheduling scanning or returning to AppKit.
        let access = try ImportSourceAccess(url)
        receive(access)
        accepted = true
      } catch { failure(error) }
    }
    return accepted
  }
}
