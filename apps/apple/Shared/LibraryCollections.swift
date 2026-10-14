import Charts
import MangaCore
import QuickLookThumbnailing
import SwiftUI

struct FileThumbnail: View {
  var url: URL?
  var symbol = "book.closed"
  @State private var image: CGImage?
  var body: some View {
    ZStack {
      Rectangle().fill(.quaternary)
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
      } else {
        Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
      }
    }
    .clipped()
    .task(id: url) {
      image = nil
      guard let url else { return }
      let request = QLThumbnailGenerator.Request(
        fileAt: url, size: CGSize(width: 500, height: 700), scale: 2,
        representationTypes: .thumbnail)
      if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
        for: request), !Task.isCancelled
      {
        image = result.cgImage
      }
    }
  }
}
struct MangaCover: View {
  let entity: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    FileThumbnail(
      url: library.coverURL(entity), symbol: entity.kind == .series ? "square.stack" : "book.closed"
    )
    .accessibilityLabel("Cover of " + library.title(entity))
  }
}
struct ComicTile: View {
  let entity: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .topTrailing) {
        openControl {
          MangaCover(entity: entity).aspectRatio(0.72, contentMode: .fit).clipShape(
            RoundedRectangle(cornerRadius: 10))
        }
        Button {
          library.download(entity)
        } label: {
          Image(systemName: isDownloaded ? "checkmark" : "arrow.down").frame(width: 28, height: 28)
        }.buttonStyle(.glass).clipShape(Circle()).padding(8)
          .help("Download for offline reading").accessibilityLabel(
            "Download " + library.title(entity))
      }
      HStack(alignment: .top, spacing: 4) {
        openControl {
          Text(library.title(entity)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        if library.canManage {
          Button("Edit", systemImage: "pencil") { library.edit(entity) }.labelStyle(.iconOnly)
            .buttonStyle(.plain).foregroundStyle(.secondary).frame(
              width: 22, height: 18, alignment: .topTrailing
            )
            .help("Edit " + library.title(entity)).accessibilityLabel(
              "Edit " + library.title(entity))
        }
      }
      Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      if let progress = library.state(entity.id)?.progress {
        let total = entity.media.first { $0.id == progress.mediaId }?.pageCount ?? 1
        ProgressView(
          value: progress.completed ? 1 : Double(progress.pageIndex + 1) / Double(max(1, total))
        ).tint(.pink)
        Text(progress.completed ? "Read" : "Page \(progress.pageIndex + 1) of \(total)").font(
          .caption2
        ).foregroundStyle(.secondary)
      }
    }
    .contextMenu {
      Button("Download", systemImage: "arrow.down", action: { library.download(entity) })
      if isDownloaded {
        Button("Remove Download", role: .destructive) { library.removeDownload(entity) }
      }
      Button("Favorite", systemImage: "heart", action: { library.mark(entity, starred: false) })
      Button("Star", systemImage: "star", action: { library.mark(entity, starred: true) })
      if library.canManage {
        Button("Edit", systemImage: "pencil", action: { library.edit(entity) })
      }
    }
    .accessibilityElement(children: .contain)
  }
  @ViewBuilder private func openControl<Content: View>(@ViewBuilder _ content: () -> Content)
    -> some View
  {
    if entity.kind == .chapter {
      Button {
        library.open(entity)
      } label: {
        content()
      }.buttonStyle(.plain)
    } else {
      NavigationLink(value: LibraryRoute.entity(entity.id)) { content() }.buttonStyle(.plain)
    }
  }
  private var isDownloaded: Bool { entity.media.contains { library.smb.downloadedURLs($0) != nil } }
  private var subtitle: String {
    if entity.kind == .chapter {
      let media = entity.preferredMedia(AppConfiguration.preferredLanguage)
      let count = max(
        media?.pageAlignment?.count ?? media?.pageCount ?? 0, entity.media.first?.pageCount ?? 0)
      return (entity.media.first?.kind == "video" ? "Video" : "\(count) pages")
        + (library.entity(entity.authorId).map { " · " + library.title($0) } ?? "")
    }
    return (library.entity(entity.authorId).map(library.title) ?? "other author")
      + " · \(library.chapters(entity).count) chapters"
  }
}
struct ComicGrid: View {
  let entities: [LibraryEntity]
  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
      ForEach(entities) { ComicTile(entity: $0) }
    }
  }
  private var columns: [GridItem] {
    #if os(macOS)
      [GridItem(.adaptive(minimum: 155, maximum: 215), spacing: 24, alignment: .top)]
    #else
      [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top),
      ]
    #endif
  }
}
struct CollectionFilters: View {
  let page: LibraryPage
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("\(library.collection(page).count) items").font(.callout).foregroundStyle(.secondary)
        Spacer()
        Menu {
          Picker("Sort by", selection: $library.sort) {
            ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          Toggle("Unread only", isOn: $library.unreadOnly)
        } label: {
          Label(library.sort.rawValue, systemImage: "line.3.horizontal.decrease")
        }.menuStyle(.borderlessButton)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          Button("All") {
            library.selectedTag = nil
            library.unreadOnly = false
          }.buttonStyle(.bordered).tint(
            library.selectedTag == nil && !library.unreadOnly ? .pink : .secondary)
          Button("Unread") { library.unreadOnly.toggle() }.buttonStyle(.bordered).tint(
            library.unreadOnly ? .pink : .secondary)
          ForEach(session.visibleEntities(kind: .tag)) { tag in
            Button(library.title(tag)) {
              library.selectedTag = library.selectedTag == tag.id ? nil : tag.id
            }
            .buttonStyle(.bordered).tint(library.selectedTag == tag.id ? .pink : .secondary)
          }
        }.controlSize(.small)
      }
    }
  }
}
struct ComicCollectionScreen: View {
  let page: LibraryPage
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        CollectionFilters(page: page)
        if library.collection(page).isEmpty {
          LibraryEmptyState(page: page).frame(maxWidth: .infinity).padding(.top, 55)
        } else {
          ComicGrid(entities: library.collection(page))
        }
      }.padding(contentPadding)
    }
    .refreshable { try? await session.synchronize() }
    .overlay(alignment: .bottom) {
      if library.opening {
        Label {
          ProgressView().controlSize(.small)
          Text("Opening chapter…")
        } icon: {
          Image(systemName: "book")
        }.padding(14).glassEffect().padding()
      }
    }
  }
}
var contentPadding: CGFloat {
  #if os(macOS)
    28
  #else
    18
  #endif
}
struct LibraryEmptyState: View {
  let page: LibraryPage
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: page.symbol)
    } description: {
      Text(description)
    } actions: {
      if library.canManage && [.library, .search].contains(page) {
        Button("Import Comics", systemImage: "folder.badge.plus") { library.selection = .importing }
          .buttonStyle(.borderedProminent)
      }
      if !library.query.isEmpty { Button("Clear Search") { library.query = "" } }
    }
  }
  private var title: String {
    if !library.query.isEmpty { return "No matching comics" }
    switch page {
    case .continuing: return "Ready for your next chapter"
    case .favorites: return "Your favorites live here"
    case .starred: return "Keep the best stories close"
    case .history: return "Your reading history"
    default: return "Your library starts here"
    }
  }
  private var description: String {
    switch page {
    case .continuing: return "Start a chapter and pick up where you left off on any device."
    case .favorites: return "Tap the heart on a comic or page to save it."
    case .starred: return "Star a comic, chapter or page to find it here."
    case .history: return "Chapters you read appear here automatically."
    default:
      return library.canManage
        ? "Import folders, PDFs or videos to build your collection."
        : "Add comics from your Mac. Your library will sync here automatically."
    }
  }
}
struct EntityCollectionScreen: View {
  let entity: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            Text(library.title(entity)).font(.largeTitle.bold())
            if library.canManage && [.work, .series].contains(entity.kind) {
              TranslateButton(entity: entity, field: "title")
            }
          }
          if let author = library.entity(entity.authorId) {
            Text(library.title(author)).foregroundStyle(.secondary)
          }
          HStack(spacing: 14) {
            if let chapter = library.chapters(entity).first {
              Button("Read", systemImage: "book") { library.open(chapter) }.buttonStyle(
                .borderedProminent)
            }
            if entity.kind != .tag {
              Button("Download All", systemImage: "arrow.down") { library.download(entity) }
                .buttonStyle(.bordered)
            }
            if [.work, .series, .chapter].contains(entity.kind) {
              Button(
                "Favorite",
                systemImage: library.state(entity.id)?.favorite == true ? "heart.fill" : "heart"
              ) { library.mark(entity, starred: false) }.labelStyle(.iconOnly).buttonStyle(
                .borderless)
              Button(
                "Star",
                systemImage: library.state(entity.id)?.starred == true ? "star.fill" : "star"
              ) { library.mark(entity, starred: true) }.labelStyle(.iconOnly).buttonStyle(
                .borderless)
            }
            if library.canManage {
              Button("Edit", systemImage: "pencil") { library.edit(entity) }.labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
          }.controlSize(.regular)
          if !entity.description(in: AppConfiguration.preferredLanguage).isEmpty {
            HStack(alignment: .top) {
              Text(entity.description(in: AppConfiguration.preferredLanguage)).foregroundStyle(
                .secondary
              ).textSelection(.enabled)
              if library.canManage && [.work, .series].contains(entity.kind) {
                TranslateButton(entity: entity, field: "description")
              }
            }
          }
          SourceLinksView(links: entity.sources, author: entity.kind == .author)
        }
        Divider()
        let children = library.filtered(library.children(entity))
        HStack {
          Text(entity.kind == .work ? "Chapters" : "Collection").font(.title2.bold())
          Spacer()
          Text("\(children.count) items").foregroundStyle(.secondary)
        }
        if children.isEmpty {
          ContentUnavailableView(
            "No chapters yet", systemImage: "book.closed",
            description: Text("Add chapters from Import & Identify on your Mac."))
        } else {
          ComicGrid(entities: children)
        }
      }.padding(contentPadding)
    }.navigationTitle(library.title(entity))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
  }
}
struct AuthorsScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(library.collection(.authors)) { author in
          HStack(spacing: 16) {
            NavigationLink(value: LibraryRoute.entity(author.id)) {
              HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 45))
                  .foregroundStyle(.pink.opacity(0.8))
                VStack(alignment: .leading, spacing: 5) {
                  Text(library.title(author)).font(.headline).foregroundStyle(.primary)
                  Text("\(library.chapters(author).count) chapters").font(.caption).foregroundStyle(
                    .secondary)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            ForEach(Array(library.authorPreviews(author).prefix(3))) { work in
              NavigationLink(value: LibraryRoute.entity(work.id)) {
                MangaCover(entity: work).frame(width: 48, height: 68).clipShape(
                  RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.plain)
            }
            if library.canManage {
              Button("Edit Author", systemImage: "pencil") { library.edit(author) }.labelStyle(
                .iconOnly
              ).buttonStyle(.borderless)
            }
          }.padding(.vertical, 18)
          Divider()
        }
        if library.collection(.authors).isEmpty {
          ContentUnavailableView(
            "No authors yet", systemImage: "person.crop.circle",
            description: Text("Authors are added when you import or organize comics."))
        }
      }.padding(contentPadding)
    }.toolbar {
      if library.canManage { Button("New Author", systemImage: "plus") { library.create(.author) } }
    }
  }
}
struct TagsScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    List {
      ForEach(library.collection(.tags)) { tag in
        HStack {
          NavigationLink(value: LibraryRoute.entity(tag.id)) {
            HStack(spacing: 12) {
              Circle().fill(tag.nsfw ? .orange : .pink).frame(width: 10, height: 10)
              Text(library.title(tag))
              Spacer()
              Text("\(library.children(tag).count)").foregroundStyle(.secondary)
            }
          }
          if library.canManage {
            Button("Edit Tag", systemImage: "pencil") { library.edit(tag) }.labelStyle(.iconOnly)
              .buttonStyle(.borderless)
          }
        }.padding(.vertical, 6)
      }
      if library.collection(.tags).isEmpty {
        ContentUnavailableView(
          "No tags yet", systemImage: "tag",
          description: Text("Tags are shared across your comics, series and chapters."))
      }
    }.toolbar {
      if library.canManage { Button("New Tag", systemImage: "plus") { library.create(.tag) } }
    }
  }
}
struct SavedPagesScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    let bookmarks = session.states.filter {
      $0.pageIndex != nil && ($0.favorite || $0.starred) && library.entity($0.entityId) != nil
    }
    ScrollView {
      if bookmarks.isEmpty {
        ContentUnavailableView(
          "Save a favorite moment", systemImage: "photo.on.rectangle",
          description: Text("Favorite or star a page while reading to return to it here."))
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 20)], spacing: 24) {
          ForEach(bookmarks) { bookmark in
            if let chapter = library.entity(bookmark.entityId) {
              Button {
                library.open(chapter, page: bookmark.pageIndex)
              } label: {
                VStack(alignment: .leading, spacing: 8) {
                  let source = library.pageSource(chapter, page: bookmark.pageIndex ?? 0)
                  PagePreview(url: source.url, kind: source.kind, index: source.index).aspectRatio(
                    0.72, contentMode: .fit
                  ).clipShape(RoundedRectangle(cornerRadius: 8))
                  Text(library.title(chapter)).font(.subheadline).lineLimit(1)
                  Label(
                    "Page \((bookmark.pageIndex ?? 0) + 1)",
                    systemImage: bookmark.favorite ? "heart.fill" : "star.fill"
                  ).font(.caption).foregroundStyle(.secondary)
                }
              }.buttonStyle(.plain)
            }
          }
        }.padding(contentPadding)
      }
    }
  }
}
struct DownloadsScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(library.activities) { activity in
          HStack(spacing: 14) {
            Image(
              systemName: activity.completed
                ? "checkmark.circle"
                : activity.failed ? "exclamationmark.circle" : "arrow.down.circle"
            ).font(.title2).foregroundStyle(activity.failed ? .orange : .pink)
            VStack(alignment: .leading, spacing: 5) {
              Text(activity.title).font(.headline)
              Text(activity.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !activity.failed && !activity.completed {
              ProgressView().controlSize(.small)
              Button("Cancel", action: library.cancelDownload)
            }
            if activity.failed, let entity = library.entity(activity.id) {
              Button("Retry") { library.download(entity) }
            }
          }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        Text("Available Offline").font(.title2.bold())
        if library.collection(.downloads).isEmpty {
          ContentUnavailableView(
            "Take your comics with you", systemImage: "arrow.down.circle",
            description: Text("Use the download button on any comic, author or series."))
        } else {
          ComicGrid(entities: library.collection(.downloads))
        }
      }.padding(contentPadding)
    }
  }
}
struct StatisticsScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    let states = session.states.filter {
      $0.pageIndex == nil && $0.progress != nil && library.entity($0.entityId) != nil
    }
    let seconds = states.reduce(0) { $0 + ($1.progress?.activeSeconds ?? 0) }
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        HStack(spacing: 30) {
          statistic("Reading Time", value: "\(seconds / 60) min", icon: "clock")
          statistic(
            "Completed", value: "\(states.filter { $0.progress?.completed == true }.count)",
            icon: "checkmark.circle")
          statistic(
            "In Progress", value: "\(states.filter { $0.progress?.completed != true }.count)",
            icon: "book")
        }.frame(maxWidth: .infinity, alignment: .leading)
        Text("Recent Chapters").font(.title2.bold())
        if states.isEmpty {
          ContentUnavailableView(
            "A little reading, every day", systemImage: "chart.bar",
            description: Text("Reading time and completed chapters appear here as you read."))
        } else {
          Chart(Array(states.sorted { $0.updatedAt > $1.updatedAt }.prefix(7))) { state in
            BarMark(
              x: .value("Chapter", library.entity(state.entityId).map(library.title) ?? "Chapter"),
              y: .value("Minutes", Double(state.progress?.activeSeconds ?? 0) / 60)
            ).foregroundStyle(.pink)
          }.frame(height: 220)
        }
      }.padding(contentPadding)
    }
  }
  private func statistic(_ title: String, value: String, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: icon).font(.title2).foregroundStyle(.pink)
      Text(value).font(.title.bold())
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
  }
}
struct SourceLinksView: View {
  let links: [SourceLink]
  var author = false
  var body: some View {
    if !links.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(Array(links.enumerated()), id: \.offset) { _, link in
            if let url = sourceURL(link) {
              Link(link.site.capitalized, destination: url).font(.callout)
            }
          }
        }
      }
    }
  }
  private func sourceURL(_ link: SourceLink) -> URL? {
    if link.value.hasPrefix("https://") { return URL(string: link.value) }
    let escaped = link.value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    switch link.site {
    case "pixiv":
      return URL(string: "https://www.pixiv.net/" + (author ? "users/" : "artworks/") + escaped)
    case "fanbox":
      if author {
        guard link.value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
          return nil
        }
        return URL(string: "https://" + link.value + ".fanbox.cc")
      }
      return URL(string: "https://www.fanbox.cc/posts/" + escaped)
    case "patreon": return URL(string: "https://www.patreon.com/" + escaped)
    case "ehentai": return URL(string: "https://e-hentai.org/g/" + escaped)
    default: return nil
    }
  }
}
