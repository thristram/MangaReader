import MangaCore
import SwiftUI

struct MangaRootScreen: View {
  @ObservedObject var session: AppSession
  @StateObject var library: LibraryUIModel
  @AppStorage("ShowNSFW") private var showNSFW = false
  init(session: AppSession, library: LibraryUIModel? = nil) {
    self.session = session
    _library = StateObject(wrappedValue: library ?? LibraryUIModel(session: session))
  }
  var body: some View {
    Group {
      if session.account == nil {
        WelcomeScreen()
      } else {
        #if os(macOS)
          if let reader = library.reader {
            MangaReaderScreen(context: reader)
          } else {
            MacLibraryShell()
          }
        #else
          PhoneLibraryShell()
            .fullScreenCover(item: $library.reader) {
              MangaReaderScreen(context: $0).environmentObject(library).environmentObject(session)
            }
        #endif
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environmentObject(library).environmentObject(session).tint(.pink)
    .onChange(of: session.account?.ownerId) { _, _ in library.reset() }
    .onChange(of: showNSFW) { _, _ in library.visibilityChanged() }
    .onChange(of: session.entities.map { $0.id + ":" + String($0.revision) }) { _, _ in
      library.visibilityChanged()
    }
    .sheet(item: $library.editor) {
      MetadataEditor(request: $0).environmentObject(library).environmentObject(session)
    }
    .alert(
      "MangaReader",
      isPresented: Binding(
        get: { library.message != nil }, set: { if !$0 { library.message = nil } })
    ) {
      Button("OK", role: .cancel) { library.message = nil }
    } message: {
      Text(library.message?.text ?? "")
    }
  }
}

struct WelcomeScreen: View {
  @EnvironmentObject private var session: AppSession
  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "books.vertical.fill").font(.system(size: 72)).foregroundStyle(.pink)
        .accessibilityHidden(true)
      Text("MangaReader").font(.system(size: 36, weight: .semibold))
      Text("Your library, wherever you read.").font(.title3).foregroundStyle(.secondary)
      Button(action: session.login) {
        Text("Sign In").font(.headline).frame(width: 180).padding(.vertical, 8)
      }
      .buttonStyle(.glassProminent).disabled(session.busy).accessibilityIdentifier("sign-in")
      if session.busy { ProgressView().controlSize(.small) }
      if !["Sign in to your MangaReader library.", "Signed out"].contains(session.status) {
        Text(session.status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(
          .center
        ).frame(maxWidth: 420)
      }
    }
    .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("welcome-screen")
  }
}

#if os(macOS)
  struct MacLibraryShell: View {
    @EnvironmentObject private var library: LibraryUIModel
    @EnvironmentObject private var session: AppSession
    @State private var settingsExpanded = true
    var body: some View {
      NavigationSplitView {
        VStack(spacing: 0) {
          List(selection: $library.selection) {
            sidebarRow(.search)
            Section("Library") { ForEach(LibraryPage.libraryPages) { sidebarRow($0) } }
            Section("Activity") { ForEach(LibraryPage.activityPages) { sidebarRow($0) } }
            if library.canManage {
              Section("Manage") {
                ForEach([LibraryPage.importing, .organization, .storage]) { sidebarRow($0) }
              }
            }
            Section {
              DisclosureGroup(isExpanded: $settingsExpanded) {
                ForEach(LibraryPage.settingsPages) { sidebarRow($0) }
              } label: {
                Label("Settings", systemImage: "gearshape").font(.system(size: 15))
              }
            }
          }
          .listStyle(.sidebar).listItemTint(.monochrome)
          .background(MacSidebarSelectionAppearance())
          .navigationSplitViewColumnWidth(min: 225, ideal: 265, max: 330)
          Divider().padding(.horizontal, 12)
          Button {
            library.selection = .sync
          } label: {
            HStack(spacing: 11) {
              Image(systemName: "person.crop.circle.fill").font(.system(size: 32)).foregroundStyle(
                .secondary)
              VStack(alignment: .leading, spacing: 3) {
                Text("Thristram Account").font(.headline)
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer()
            }.padding(14)
          }.buttonStyle(.plain).accessibilityLabel("Account and sync")
        }
        .navigationSplitViewColumnWidth(min: 225, ideal: 265, max: 330)
      } detail: {
        NavigationStack(path: $library.path) {
          LibraryPageScreen(page: library.selection ?? .library)
            .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
        }
      }
      .navigationSplitViewStyle(.balanced)
      .background(
        MacNavigationGestures(back: library.navigateBack, forward: library.navigateForward)
      )
      .onChange(of: library.path) { old, new in library.navigationChanged(from: old, to: new) }
      .onChange(of: library.selection) { _, _ in
        library.path = []
        library.query = ""
        library.selectedTag = nil
      }
      .searchable(text: $library.query, placement: .toolbar, prompt: "Search your library")
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          if library.canManage {
            Button("Import", systemImage: "plus") { library.selection = .importing }
              .keyboardShortcut("o")
          }
          Button("Sync", systemImage: "arrow.triangle.2.circlepath", action: library.synchronize)
        }
      }
      .accessibilityIdentifier("mac-library-shell")
    }
    private func sidebarRow(_ page: LibraryPage) -> some View {
      Label {
        Text(page.title)
      } icon: {
        Image(systemName: page.symbol).font(.system(size: 19)).frame(width: 25)
      }
      .font(.system(size: 15)).foregroundStyle(
        library.selection == page ? Color.pink : Color.primary
      )
      .padding(.vertical, 6).tag(page)
      .listRowBackground(
        RoundedRectangle(cornerRadius: 8).fill(
          library.selection == page ? Color.primary.opacity(0.08) : Color.clear)
      )
      .accessibilityIdentifier("sidebar-" + page.rawValue)
    }
  }
#else
  struct PhoneLibraryShell: View {
    @EnvironmentObject private var library: LibraryUIModel
    @State private var tab: LibraryPage = .library
    private var tabs: some View {
      TabView(selection: $tab) {
        Tab("Library", systemImage: "books.vertical", value: .library) {
          PhonePageStack(page: .library)
        }
        Tab("Continue Reading", systemImage: "book", value: .continuing) {
          PhonePageStack(page: .continuing)
        }
        Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
          PhonePageStack(page: .downloads)
        }
      }
      .tabBarMinimizeBehavior(.onScrollDown)
    }
    @ViewBuilder var body: some View {
      if #available(iOS 26.1, *) {
        tabs.tabViewBottomAccessory(isEnabled: library.latestChapter != nil) { accessory }
      } else if library.latestChapter != nil {
        tabs.tabViewBottomAccessory { accessory }
      } else {
        tabs
      }
    }
    @ViewBuilder private var accessory: some View {
      if let chapter = library.latestChapter {
        Button {
          library.open(chapter)
        } label: {
          HStack(spacing: 12) {
            MangaCover(entity: chapter).frame(width: 32, height: 42).clipShape(
              RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading) {
              Text(library.title(chapter)).font(.subheadline).lineLimit(1)
              Text("Continue reading").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "book.fill").font(.title3)
          }.padding(.horizontal, 18).padding(.vertical, 6)
        }.buttonStyle(.plain).accessibilityLabel("Resume " + library.title(chapter))
      }
    }
  }
  struct PhonePageStack: View {
    let page: LibraryPage
    @EnvironmentObject private var library: LibraryUIModel
    @State private var path: [LibraryRoute] = []
    var body: some View {
      NavigationStack(path: $path) {
        LibraryPageScreen(page: page)
          .searchable(
            text: $library.query, placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search your library"
          )
          .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
          .toolbarTitleDisplayMode(.large)
          .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
              Menu("More", systemImage: "ellipsis") {
                ForEach([
                  LibraryPage.authors, .series, .tags, .favorites, .starred, .savedPages, .history,
                  .statistics, .settings,
                ]) { page in
                  NavigationLink(value: LibraryRoute.page(page)) {
                    Label(page == .settings ? "Settings" : page.title, systemImage: page.symbol)
                  }
                }
              }.accessibilityLabel("More library pages")
            }
          }
      }
    }
  }
#endif

struct LibraryDestination: View {
  let route: LibraryRoute
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    switch route {
    case .page(let page): LibraryPageScreen(page: page)
    case .entity(let id):
      if let entity = library.entity(id) {
        EntityCollectionScreen(entity: entity)
      } else {
        ContentUnavailableView(
          "Content unavailable", systemImage: "book.closed",
          description: Text("It may have been removed or hidden by your content settings."))
      }
    }
  }
}
struct LibraryPageScreen: View {
  let page: LibraryPage
  var body: some View {
    Group {
      #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
          Text(page.title).font(.system(size: 30, weight: .bold)).padding(.horizontal, 28).padding(
            .top, 22
          ).padding(.bottom, 6)
          content
        }
      #else
        // Keep the scrolling content directly under native navigation so the
        // large title/search drawer expands and collapses with its scroll edge.
        content
      #endif
    }
    .navigationTitle(page.title)
    #if os(iOS)
      .toolbarTitleDisplayMode(.large)
    #endif
    .accessibilityIdentifier("page-" + page.rawValue)
  }
  @ViewBuilder private var content: some View {
    Group {
      switch page {
      case .authors: AuthorsScreen()
      case .tags: TagsScreen()
      case .statistics: StatisticsScreen()
      case .savedPages: SavedPagesScreen()
      case .downloads: DownloadsScreen()
      case .settings, .reading, .translation, .connections, .sync, .files, .storage:
        LibrarySettingsScreen(page: page)
      case .importing:
        #if os(macOS)
          ImportScreen()
        #else
          ContentUnavailableView("Import on your Mac", systemImage: "desktopcomputer")
        #endif
      case .organization:
        #if os(macOS)
          OrganizationScreen()
        #else
          ContentUnavailableView("Organize on your Mac", systemImage: "desktopcomputer")
        #endif
      default: ComicCollectionScreen(page: page)
      }
    }
  }
}
