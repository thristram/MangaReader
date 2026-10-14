import AppKit
import Combine

final class MacRootController: NSViewController {
  let session: AppSession
  private var observation: AnyCancellable?
  private var activeController: NSViewController?
  private var activeOwnerId: String?
  init(session: AppSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    updateContent()
    // Library uses onChange for data refresh; the root independently observes identity.
    observation = session.$account.map { $0?.ownerId }.removeDuplicates()
      .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateContent() }
  }
  private func updateContent() {
    let signedIn = session.account != nil
    let ownerId = session.account?.ownerId
    if activeController != nil && activeOwnerId == ownerId { return }
    activeOwnerId = ownerId
    if let library = activeController as? MacLibraryController {
      library.readerWindows.forEach { $0.close() }
      library.presentedViewControllers?.forEach { library.dismiss($0) }
      library.media.release()
    }
    activeController?.view.removeFromSuperview()
    activeController?.removeFromParent()
    view.window?.toolbar = nil
    let controller: NSViewController = signedIn
      ? MacLibraryController(session: session) : MacSignInController(session: session)
    activeController = controller
    addChild(controller)
    view.addSubview(controller.view)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

final class MacSignInController: NSViewController {
  let session: AppSession
  let signIn = NSButton(title: "Sign In", target: nil, action: nil)
  let message = NSTextField(wrappingLabelWithString: "")
  let progress = NSProgressIndicator()
  private var observation: AnyCancellable?
  init(session: AppSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    view = NSView()
    let background = NSVisualEffectView()
    background.material = .windowBackground
    background.blendingMode = .behindWindow
    background.state = .followsWindowActiveState
    view.addSubview(background)
    background.translatesAutoresizingMaskIntoConstraints = false
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 20
    let icon = NSImageView(image: NSImage(systemSymbolName: "books.vertical.fill",
      accessibilityDescription: "MangaReader")!)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.contentTintColor = .controlAccentColor
    let title = NSTextField(labelWithString: "MangaReader")
    title.font = .systemFont(ofSize: 42, weight: .bold)
    let subtitle = NSTextField(wrappingLabelWithString: "Your library, wherever you read.")
    subtitle.alignment = .center
    subtitle.textColor = .secondaryLabelColor
    subtitle.font = .systemFont(ofSize: 17)
    signIn.bezelStyle = .rounded
    signIn.controlSize = .large
    signIn.keyEquivalent = "\r"
    signIn.target = self
    signIn.action = #selector(startSignIn)
    message.alignment = .center
    message.textColor = .secondaryLabelColor
    progress.style = .spinning
    progress.isDisplayedWhenStopped = false
    for v in [icon, title, subtitle, signIn, progress, message] { stack.addArrangedSubview(v) }
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      background.topAnchor.constraint(equalTo: view.topAnchor),
      background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      stack.widthAnchor.constraint(equalToConstant: 420),
      icon.widthAnchor.constraint(equalToConstant: 72),
      icon.heightAnchor.constraint(equalToConstant: 72),
      signIn.widthAnchor.constraint(equalToConstant: 180),
      message.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    observation = session.$status.combineLatest(session.$busy).receive(on: RunLoop.main)
      .sink { [weak self] status, busy in
        guard let self else { return }
        signIn.isEnabled = !busy
        message.stringValue = ["Sign in to your MangaReader library.", "Signed out"].contains(status)
          ? "" : status
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
      }
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.toolbar = nil
  }
  @objc func startSignIn() { session.login() }
}
