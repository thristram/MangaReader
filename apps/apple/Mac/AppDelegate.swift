import AppKit

@main @MainActor final class MacAppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  let session = AppSession()
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    let menu = NSMenu()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About MangaReader",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit MangaReader", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let item = NSMenuItem()
    item.submenu = appMenu
    menu.addItem(item)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editItem.submenu = edit
    menu.addItem(editItem)
    NSApp.mainMenu = menu
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "MangaReader"
    window.minSize = NSSize(width: 760, height: 560)
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.contentViewController = MacLibraryController(session: session)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    session.restore()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
