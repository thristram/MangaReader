import MangaCore
import UIKit

final class PhoneSettingsController: UITableViewController {
  let session: AppSession
  let smb: SMBMedia
  init(session: AppSession, smb: SMBMedia) {
    self.session = session
    self.smb = smb
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Settings"
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 3 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 1 : section == 1 ? 3 : 1
  }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
  { ["Connections", "Reading", "Account"][section] }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.accessoryType = .disclosureIndicator
    switch (indexPath.section, indexPath.row) {
    case (0, 0):
      cell.textLabel?.text = "SMB Storage Roots"
      cell.detailTextLabel?.text = "NAS credentials stay in Keychain on this device"
    case (1, 0):
      cell.textLabel?.text = "Preferred Manga Language"
      cell.detailTextLabel?.text = AppConfiguration.preferredLanguage
    case (1, 1):
      cell.textLabel?.text = "Show NSFW"
      let toggle = UISwitch()
      toggle.isOn = AppConfiguration.showNSFW
      toggle.addAction(
        UIAction { [weak self] _ in
          UserDefaults.standard.set(toggle.isOn, forKey: "ShowNSFW")
          self?.session.onChange?()
        }, for: .valueChanged)
      cell.accessoryView = toggle
    case (1, 2):
      cell.textLabel?.text = "Interface Language"
      cell.detailTextLabel?.text = "English"
      cell.accessoryType = .none
    default:
      cell.textLabel?.text = session.account == nil ? "Sign in with Thristram" : "Sign out"
      cell.detailTextLabel?.text = session.status
    }
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch (indexPath.section, indexPath.row) {
    case (0, 0): chooseRoot()
    case (1, 0): language()
    case (2, 0):
      if session.account == nil { session.login() } else { session.signOut() }
      tableView.reloadData()
    default: break
    }
  }
  func language() {
    let a = UIAlertController(
      title: "Preferred Manga Language",
      message:
        "Use a language code such as zh, en or ja. Unavailable versions fall back automatically.",
      preferredStyle: .alert)
    a.addTextField {
      $0.text = AppConfiguration.preferredLanguage
      $0.autocapitalizationType = .none
    }
    a.addAction(
      UIAlertAction(title: "Save", style: .default) { [weak self] _ in
        guard let code = a.textFields?.first?.text,
          code.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
        else { return }
        UserDefaults.standard.set(code, forKey: "ContentLanguage")
        self?.tableView.reloadData()
        self?.session.onChange?()
      })
    a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(a, animated: true)
  }
  func chooseRoot() {
    guard session.account != nil else {
      session.login()
      return
    }
    let roots = session.entities.filter { $0.kind == .storageRoot && !$0.deleted }
    let a = UIAlertController(
      title: "SMB Storage Root",
      message: roots.isEmpty
        ? "Create and import a storage root from the Mac app first."
        : "Connect this device to a root already in your library.", preferredStyle: .actionSheet)
    for root in roots {
      a.addAction(
        UIAlertAction(title: root.title, style: .default) { [weak self] _ in self?.configure(root) }
      )
    }
    a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    a.popoverPresentationController?.sourceView = view
    a.popoverPresentationController?.sourceRect = CGRect(
      x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    present(a, animated: true)
  }
  func configure(_ root: LibraryEntity) {
    let a = UIAlertController(
      title: root.title,
      message: "Paths are relative to the share plus the base folder. SMB3 encryption is required.",
      preferredStyle: .alert)
    let existing = try? smb.connection(rootId: root.id)
    for (placeholder, value, secure) in [
      ("smb://nas.local", existing?.server ?? "", false), ("Share", existing?.share ?? "", false),
      ("Base folder (optional)", existing?.basePath ?? "", false),
      ("Username", existing?.username ?? "", false), ("Password", existing?.password ?? "", true),
    ] {
      a.addTextField {
        $0.placeholder = placeholder
        $0.text = value
        $0.isSecureTextEntry = secure
        $0.autocapitalizationType = .none
        $0.autocorrectionType = .no
      }
    }
    a.addAction(
      UIAlertAction(title: "Save Connection", style: .default) { [weak self] _ in
        guard let self, let f = a.textFields else { return }
        do {
          try self.smb.configure(
            rootId: root.id,
            connection: .init(
              server: f[0].text ?? "", share: f[1].text ?? "", basePath: f[2].text ?? "",
              username: f[3].text ?? "", password: f[4].text ?? "", encrypted: true))
          self.tableView.reloadData()
        } catch { self.session.status = error.localizedDescription }
      })
    a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(a, animated: true)
  }
}
