import AppKit
import CoreGraphics

// Run with `swift scripts/verify-mac-window.swift [path/to/MangaReaderMac.app]`.
// Verify a real onscreen main window, not merely a live process. Close only the
// instance launched by this check; existing Xcode/user instances are untouched.
let path = CommandLine.arguments.dropFirst().first
  ?? ".build/xcode-mac/Build/Products/Debug/MangaReaderMac.app"
let url = URL(fileURLWithPath: path).standardizedFileURL
guard Bundle(url: url)?.bundleIdentifier == "com.thristram.mangareader.mac" else {
  fputs("Build the MangaReaderMac target first, or pass its .app path.\n", stderr)
  exit(1)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
var launchedApp: NSRunningApplication?
var launchError: Error?
NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
  DispatchQueue.main.async {
    launchedApp = app
    launchError = error
  }
}
let deadline = Date().addingTimeInterval(15)
var visibleWindow: [String: Any]?
while Date() < deadline && launchError == nil {
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  guard let app = launchedApp else { continue }
  if app.isTerminated { break }
  let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
  ) as? [[String: Any]] ?? []
  visibleWindow = windows.first { window in
    guard window[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier,
      window[kCGWindowLayer as String] as? Int == 0,
      let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
    else { return false }
    return width >= 760 && height >= 560
  }
  if visibleWindow != nil { break }
}
let passed = visibleWindow != nil && launchedApp?.activationPolicy == .regular
// A new-instance launch guarantees this does not terminate a user's running app.
_ = launchedApp?.terminate()
if passed {
  let bounds = visibleWindow![kCGWindowBounds as String] as! [String: Any]
  print("PASS: MangaReader created an onscreen main window (\(bounds["Width"]!) × \(bounds["Height"]!)).")
} else {
  fputs("FAIL: MangaReader did not show its main window within 15 seconds.\n", stderr)
  if let launchError { fputs("\(launchError.localizedDescription)\n", stderr) }
  exit(1)
}
