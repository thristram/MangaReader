import AppKit
import SwiftUI

// AppKit owns application/window lifecycle; every screen is SwiftUI.
final class MacRootController: NSHostingController<MangaRootScreen> {
  let session: AppSession
  init(session: AppSession) {
    self.session = session
    super.init(rootView: MangaRootScreen(session: session))
    sizingOptions = []
  }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
