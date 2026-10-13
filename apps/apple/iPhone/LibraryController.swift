import MangaCore
import UIKit

final class PhoneTabController: UITabBarController {
  let session: AppSession
  let smb: SMBMedia
  var libraries: [PhoneLibraryController] = []
  var lastOwner: String?
  init(session: AppSession) {
    self.session = session
    smb = SMBMedia(session: session)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    tabBarMinimizeBehavior = .onScrollDown
    for (title, symbol) in [
      ("Library", "books.vertical"), ("Continue Reading", "book"),
      ("Downloads", "arrow.down.circle"),
    ] {
      let vc = PhoneLibraryController(session: session, smb: smb, section: title)
      libraries.append(vc)
      _ = symbol
    }
    viewControllers = libraries.map {
      let nav = UINavigationController(rootViewController: $0)
      nav.navigationBar.prefersLargeTitles = true
      nav.tabBarItem = UITabBarItem(
        title: $0.section,
        image: UIImage(
          systemName: $0.section == "Library"
            ? "books.vertical" : $0.section == "Downloads" ? "arrow.down.circle" : "book"), tag: 0)
      return nav
    }
    tabBar.tintColor = .systemPink
    session.onChange = { [weak self] in
      guard let self else { return }
      if lastOwner != session.account?.ownerId {
        viewControllers?.compactMap { $0 as? UINavigationController }.forEach {
          $0.popToRootViewController(animated: false)
        }
        libraries.forEach {
          $0.search.searchBar.text = ""
          $0.category = "All Comics"
        }
        lastOwner = session.account?.ownerId
      }
      self.libraries.forEach { $0.reload() }
      self.updateAccessory()
    }
    smb.progress = { [weak self] text in
      guard let self else { return }
      self.session.status = text
      self.libraries.forEach { $0.reload() }
    }
    updateAccessory()
  }
  func updateAccessory() {
    guard
      let state = session.states.filter({ $0.progress != nil && $0.pageIndex == nil }).sorted(by: {
        $0.updatedAt > $1.updatedAt
      }).first,
      let chapter = session.visibleEntities(kind: .chapter).first(where: { $0.id == state.entityId }
      )
    else {
      bottomAccessory = nil
      return
    }
    let button = UIButton(type: .system)
    var config = UIButton.Configuration.plain()
    config.title = chapter.title(in: AppConfiguration.preferredLanguage)
    config.subtitle = "Continue reading"
    config.image = UIImage(systemName: "book.fill")
    config.imagePadding = 12
    button.configuration = config
    button.addAction(
      UIAction { [weak self] _ in self?.libraries.first?.open(chapter) }, for: .touchUpInside)
    bottomAccessory = UITabAccessory(contentView: button)
  }
}
final class ComicCell: UICollectionViewCell {
  static let identifier = "Comic"
  let cover = UIImageView()
  let label = UILabel()
  let secondary = UILabel()
  let download = UIButton(type: .system)
  var downloadAction: (() -> Void)?
  var entityId: String?
  override init(frame: CGRect) {
    super.init(frame: frame)
    cover.contentMode = .scaleAspectFill
    cover.clipsToBounds = true
    cover.layer.cornerRadius = 8
    cover.backgroundColor = .secondarySystemBackground
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.numberOfLines = 2
    secondary.font = .preferredFont(forTextStyle: .caption1)
    secondary.textColor = .secondaryLabel
    download.setImage(UIImage(systemName: "arrow.down.circle.fill"), for: .normal)
    download.tintColor = .white
    download.accessibilityLabel = "Download for offline reading"
    download.addAction(UIAction { [weak self] _ in self?.downloadAction?() }, for: .touchUpInside)
    for v in [cover, label, secondary, download] {
      contentView.addSubview(v)
      v.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      cover.topAnchor.constraint(equalTo: contentView.topAnchor),
      cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: 1.4),
      label.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 7),
      label.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
      secondary.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
      secondary.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
      download.topAnchor.constraint(equalTo: cover.topAnchor, constant: 4),
      download.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -4),
      download.widthAnchor.constraint(equalToConstant: 44),
      download.heightAnchor.constraint(equalToConstant: 44),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
  func configure(_ entity: LibraryEntity, session: AppSession, smb: SMBMedia) {
    entityId = entity.id
    label.text = entity.title(in: AppConfiguration.preferredLanguage)
    secondary.text = entity.kind.rawValue.capitalized
    cover.image = UIImage(systemName: "book.closed")
    cover.contentMode = .scaleAspectFit
    let chapter = entity.kind == .chapter ? entity : smb.chapters(for: entity).first
    if let v = chapter?.preferredMedia(AppConfiguration.preferredLanguage),
      let urls = smb.downloadedURLs(v), let first = urls.first,
      let image = UIImage(contentsOfFile: first.path)
    {
      cover.image = image
      cover.contentMode = .scaleAspectFill
    }
  }
}
final class PhoneLibraryController: UIViewController, UICollectionViewDataSource,
  UICollectionViewDelegate, UISearchResultsUpdating
{
  let session: AppSession
  let smb: SMBMedia
  let section: String
  var parentEntity: LibraryEntity?
  var category = "All Comics"
  var items: [LibraryEntity] = []
  var collection: UICollectionView!
  let search = UISearchController(searchResultsController: nil)
  init(session: AppSession, smb: SMBMedia, section: String, parentEntity: LibraryEntity? = nil) {
    self.session = session
    self.smb = smb
    self.section = section
    self.parentEntity = parentEntity
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = parentEntity?.title(in: AppConfiguration.preferredLanguage) ?? section
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = "Search your library"
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = false
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis"), menu: menu())
    let item = NSCollectionLayoutItem(
      layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
    item.contentInsets = .init(top: 0, leading: 8, bottom: 16, trailing: 8)
    let group = NSCollectionLayoutGroup.horizontal(
      layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(320)),
      repeatingSubitem: item, count: 2)
    let section = NSCollectionLayoutSection(group: group)
    section.contentInsets = .init(top: 12, leading: 8, bottom: 12, trailing: 8)
    collection = UICollectionView(
      frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
    collection.backgroundColor = .systemBackground
    collection.register(ComicCell.self, forCellWithReuseIdentifier: ComicCell.identifier)
    collection.dataSource = self
    collection.delegate = self
    view.addSubview(collection)
    collection.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      collection.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    setContentScrollView(collection)
    let refresh = UIRefreshControl()
    refresh.addAction(
      UIAction { [weak self] _ in
        Task {
          try? await self?.session.synchronize()
          refresh.endRefreshing()
        }
      }, for: .valueChanged)
    collection.refreshControl = refresh
    reload()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reload()
  }
  func menu() -> UIMenu {
    var actions = [
      UIAction(
        title: session.account == nil ? "Sign in" : "Sign out",
        image: UIImage(systemName: "person.crop.circle")
      ) { [weak self] _ in
        guard let self else { return }
        if self.session.account == nil { self.session.login() } else { self.session.signOut() }
      },
      UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
        guard let self else { return }
        self.navigationController?.pushViewController(
          PhoneSettingsController(session: self.session, smb: self.smb), animated: true)
      },
    ]
    if parentEntity == nil && section == "Library" {
      for name in ["All Comics", "Authors", "Series", "Tags", "Favorites", "Starred", "History"] {
        actions.append(
          UIAction(title: name) { [weak self] _ in
            self?.category = name
            self?.title = name
            self?.reload()
          })
      }
    }
    return UIMenu(children: actions)
  }
  func reload() {
    guard isViewLoaded else { return }
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis"), menu: menu())
    guard session.account != nil else {
      items = []
      collection.reloadData()
      var empty = UIContentUnavailableConfiguration.empty()
      empty.image = UIImage(systemName: "books.vertical")
      empty.text = "Your manga, on every device"
      empty.secondaryText = session.status
      empty.button.title = "Sign in with Thristram"
      empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.session.login() }
      contentUnavailableConfiguration = empty
      return
    }
    if let parentEntity {
      items = smb.chapters(for: parentEntity)
    } else if section == "Downloads" {
      items = session.visibleEntities(kind: .chapter).filter {
        $0.media.contains { smb.downloadedURLs($0) != nil }
      }
    } else if section == "Continue Reading" || category == "History" {
      let ids = Set(session.states.filter { $0.progress != nil }.map(\.entityId))
      items = session.visibleEntities(kind: .chapter).filter { ids.contains($0.id) }
    } else {
      switch category {
      case "Authors": items = session.visibleEntities(kind: .author)
      case "Series": items = session.visibleEntities(kind: .series)
      case "Tags": items = session.visibleEntities(kind: .tag)
      case "Favorites", "Starred":
        let ids = Set(
          session.states.filter { category == "Favorites" ? $0.favorite : $0.starred }.map(
            \.entityId))
        items = session.visibleEntities().filter { ids.contains($0.id) }
      default:
        items = session.visibleEntities().filter {
          $0.kind == .work || ($0.kind == .chapter && $0.workId == nil)
        }
      }
    }
    if let query = search.searchBar.text, !query.isEmpty {
      items = items.filter {
        $0.title(in: AppConfiguration.preferredLanguage).localizedCaseInsensitiveContains(query)
      }
    }
    collection.reloadData()
    if items.isEmpty {
      var empty = UIContentUnavailableConfiguration.empty()
      empty.text = "No comics yet"
      empty.secondaryText =
        section == "Downloads"
        ? "Download comics from your SMB library for offline reading."
        : "Import your collection from the Mac app."
      contentUnavailableConfiguration = empty
    } else {
      contentUnavailableConfiguration = nil
    }
  }
  func updateSearchResults(for searchController: UISearchController) { reload() }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  { items.count }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    let cell =
      collectionView.dequeueReusableCell(withReuseIdentifier: ComicCell.identifier, for: indexPath)
      as! ComicCell
    let entity = items[indexPath.item]
    cell.configure(entity, session: session, smb: smb)
    cell.downloadAction = { [weak self] in self?.download(entity) }
    return cell
  }
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    open(items[indexPath.item])
  }
  func open(_ entity: LibraryEntity) {
    if entity.kind != .chapter {
      let vc = PhoneLibraryController(
        session: session, smb: smb, section: "Chapters", parentEntity: entity)
      navigationController?.pushViewController(vc, animated: true)
      return
    }
    guard let media = entity.preferredMedia(AppConfiguration.preferredLanguage) else { return }
    Task {
      do {
        let urls = try await smb.download(media)
        guard session.account != nil else { return }
        let reader = PhoneReaderController(
          chapter: entity, media: media, urls: urls, session: session, smb: smb)
        reader.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(reader, animated: true)
      } catch { show(error) }
    }
  }
  func download(_ entity: LibraryEntity) {
    Task {
      do {
        try await smb.download(entity)
        reload()
      } catch { show(error) }
    }
  }
  func show(_ error: Error) {
    let alert = UIAlertController(
      title: "MangaReader", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
