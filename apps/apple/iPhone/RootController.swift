import SwiftUI
import UIKit

// UIKit owns scene lifecycle and ASWeb presentation; screens are SwiftUI.
final class PhoneRootController: UIHostingController<MangaRootScreen> {
  init(session: AppSession) { super.init(rootView: MangaRootScreen(session: session)) }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
