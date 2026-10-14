import AppKit
import Foundation
import MangaCore

@main @MainActor struct WelcomeStateChecks {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
  }
  static func drain() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
  }
  static func main() throws {
    let defaults = UserDefaults.standard
    defaults.set("https://obsolete.invalid", forKey: "MangaAPIURL")
    defaults.set("https://obsolete.invalid/resource", forKey: "MangaAPIAudience")
    defer {
      defaults.removeObject(forKey: "MangaAPIURL")
      defaults.removeObject(forKey: "MangaAPIAudience")
    }
    expect(AppConfiguration.current().apiURL.absoluteString == Bundle.main.object(forInfoDictionaryKey: "MangaAPIURL") as? String, "old preferences must not override the project API endpoint")
    expect(AppConfiguration.current().audience == Bundle.main.object(forInfoDictionaryKey: "MangaAPIAudience") as? String, "old preferences must not override the project audience")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    let session = AppSession()
    let root = MacRootController(session: session)
    let window = NSWindow(contentViewController: root)
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 1200, height: 800))
    window.makeKeyAndOrderFront(nil)
    drain()
    expect(root.children.count == 1 && root.children.first is MacSignInController, "signed-out root must show only the welcome screen")
    expect(window.toolbar == nil, "signed-out root must have no library toolbar")
    let splash = root.children.first as! MacSignInController
    session.busy = true
    drain()
    expect(!splash.signIn.isEnabled, "busy session must disable duplicate sign-in")
    session.busy = false
    drain()
    expect(splash.signIn.isEnabled, "completed session must re-enable sign-in")
    splash.signIn.performClick(nil)
    drain()
    expect(session.account == nil && !session.busy && splash.signIn.isEnabled, "invalid build configuration must remain on a retryable welcome screen")
    expect(splash.message.stringValue == "Sign-in is not configured for this build.", "configuration failure must be visible")
    func account(_ subject: String) throws -> VerifiedAccount {
      let json = "{\"ownerId\":\"welcome-check-\(subject)\",\"issuer\":\"https://auth.thenoirclub.com/api/auth\",\"subject\":\"\(subject)\",\"scopes\":[\"manga:read\"]}"
      return try JSONDecoder().decode(VerifiedAccount.self, from: Data(json.utf8))
    }
    session.account = try account("alice")
    drain()
    expect(root.children.first is MacLibraryController, "a verified identity must reveal the library")
    expect(window.toolbar != nil, "verified identity must reveal the library toolbar")
    let firstLibrary = root.children.first as! MacLibraryController
    let reader = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    reader.isReleasedWhenClosed = false
    reader.makeKeyAndOrderFront(nil)
    firstLibrary.readerWindows.append(reader)
    session.account = try account("bob")
    drain()
    expect(root.children.first is MacLibraryController && root.children.first !== firstLibrary, "identity changes must replace the old account's library")
    expect(!reader.isVisible, "identity changes must close old readers")
    session.account = nil
    drain()
    expect(root.children.first is MacSignInController && window.toolbar == nil, "sign-out must hide the library and toolbar")
    window.close()
    print("PASS: project endpoint/audience ignore obsolete preferences; welcome, busy/error, identity switch and sign-out transitions.")
  }
}
