import Combine
import UIKit

final class PhoneRootController: UIViewController {
  let session: AppSession
  private var observation: AnyCancellable?
  private var activeController: UIViewController?
  private var activeOwnerId: String?
  init(session: AppSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    updateContent()
    observation = session.$account.map { $0?.ownerId }.removeDuplicates()
      .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateContent() }
  }
  private func updateContent() {
    let signedIn = session.account != nil
    let ownerId = session.account?.ownerId
    if activeController != nil && activeOwnerId == ownerId { return }
    activeOwnerId = ownerId
    activeController?.dismiss(animated: false)
    activeController?.willMove(toParent: nil)
    activeController?.view.removeFromSuperview()
    activeController?.removeFromParent()
    let controller: UIViewController = signedIn
      ? PhoneTabController(session: session) : PhoneSignInController(session: session)
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
    controller.didMove(toParent: self)
  }
}

final class PhoneSignInController: UIViewController {
  let session: AppSession
  let signIn = UIButton(type: .system)
  let message = UILabel()
  let progress = UIActivityIndicatorView(style: .medium)
  private var observation: AnyCancellable?
  init(session: AppSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let icon = UIImageView(image: UIImage(systemName: "books.vertical.fill"))
    icon.tintColor = .systemPink
    icon.contentMode = .scaleAspectFit
    let title = UILabel()
    title.text = "MangaReader"
    title.font = .preferredFont(forTextStyle: .largeTitle)
    title.adjustsFontForContentSizeCategory = true
    let subtitle = UILabel()
    subtitle.text = "Your library, wherever you read."
    subtitle.font = .preferredFont(forTextStyle: .body)
    subtitle.adjustsFontForContentSizeCategory = true
    subtitle.textColor = .secondaryLabel
    subtitle.numberOfLines = 0
    subtitle.textAlignment = .center
    var configuration = UIButton.Configuration.prominentGlass()
    configuration.title = "Sign In"
    configuration.baseBackgroundColor = .systemPink
    configuration.cornerStyle = .capsule
    configuration.buttonSize = .large
    signIn.configuration = configuration
    signIn.addAction(UIAction { [weak self] _ in self?.session.login() }, for: .touchUpInside)
    message.numberOfLines = 0
    message.textAlignment = .center
    message.textColor = .secondaryLabel
    message.font = .preferredFont(forTextStyle: .footnote)
    message.adjustsFontForContentSizeCategory = true
    progress.hidesWhenStopped = true
    let stack = UIStackView(arrangedSubviews: [icon, title, subtitle, signIn, progress, message])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 20
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
      icon.widthAnchor.constraint(equalToConstant: 72),
      icon.heightAnchor.constraint(equalToConstant: 72),
      signIn.widthAnchor.constraint(equalToConstant: 200),
      message.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    observation = session.$status.combineLatest(session.$busy).receive(on: RunLoop.main)
      .sink { [weak self] status, busy in
        guard let self else { return }
        signIn.isEnabled = !busy
        message.text = ["Sign in to your MangaReader library.", "Signed out"].contains(status)
          ? nil : status
        message.isHidden = message.text == nil
        if busy { progress.startAnimating() } else { progress.stopAnimating() }
      }
  }
}
