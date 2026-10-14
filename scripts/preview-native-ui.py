#!/usr/bin/env python3
"""Build an isolated native UI preview, with synthetic data and no valid OAuth ID.
No preview entrypoint is included in the real targets; user credentials/cache are not used.
"""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("platform", choices=["mac", "phone"])
parser.add_argument("--destination", help="Override the Xcode destination, such as platform=iOS Simulator,id=…")
args = parser.parse_args()
preview = root / ".build/native-ui-preview"
(preview / "scripts").mkdir(parents=True, exist_ok=True)
app = preview / "apps/apple"
shutil.copytree(root / "apps/apple", app, dirs_exist_ok=True, ignore=shutil.ignore_patterns("Local.xcconfig", "xcuserdata"))
(preview / "packages").mkdir(exist_ok=True)
core = preview / "packages/MangaCore"
if not core.exists(): core.symlink_to(root / "packages/MangaCore", target_is_directory=True)
shutil.copy2(root / "scripts/generate-xcode-project.py", preview / "scripts/generate-xcode-project.py")
shutil.copy2(root / "scripts/native-ui-fixtures.swift", app / "Shared/NativeUIFixtures.swift")
(app / "Config/Base.xcconfig").write_text('MAC_OAUTH_CLIENT_ID = configure-preview\nIPHONE_OAUTH_CLIENT_ID = configure-preview\n#include "Service.xcconfig"\n')
project = app / "MangaReader.xcodeproj/project.pbxproj"
data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project)]))
for obj in data["objects"].values():
    if obj["isa"] == "XCBuildConfiguration" and "PRODUCT_BUNDLE_IDENTIFIER" in obj.get("buildSettings", {}):
        obj["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] += ".uipreview"
project.write_text(json.dumps(data))
subprocess.run(["plutil", "-convert", "xml1", str(project)], check=True)
(app / "Mac/AppDelegate.swift").write_text('''import AppKit
import SwiftUI
@main @MainActor enum PreviewApp {
  static func main() {
    let app = NSApplication.shared
    let delegate = PreviewDelegate(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
@MainActor final class PreviewDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var model: LibraryUIModel!
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    do {
      let directory = URL(fileURLWithPath: "''' + str(preview / "fixtures") + '''")
      let session = AppSession(cacheRoot: directory.appendingPathComponent("cache"))
      model = try NativeUIFixtures.seed(session: session, directory: directory)
      window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
      window.title = "MangaReader · Native UI Preview"; window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
      let hosting = NSHostingController(rootView: MangaRootScreen(session: session, library: model)); hosting.sizingOptions = []
      window.contentViewController = hosting
      window.minSize = NSSize(width: 760, height: 560)
      window.setContentSize(NSSize(width: 1200, height: 850))
      let menu = NSMenu(); let appMenu = NSMenu()
      appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
      let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
      NSApp.mainMenu = menu
      window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    } catch { NSLog("Preview setup failed: %@", error.localizedDescription); NSApp.terminate(nil) }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
''')
(app / "iPhone/AppDelegate.swift").write_text('''import UIKit
import SwiftUI
@main final class PhoneAppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration { UISceneConfiguration(name: "Default", sessionRole: session.role) }
}
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    do {
      let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ui-fixtures")
      let session = AppSession(cacheRoot: directory.appendingPathComponent("cache"))
      let model = try NativeUIFixtures.seed(session: session, directory: directory)
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIHostingController(rootView: MangaRootScreen(session: session, library: model))
      self.window = window; window.makeKeyAndVisible()
    } catch { fatalError("Preview setup failed") }
  }
}
''')
subprocess.run(["python3", str(preview / "scripts/generate-xcode-project.py")], check=True)
scheme = "MangaReaderMac" if args.platform == "mac" else "MangaReaderiPhone"
destination = args.destination or ("platform=macOS,arch=arm64" if args.platform == "mac" else "generic/platform=iOS Simulator")
command = ["xcodebuild", "-project", str(project.parent), "-scheme", scheme, "-destination", destination, "-derivedDataPath", str(preview / ("build-" + args.platform)), "build"]
if args.platform == "mac": command.insert(-1, "CODE_SIGNING_ALLOWED=NO")
with (preview / (args.platform + "-build.log")).open("w") as log:
    subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
print(preview / ("build-" + args.platform) / "Build/Products" / ("Debug" if args.platform == "mac" else "Debug-iphonesimulator") / (scheme + ".app"))
