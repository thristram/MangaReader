import Charts
import MangaCore
import SwiftUI

struct FileThumbnail: View {
  var url: URL?
  var symbol = "book.closed"
  var contentMode: ContentMode = .fill
  @StateObject private var thumbnail = ThumbnailPresentation()
  var body: some View {
    Color.clear.overlay {
      GeometryReader { geometry in
        ZStack {
          if contentMode == .fill { Rectangle().fill(.quaternary) }
          if let image = thumbnail.image {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
              .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
          } else if thumbnail.loading {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(
              .tertiary)
          }
        }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
      }
    }.clipped()
      .onDisappear { thumbnail.clear() }
      .task(id: url) { await thumbnail.load(url) }
  }
}
struct MangaCover: View {
  let entity: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  @State private var url: URL?
  @State private var loading = true
  var body: some View {
    ZStack {
      FileThumbnail(url: url, symbol: entity.kind == .series ? "square.stack" : "book.closed")
      if loading { ProgressView().controlSize(.small) }
    }
    .accessibilityLabel("Cover of " + library.title(entity))
    .onDisappear {
      url = nil
      loading = false
    }
    .task(id: library.coverKey(entity)) {
      loading = true
      let result = await library.coverURL(entity)
      guard !Task.isCancelled else { return }
      url = result
      loading = false
    }
  }
}
struct ComicTile: View {
  let entity: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      openControl {
        VStack(alignment: .leading, spacing: 7) {
          MangaCover(entity: entity).aspectRatio(0.72, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
          Text(library.title(entity)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }
      .accessibilityLabel(library.title(entity))
      // The cover overlay and action row are siblings of the navigation control.
      .overlay(alignment: .topTrailing) { ComicDownloadButton(entity: entity).padding(10) }
      #if os(macOS)
        HStack(spacing: 6) {
          if library.canManage {
            Button("Edit", systemImage: "pencil") { library.edit(entity) }
              .help("Edit " + library.title(entity)).accessibilityLabel("Edit " + library.title(entity))
          }
          if entity.kind == .chapter {
            NavigationLink(value: LibraryRoute.pages(entity.id)) {
              Label("All Pages", systemImage: "square.grid.2x2")
            }.accessibilityLabel("All Pages · " + library.title(entity))
          }
          Spacer(minLength: 0)
        }.buttonStyle(.bordered).controlSize(.small).font(.caption).tint(.pink)
      #endif
      if let progress = library.state(entity.id)?.progress {
        let total = entity.media.first { $0.id == progress.mediaId }?.pageCount ?? 1
        ProgressView(value: progress.completed ? 1 : Double(progress.pageIndex + 1) / Double(max(1, total)))
          .tint(.pink)
        Text(progress.completed ? "Read" : "Page \(progress.pageIndex + 1) of \(total)")
          .font(.caption2).foregroundStyle(.secondary)
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
        if [.work, .chapter].contains(entity.kind) {
          Button(entity.kind == .chapter ? "Delete Chapter" : "Delete Comic", role: .destructive) {
            library.requestDeletion(entity)
          }.disabled(
            library.deletingComic)
        }
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
  private var isDownloaded: Bool { library.isDownloaded(entity) }
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
/// Shared native menu content for library filters and chapter collections.
struct CollectionSortOptions: View {
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    Picker("Sort by", selection: $library.sort) {
      ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    Divider()
    Picker("Order", selection: $library.sortAscending) {
      Label("Ascending", systemImage: "arrow.up").tag(true)
      Label("Descending", systemImage: "arrow.down").tag(false)
    }
  }
}
/// Shared compact filter layout, also used inside the iPhone Saved switch popover.
struct CollectionFilterPanel<Header: View>: View {
  @ViewBuilder var header: () -> Header
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header()
      Text("Filters").font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
      filterRow("All Items", symbol: "square.grid.2x2",
        selected: !library.unreadOnly && library.selectedTag == nil) {
        library.unreadOnly = false; library.selectedTag = nil
      }
      filterRow("Unread", symbol: "book.closed", selected: library.unreadOnly) {
        library.unreadOnly.toggle()
      }
      Menu {
        Picker("Tag", selection: $library.selectedTag) {
          Text("All Tags").tag(String?.none)
          ForEach(session.visibleEntities(kind: .tag)) { Text(library.title($0)).tag(Optional($0.id)) }
        }
      } label: {
        row(library.selectedTag.flatMap { library.entity($0).map(library.title) } ?? "Tags",
          symbol: "tag", selected: library.selectedTag != nil, disclosure: true)
      }.buttonStyle(.plain).accessibilityLabel("Filter by tag")
      Divider().padding(.vertical, 8)
      Menu { CollectionSortOptions() } label: {
        row(library.sort.rawValue, symbol: "arrow.up.arrow.down", selected: false, disclosure: true)
      }.buttonStyle(.plain).accessibilityLabel("Sort by " + library.sort.rawValue)
    }.padding(12).frame(width: 310)
  }
  private func filterRow(_ title: String, symbol: String, selected: Bool,
    action: @escaping () -> Void) -> some View {
    Button(action: action) { row(title, symbol: symbol, selected: selected) }
      .buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
  }
  private func row(_ title: String, symbol: String, selected: Bool, disclosure: Bool = false) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
        .opacity(selected ? 1 : 0).frame(width: 18).accessibilityHidden(true)
      Image(systemName: symbol).frame(width: 24).accessibilityHidden(true)
      Text(title).lineLimit(1)
      Spacer(minLength: 0)
      if disclosure { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
    }.frame(minHeight: 44).contentShape(Rectangle())
  }
}
#if os(macOS)
struct MacCollectionFilterButton: View {
  @State private var presented = false
  var body: some View {
    Button { presented.toggle() } label: {
      Image(systemName: "line.3.horizontal.decrease").font(.system(size: 16))
        .frame(width: 32, height: 32).contentShape(Circle())
        .glassEffect(.regular.interactive(), in: Circle())
    }.buttonStyle(.plain)
    .accessibilityLabel("Filter and Sort").accessibilityIdentifier("collection-filter")
    .help("Filter and sort your library")
    .popover(isPresented: $presented, arrowEdge: .bottom) { CollectionFilterPanel { EmptyView() } }
  }
}
#endif
struct CollectionFilters: View {
  let page: LibraryPage
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    Text("\(library.collection(page).count) items").font(.callout).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
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
          if let author = library.author(for: entity) {
            HStack(alignment: .center, spacing: 12) {
              Text(library.title(author)).foregroundStyle(.secondary)
              SourceLinksView(links: author.sources, author: true, compact: true)
            }.accessibilityIdentifier("comic-author-links")
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
              if [.work, .chapter, .author].contains(entity.kind) {
                Button(
                  entity.kind == .author
                    ? "Delete Author" : entity.kind == .chapter ? "Delete Chapter" : "Delete Comic",
                  systemImage: "trash",
                  role: .destructive
                ) {
                  library.requestDeletion(entity)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(library.deletingComic)
              }
            }
          }.controlSize(.regular)
          if !entity.description(in: AppConfiguration.preferredLanguage).isEmpty {
            HStack(alignment: .top) {
              CollectionDescription(entity: entity)
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
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) { PhoneCollectionFilterButton() }
            .sharedBackgroundVisibility(.hidden)
        }
      #endif
  }
}
struct AuthorsScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  @State private var expanded: Set<String> = []
  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(library.collection(.authors)) { author in
          HStack(spacing: 16) {
            Button {
              if expanded.contains(author.id) {
                expanded.remove(author.id)
              } else {
                expanded.insert(author.id)
              }
            } label: {
              Image(systemName: expanded.contains(author.id) ? "chevron.down" : "chevron.right")
                .frame(width: 28, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Show comics by " + library.title(author))
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
              Button("Delete Author", systemImage: "trash", role: .destructive) {
                library.requestDeletion(author)
              }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(library.deletingComic)
            }
          }.padding(.vertical, 18)
            .contextMenu {
              if library.canManage {
                Button("Edit Author", systemImage: "pencil") { library.edit(author) }
                Button("Delete Author", systemImage: "trash", role: .destructive) {
                  library.requestDeletion(author)
                }
              }
            }
          SourceLinksView(links: author.sources, author: true, compact: true)
            .padding(.leading, 44).padding(.bottom, author.sources.isEmpty ? 0 : 14)
            .accessibilityIdentifier("author-links-" + author.id)
          if expanded.contains(author.id) {
            let comics = library.authorPreviews(author)
            if comics.isEmpty {
              Text("No comics yet").foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
              ComicGrid(entities: comics).padding(.top, 8).padding(.bottom, 24)
            }
          }
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
  @EnvironmentObject private var session: AppSession
  @State private var creating = false
  @State private var newName = ""
  @State private var saving = false
  @FocusState private var newFocused: Bool
  var body: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 24)], spacing: 28
      ) {
        if creating {
          VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "tag").font(.largeTitle).frame(maxWidth: .infinity, minHeight: 120)
              .foregroundStyle(.pink)
            TextField("Tag name", text: $newName).textFieldStyle(.roundedBorder).focused(
              $newFocused
            ).contentShape(Rectangle()).onTapGesture { newFocused = true }.onSubmit(create)
            HStack {
              Button("Cancel") { creating = false }
              Spacer()
              Button("Create", action: create).disabled(
                saving || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        ForEach(library.collection(.tags)) { tag in TagCollectionTile(tag: tag) }
      }.padding(contentPadding)
      if !creating && library.collection(.tags).isEmpty {
        ContentUnavailableView(
          "No tags yet", systemImage: "tag",
          description: Text("Create a tag to organize your comics.")
        ).padding(.top, 40)
      }
    }.toolbar {
      if library.canManage {
        Button("New Tag", systemImage: "plus") {
          newName = ""
          creating = true
          Task {
            await Task.yield()
            newFocused = true
          }
        }
      }
    }
  }
  private func create() {
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !saving else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        var input = MetadataInput(kind: .tag, title: name)
        input.nsfw = name.lowercased() == "nsfw"
        _ = try await session.create(input)
        creating = false
      } catch { library.show(error) }
    }
  }
}
struct TagCollectionTile: View {
  let tag: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @State private var editing = false
  @State private var name = ""
  @State private var revision = 0
  @State private var saving = false
  @State private var deleting = false
  @FocusState private var focused: Bool
  private var comics: [LibraryEntity] { library.taggedComics(tag) }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      NavigationLink(value: LibraryRoute.entity(tag.id)) {
        ZStack {
          if comics.isEmpty {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            Image(systemName: "tag").font(.largeTitle).foregroundStyle(.pink)
          }
          ForEach(Array(comics.prefix(3).enumerated()).reversed(), id: \.element.id) {
            index, comic in
            MangaCover(entity: comic).aspectRatio(0.72, contentMode: .fit).clipShape(
              RoundedRectangle(cornerRadius: 10)
            )
            .padding(.trailing, 20).padding(.top, 16).offset(
              x: CGFloat(index) * 8, y: -CGFloat(index) * 7)
          }
        }.aspectRatio(0.78, contentMode: .fit).contentShape(Rectangle())
      }.buttonStyle(.plain)
      HStack(alignment: .center) {
        if editing {
          TextField("Tag name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            .contentShape(Rectangle()).onTapGesture { focused = true }.onSubmit(save).disabled(
              saving)
        } else {
          Text(tag.title).font(.headline).lineLimit(1)
        }
        Spacer(minLength: 4)
        if library.canManage {
          Button {
            if editing {
              deleting = true
            } else {
              name = tag.title
              revision = tag.revision
              editing = true
              Task {
                await Task.yield()
                focused = true
              }
            }
          } label: {
            Image(systemName: editing ? "trash" : "pencil")
          }
          .buttonStyle(.borderless).foregroundStyle(editing ? Color.pink : Color.secondary)
          .accessibilityLabel((editing ? "Delete tag " : "Edit tag ") + tag.title).disabled(saving)
        }
      }
      Text("\(comics.count) " + (comics.count == 1 ? "comic" : "comics")).font(.caption)
        .foregroundStyle(.secondary)
    }
    .alert("Delete tag “\(tag.title)” ?", isPresented: $deleting) {
      Button("Cancel", role: .cancel) {}
      Button("Delete Tag", role: .destructive) {
        saving = true
        Task {
          defer { saving = false }
          do { try await session.deleteTag(tag) } catch { library.show(error) }
        }
      }
    } message: {
      Text("The tag will be removed from your comics. No comics or files will be deleted.")
    }
  }
  private func save() {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !saving else { return }
    guard let current = session.entities.first(where: { $0.id == tag.id && !$0.deleted }),
      current.revision == revision
    else {
      editing = false
      library.show(
        LoginError.server("This tag changed. Review the latest name before editing again."))
      return
    }
    saving = true
    Task {
      defer { saving = false }
      do {
        var input = current.input
        input.title = title
        input.localizations = [:]
        try await session.update(current, input: input)
        editing = false
      } catch { library.show(error) }
    }
  }
}
struct SavedPagesScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  var body: some View {
    let bookmarks = library.savedPages()
    ScrollView {
      SavedPageGrid(bookmarks: bookmarks).padding(contentPadding)
    }
  }
}
struct SavedPageGrid: View {
  let bookmarks: [PersonalState]
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
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
                ChapterPagePreview(chapter: chapter, page: bookmark.pageIndex ?? 0).aspectRatio(
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
              ProgressView(value: activity.progress).frame(width: 90)
              Button("Cancel") { library.cancelDownload(activity.id) }
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
  var compact = false
  private struct Destination: Identifiable {
    let id: Int
    let link: SourceLink
    let url: URL
  }
  private var destinations: [Destination] {
    links.enumerated().compactMap { index, link in
      guard let url = link.destinationURL(author: author) else { return nil }
      return Destination(id: index, link: link, url: url)
    }
  }
  var body: some View {
    if !destinations.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: compact ? 10 : 12) {
          ForEach(destinations) { item in sourceLink(item) }
        }
      }.fixedSize(horizontal: false, vertical: true)
    }
  }
  private func sourceLink(_ item: Destination) -> some View {
    let action = "Open " + item.link.displayName + (author ? " author profile" : " source")
    let identifier = ["source-link", author ? "author" : "comic", item.link.site, String(item.id)].joined(separator: "-")
    return Link(destination: item.url) { linkLabel(item.link) }
      .buttonStyle(.borderless).help(action).accessibilityLabel(action)
      .accessibilityIdentifier(identifier)
  }
  private func linkLabel(_ link: SourceLink) -> some View {
    HStack(spacing: 4) {
      Text(link.displayName)
      if compact { Image(systemName: "arrow.up.right").font(.caption2) }
    }.font(compact ? Font.caption : Font.callout)
      #if os(iOS)
        .frame(minHeight: 44)
      #else
        .padding(.vertical, compact ? 5 : 0)
      #endif
  }
}
struct ComicDownloadButton: View {
  let entity: LibraryEntity
  @EnvironmentObject private var library: LibraryUIModel
  private var activity: DownloadActivity? { library.downloadActivity(entity.id) }
  private var running: Bool { activity.map { !$0.completed && !$0.failed } ?? false }
  private var downloaded: Bool { library.isDownloaded(entity) }
  var body: some View {
    Button {
      library.download(entity)
    } label: {
      ZStack {
        Circle().fill(.pink)
        if running {
          DownloadPie(fraction: activity?.progress ?? 0).fill(.white.opacity(0.85)).padding(5)
          Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5).padding(5)
        } else {
          Image(
            systemName: activity?.failed == true
              ? "exclamationmark" : downloaded ? "checkmark" : "arrow.down"
          )
          .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
        }
      }.frame(width: 34, height: 34).contentShape(Circle())
    }.buttonStyle(.plain).disabled(running || (downloaded && activity?.failed != true))
      .help(
        activity?.failed == true
          ? "Retry download" : running ? "Downloading" : "Download for offline reading"
      )
      .accessibilityLabel(
        (activity?.failed == true ? "Retry download " : "Download ") + library.title(entity)
      )
      .accessibilityValue(
        running
          ? "\(Int((activity?.progress ?? 0) * 100)) percent"
          : downloaded ? "Available offline" : "")
  }
}
struct DownloadPie: Shape {
  var fraction: Double
  var animatableData: Double {
    get { fraction }
    set { fraction = newValue }
  }
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    path.move(to: center)
    path.addArc(
      center: center, radius: min(rect.width, rect.height) / 2,
      startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, max(0, fraction))),
      clockwise: false)
    path.closeSubpath()
    return path
  }
}
