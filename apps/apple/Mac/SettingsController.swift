import AppKit
import MangaCore

final class MacSettingsController: NSViewController {
  let session: AppSession
  let media: LocalMedia
  let section: String
  var fields: [String: NSTextField] = [:]
  init(session: AppSession, media: LocalMedia, section: String) {
    self.session = session
    self.media = media
    self.section = section
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: view.topAnchor),
    ])
    let title = NSTextField(labelWithString: section)
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    stack.addArrangedSubview(title)
    let c = AppConfiguration.current()
    var values: [(String, String, String)] = []
    switch section {
    case "Connections":
      values = [
        ("MangaAPIURL", "Metadata API URL", c.apiURL.absoluteString),
        ("AuthIssuer", "Auth issuer", c.issuer.absoluteString),
        ("MangaAPIAudience", "API resource / audience", c.audience),
        ("OAuthClientID", "Mac public OAuth client ID", c.clientId),
      ]
    case "Reading":
      values = [("ContentLanguage", "Preferred manga language", AppConfiguration.preferredLanguage)]
      let nsfw = NSButton(
        checkboxWithTitle: "Show NSFW content", target: self, action: #selector(nsfwChanged(_:)))
      nsfw.state = AppConfiguration.showNSFW ? .on : .off
      stack.addArrangedSubview(nsfw)
      let ui = NSTextField(
        labelWithString: "Interface language: English (system localization will follow later).")
      stack.addArrangedSubview(ui)
    case "Ollama":
      values = [
        (
          "OllamaURL", "Local Ollama host",
          UserDefaults.standard.string(forKey: "OllamaURL") ?? "http://localhost:11434"
        ), ("OllamaModel", "Model", UserDefaults.standard.string(forKey: "OllamaModel") ?? ""),
        (
          "OllamaPrompt", "System prompt",
          UserDefaults.standard.string(forKey: "OllamaPrompt")
            ?? "Translate titles and descriptions faithfully. Return JSON with title and description. Preserve names and meaning; add no commentary."
        ),
      ]
    default:
      stack.addArrangedSubview(
        NSTextField(
          wrappingLabelWithString:
            "Metadata synchronizes every 30 seconds while the app is open. Writes require a connection in this milestone. Conflicting revisions require reloading; offline queued edits will be added next."
        ))
    }
    for (key, label, value) in values {
      stack.addArrangedSubview(NSTextField(labelWithString: label))
      let field = NSTextField(string: value)
      field.placeholderString = label
      fields[key] = field
      stack.addArrangedSubview(field)
      field.widthAnchor.constraint(equalToConstant: 560).isActive = true
    }
    if section == "Connections" {
      let connect = NSButton(
        title: "Connect a local / Finder-mounted SMB root…", target: self,
        action: #selector(bindRoot))
      stack.addArrangedSubview(connect)
    }
    let save = NSButton(title: "Save", target: self, action: #selector(save))
    save.bezelStyle = .rounded
    save.keyEquivalent = "\r"
    stack.addArrangedSubview(save)
  }
  @objc func nsfwChanged(_ b: NSButton) {
    UserDefaults.standard.set(b.state == .on, forKey: "ShowNSFW")
    session.onChange?()
  }
  @objc func save() {
    for (key, f) in fields {
      if ["MangaAPIURL", "AuthIssuer", "MangaAPIAudience"].contains(key) {
        guard let url = URL(string: f.stringValue), url.scheme == "https", url.host != nil else {
          let a = NSAlert()
          a.messageText = "Enter a valid HTTPS URL"
          a.runModal()
          return
        }
      }
    }
    if section == "Connections"
      && fields.contains(where: {
        UserDefaults.standard.string(forKey: $0.key) != $0.value.stringValue
      })
    {
      media.release()
      session.signOut()
    }
    for (key, f) in fields { UserDefaults.standard.set(f.stringValue, forKey: key) }
    session.onChange?()
    dismiss(self)
  }
  @objc func bindRoot() {
    guard session.account != nil else { return }
    let roots = session.entities.filter { $0.kind == .storageRoot && !$0.deleted }
    guard !roots.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Choose storage root"
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
    popup.addItems(withTitles: roots.map(\.title))
    alert.accessoryView = popup
    alert.addButton(withTitle: "Choose folder")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try media.bind(roots[popup.indexOfSelectedItem], to: url) } catch {
      session.status = error.localizedDescription
    }
  }
}
