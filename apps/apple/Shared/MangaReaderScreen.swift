import AVKit
import MangaCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MangaReaderScreen: View {
  let context: ReadingContext
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("ReaderDescription") private var showDescription = false
  @AppStorage("ReaderDirection") private var direction = "ltr"
  @State private var version: MediaVersion
  @State private var page: Int
  @State private var controls = true
  @State private var dismissOffset: CGFloat = 0
  @State private var thumbnails = false
  @State private var overview = false
  @State private var chapterInfo = false
  @State private var fileInfo = false
  @State private var started = Date()
  @State private var activeSeconds = 0
  @State private var videoCompleted = false
  @State private var isActive = true
  @State private var pageAspect: CGFloat = 0.7
  @StateObject private var playback: ReaderVideoPlayback
  init(context: ReadingContext, playback: ReaderVideoPlayback? = nil) {
    self.context = context
    _playback = StateObject(wrappedValue: playback ?? ReaderVideoPlayback())
    _version = State(initialValue: context.version)
    _page = State(initialValue: context.page)
  }
  private var chapter: LibraryEntity { library.entity(context.chapter.id) ?? context.chapter }
  private var original: MediaVersion {
    chapter.media.first { $0.language == chapter.originalLanguage } ?? chapter.media.first
      ?? version
  }
  private var count: Int {
    max(original.pageCount, version.pageAlignment?.count ?? version.pageCount)
  }
  var body: some View {
    // Measure control insets before expanding the media canvas under system bars.
    GeometryReader { safeGeometry in
      GeometryReader { geometry in
        let descriptionOnRight =
          geometry.size.width >= 950
          && pageAspect * geometry.size.height + 235 + (thumbnails ? 110 : 0) <= geometry.size.width
        HStack(spacing: 0) {
          if thumbnails {
            ScrollView {
              LazyVStack(spacing: 14) {
                ForEach(0..<count, id: \.self) { index in
                  Button {
                    page = index
                  } label: {
                    ChapterPagePreview(chapter: chapter, preferred: version, page: index).frame(
                      width: 82, height: 112
                    ).overlay(
                      RoundedRectangle(cornerRadius: 5).stroke(
                        index == page ? Color.pink : .clear, lineWidth: 3))
                  }.buttonStyle(.plain)
                  Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                }
              }.padding(.vertical, 70).padding(.horizontal, 10)
            }.frame(width: 110).background(.black.opacity(0.8))
          }
          VStack(spacing: 0) {
            ZStack {
              Color.black
              #if os(iOS)
                PhoneReaderPager(
                  index: $page, count: count, rightToLeft: direction == "rtl",
                  contentID: "\(version.id):\(chapter.revision)",
                  onTap: { withAnimation { controls.toggle() } },
                  onDismiss: { library.reader = nil },
                  onDismissDrag: { value in
                    if value == 0 { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dismissOffset = 0 } }
                    else { dismissOffset = value }
                  }
                ) { index in
                  AnyView(
                    canvas(index).frame(maxWidth: .infinity, maxHeight: .infinity)
                      .background(.black).foregroundStyle(.white)
                      .environmentObject(library).environmentObject(session).environmentObject(playback))
                }
              #else
                MacReaderPager(index: $page, count: count, rightToLeft: direction == "rtl",
                  onTogglePlayback: version.kind == "video" ? { playback.toggle() } : nil) {
                  index in
                  AnyView(
                    canvas(index).frame(maxWidth: .infinity, maxHeight: .infinity).background(
                      .black
                    )
                    .foregroundStyle(.white).environmentObject(playback))
                }
              #endif
            }
            .clipped().contentShape(Rectangle())
            #if os(macOS)
              .onTapGesture { withAnimation { controls.toggle() } }
            #endif
            .overlay(alignment: .top) {
              if controls { topControls.padding(16).padding(.top, safeGeometry.safeAreaInsets.top) }
            }
            .overlay(alignment: .bottom) {
              if controls {
                bottomControls.padding(16).padding(.bottom, safeGeometry.safeAreaInsets.bottom)
              }
            }
            if descriptionPaneVisible && !descriptionOnRight {
              descriptionPane.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  .regularMaterial)
            }
          }
          if descriptionPaneVisible && descriptionOnRight {
            descriptionPane.padding(24).frame(width: 235, alignment: .topLeading).frame(
              maxHeight: .infinity, alignment: .top
            ).background(.regularMaterial)
          }
        }
      }.ignoresSafeArea()
    }
    .background(.black).foregroundStyle(.white)
    #if os(iOS)
      .offset(y: dismissOffset)
      .scaleEffect(1 - min(0.12, dismissOffset / 2500))
      .statusBarHidden(!controls)
      .persistentSystemOverlays(controls ? .automatic : .hidden)
    #endif
    #if os(macOS)
      .toolbar(.hidden, for: .windowToolbar)
    #endif
    .sheet(isPresented: $overview) {
      ChapterOverviewScreen(
        chapter: chapter, editing: false, preferred: version, onSelect: { page = $0 }
      )
      .environmentObject(library).environmentObject(session)
    }
    .sheet(isPresented: $fileInfo) {
      if let source = library.pageMedia(chapter, preferred: version, page: page) {
        ReaderFileInfo(media: source.media, page: source.index).environmentObject(library)
      }
    }
    .popover(isPresented: $chapterInfo, arrowEdge: .top) {
      ScrollView { descriptionPane.padding(20) }
        .frame(width: 300, height: 240).presentationCompactAdaptation(.popover)
    }
    .onAppear {
      activeSeconds = library.state(chapter.id)?.progress?.activeSeconds ?? 0
      started = Date()
      isActive = scenePhase == .active
    }
    .onChange(of: page) { _, _ in recordProgress() }
    .onChange(of: chapter.revision) { _, _ in
      guard let fallback = chapter.preferredMedia(AppConfiguration.preferredLanguage) else {
        library.reader = nil
        return
      }
      version = chapter.media.first(where: { $0.id == version.id }) ?? fallback
      page = min(page, max(0, count - 1))
    }
    .onChange(of: scenePhase) { old, new in
      if old == .active {
        accumulateTime()
        isActive = false
        recordProgress()
      }
      if new == .active {
        started = Date()
        isActive = true
      }
    }
    .onDisappear {
      accumulateTime()
      recordProgress()
      playback.reset()
    }
    .accessibilityIdentifier("manga-reader")
  }
  @ViewBuilder private var topControls: some View {
    #if os(iOS)
      phoneTopControls
    #else
      desktopTopControls
    #endif
  }
  @ViewBuilder private var bottomControls: some View {
    #if os(iOS)
      phoneBottomControls
    #else
      desktopBottomControls
    #endif
  }
  #if os(iOS)
    private var phoneTopControls: some View {
      HStack(spacing: 12) {
        Button {
          library.reader = nil
        } label: {
          Image(systemName: "chevron.left").font(.title3.weight(.medium)).frame(
            width: 44, height: 44
          )
          .glassEffect(.regular.interactive(), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("Close Reader")
          .accessibilityIdentifier("reader-back")
        Button {
          overview = true
        } label: {
          VStack(spacing: 2) {
            Text(library.title(chapter)).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(readerSubtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          }.padding(.horizontal, 14).frame(maxWidth: .infinity).frame(height: 44)
            .contentShape(Capsule()).glassEffect(.regular.interactive(), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("All Pages")
          .accessibilityValue(library.title(chapter) + ", " + readerSubtitle)
          .accessibilityIdentifier("reader-all-pages")
        Menu {
          Button("Info", systemImage: "info.circle") { fileInfo = true }
          Button("Chapter Description", systemImage: "text.alignleft") { chapterInfo = true }
        } label: {
          Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
        }.buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Reader Options")
          .accessibilityIdentifier("reader-options")
      }
    }
    private var readerSubtitle: String {
      library.entity(chapter.workId).map(library.title)
        ?? library.entity(chapter.authorId).map(library.title) ?? "other author"
    }
    private var phoneBottomControls: some View {
      VStack(spacing: 10) {
        if version.kind == "video" { ReaderVideoControls(playback: playback) }
        phonePageControls
      }
    }
    private var phonePageControls: some View {
      HStack(spacing: 8) {
        Menu {
          Picker(
            "Media Language",
            selection: Binding(
              get: { version.id },
              set: { id in
                if let media = chapter.media.first(where: { $0.id == id }) { switchVersion(media) }
              }
            )
          ) {
            ForEach(chapter.media) { media in Text(media.languageLabel).tag(media.id) }
          }.pickerStyle(.inline)
        } label: {
          Image(systemName: "globe").font(.title3).frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
        }.buttonStyle(.plain).menuIndicator(.hidden)
          .accessibilityLabel("Change page language").accessibilityValue(version.languageLabel)
          .accessibilityIdentifier("reader-language")
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 0) {
          Button {
            advance(-1)
          } label: {
            Image(systemName: direction == "rtl" ? "chevron.right" : "chevron.left")
              .frame(width: 36, height: 44)
          }.disabled(page == 0).accessibilityLabel("Previous Page")
          Text("\(page + 1) / \(count)").font(.subheadline.monospacedDigit())
            .frame(minWidth: 56).accessibilityIdentifier("reader-page-number")
          Button {
            advance(1)
          } label: {
            Image(systemName: direction == "rtl" ? "chevron.left" : "chevron.right")
              .frame(width: 36, height: 44)
          }.disabled(page + 1 >= count).accessibilityLabel("Next Page")
        }.buttonStyle(.plain).padding(.horizontal, 4).glassEffect(in: Capsule())
        ReaderPageStarButton(chapter: chapter, page: page)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  #endif
  #if os(macOS)
  private func readerIcon(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.title3.weight(.medium)).frame(width: 44, height: 44)
      .contentShape(Circle()).glassEffect(.regular.tint(.black.opacity(0.4)).interactive(), in: Circle())
  }
  private var desktopTopControls: some View {
    HStack(spacing: 12) {
      Button { library.reader = nil } label: { readerIcon("chevron.left") }
        .buttonStyle(.plain).accessibilityLabel("Close Reader")
        .accessibilityIdentifier("reader-back")
      Button { thumbnails.toggle() } label: { readerIcon("sidebar.left") }
        .buttonStyle(.plain).accessibilityLabel("Thumbnail Sidebar")
        .accessibilityValue(thumbnails ? "Shown" : "Hidden")
      Spacer()
      Menu {
        Picker("Media Language", selection: Binding(get: { version.id }, set: { id in
          if let media = chapter.media.first(where: { $0.id == id }) { switchVersion(media) }
        })) {
          ForEach(chapter.media) { media in Text(media.languageLabel).tag(media.id) }
        }.pickerStyle(.inline)
      } label: { readerIcon("globe") }
        .menuIndicator(.hidden).buttonStyle(.plain).accessibilityLabel("Change page language")
        .accessibilityValue(version.languageLabel).accessibilityIdentifier("reader-language")
      Button { overview = true } label: { readerIcon("square.grid.3x3") }
        .buttonStyle(.plain).accessibilityLabel("All Pages")
        .accessibilityIdentifier("reader-all-pages")
      Menu {
        Button("Info", systemImage: "info.circle") { fileInfo = true }
        Toggle("Chapter Description", isOn: $showDescription)
        if library.canManage {
          Divider()
          Button("Delete Chapter", systemImage: "trash", role: .destructive) {
            library.requestDeletion(chapter)
          }
        }
      } label: { readerIcon("ellipsis") }
        .menuIndicator(.hidden).buttonStyle(.plain).accessibilityLabel("Reader Options")
    }
  }
  private var desktopBottomControls: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 10) {
        if version.kind == "video" { ReaderVideoControls(playback: playback) }
        desktopPageControls
      }.padding(.horizontal, 56)
      HStack {
        Spacer()
        Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
          readerIcon("arrow.up.left.and.arrow.down.right")
        }.buttonStyle(.plain).accessibilityLabel("Full Screen")
          .accessibilityIdentifier("reader-full-screen")
      }
    }.frame(maxWidth: .infinity)
  }
  private var desktopPageControls: some View {
    HStack(spacing: 18) {
      Button("Previous Page", systemImage: direction == "rtl" ? "chevron.right" : "chevron.left") {
        advance(-1)
      }.labelStyle(.iconOnly)
        .disabled(page == 0)
      Text("\(page + 1) / \(count)").font(.subheadline.monospacedDigit()).frame(minWidth: 70)
      Button("Next Page", systemImage: direction == "rtl" ? "chevron.left" : "chevron.right") {
        advance(1)
      }.labelStyle(.iconOnly)
        .disabled(page + 1 >= count)
      Divider().frame(height: 18)
      Button(
        "Favorite Page",
        systemImage: library.state(chapter.id, page: page)?.favorite == true
          ? "heart.fill" : "heart"
      ) { library.mark(chapter, starred: false, page: page) }.labelStyle(.iconOnly)
      Button(
        "Star Page",
        systemImage: library.state(chapter.id, page: page)?.starred == true ? "star.fill" : "star"
      ) { library.mark(chapter, starred: true, page: page) }.labelStyle(.iconOnly)
    }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 13).glassEffect(in: Capsule())
  }
  #endif
  private var descriptionPaneVisible: Bool {
    #if os(iOS)
      false
    #else
      showDescription
    #endif
  }
  private var descriptionPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(library.title(chapter)).font(.headline)
      Text(chapter.description(in: AppConfiguration.preferredLanguage)).font(.callout)
        .foregroundStyle(.secondary)
      SourceLinksView(links: chapter.sources)
    }
  }
  @ViewBuilder private func canvas(_ canonical: Int) -> some View {
    if let source = library.pageMedia(chapter, preferred: version, page: canonical) {
      ReadingMediaPage(
        media: source.media, index: source.index,
        enabled: shouldLoadPage(canonical),
        isCurrent: canonical == page,
        onAspect: { value in
          if canonical == page { pageAspect = CGFloat(value) }
        },
        onComplete: {
          videoCompleted = true
          recordProgress()
        })
    } else {
      ContentUnavailableView(
        "Page unavailable", systemImage: "photo",
        description: Text("This language has no matching page."))
    }
  }
  private func shouldLoadPage(_ index: Int) -> Bool {
    #if os(iOS)
      // UICollectionView creates only visible/prefetched cells. Start those
      // loads during a fast swipe instead of waiting for the settled page index.
      return true
    #else
      return abs(index - page) <= 1
    #endif
  }
  private func advance(_ delta: Int) { page = min(max(0, page + delta), max(0, count - 1)) }
  private func switchVersion(_ media: MediaVersion) {
    guard media.id != version.id else { return }
    version = media
    page = min(page, max(0, count - 1))
  }
  private func accumulateTime() {
    if isActive { activeSeconds += max(0, Int(Date().timeIntervalSince(started))) }
    started = Date()
  }
  private func recordProgress() {
    guard session.account != nil, library.entity(chapter.id) != nil, !chapter.media.isEmpty else { return }
    let old = library.stateInput(chapter.id)
    library.writeState(
      .init(
        entityId: chapter.id, favorite: old?.favorite ?? false, starred: old?.starred ?? false,
        progress: .init(
          mediaId: page < original.pageCount ? original.id : version.id, pageIndex: page,
          completed: (old?.progress?.completed ?? false)
            || (version.kind == "video" ? videoCompleted : page == count - 1),
          activeSeconds: activeSeconds
            + (isActive ? max(0, Int(Date().timeIntervalSince(started))) : 0))))
  }
}

struct ReaderPageStarButton: View {
  let chapter: LibraryEntity
  let page: Int
  @EnvironmentObject private var library: LibraryUIModel
  private var starred: Bool { library.stateInput(chapter.id, page: page)?.starred == true }
  var body: some View {
    Button {
      library.mark(chapter, starred: true, page: page)
    } label: {
      Image(systemName: starred ? "star.fill" : "star").font(.title3)
        .foregroundStyle(starred ? Color.yellow : Color.white).frame(width: 44, height: 44)
        .glassEffect(.regular.interactive(), in: Circle())
    }.buttonStyle(.plain).accessibilityLabel(starred ? "Unstar Page" : "Star Page")
      .accessibilityValue(starred ? "Starred" : "Not starred")
      .accessibilityIdentifier("reader-star")
      .contextMenu {
        Button("Favorite Page", systemImage: "heart") {
          library.mark(chapter, starred: false, page: page)
        }
      }
  }
}

struct ReadingMediaPage: View {
  let media: MediaVersion
  let index: Int
  var enabled = true
  var isCurrent = true
  var onAspect: (Double) -> Void = { _ in }
  var onComplete: (() -> Void)?
  @EnvironmentObject private var library: LibraryUIModel
  @State private var url: URL?
  @State private var error = ""
  @State private var retry = 0
  @State private var loadedRequest: String?
  private var requestID: String {
    "\(media.id):\(media.storageRootId):\(media.relativePaths):\(index):\(enabled):\(retry)"
  }
  var body: some View {
    Group {
      if let url {
        if media.kind == "video" {
          ReaderVideoPage(url: url, isCurrent: isCurrent, onComplete: onComplete)
        } else {
          NativeReadingPage(
            url: url, pdfPage: media.kind == "pdf" ? index : nil, onSwipe: { _ in },
            isCurrent: isCurrent, onAspect: onAspect)
        }
      } else if !error.isEmpty {
        VStack(spacing: 12) {
          Text(error).font(.callout).textSelection(.enabled)
          Button("Retry") { retry += 1 }
        }.padding(24)
      } else {
        ProgressView("Loading page…")
      }
    }.task(id: requestID) {
      guard enabled else { return }
      let request = requestID
      if loadedRequest == request, url != nil { return }
      url = nil
      error = ""
      do {
        let result = try await library.mediaURL(media, index: media.kind == "images" ? index : 0)
        guard !Task.isCancelled else { return }
        url = result
        loadedRequest = request
        if media.kind == "video" { onAspect(16.0 / 9.0) }
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
}
struct MediaPagePreview: View {
  let media: MediaVersion
  let index: Int
  @EnvironmentObject private var library: LibraryUIModel
  @State private var url: URL?
  @State private var loading = true
  var body: some View {
    ZStack {
      PagePreview(url: url, kind: media.kind, index: index)
      if loading { ProgressView().controlSize(.small) }
    }.onDisappear {
      url = nil
      loading = false
    }
    .task(id: "\(media.id):\(media.storageRootId):\(media.relativePaths):\(index)") {
      loading = true
      let result = try? await library.mediaURL(media, index: media.kind == "images" ? index : 0)
      guard !Task.isCancelled else { return }
      url = result
      loading = false
    }
  }
}
struct ChapterPagePreview: View {
  let chapter: LibraryEntity
  var preferred: MediaVersion? = nil
  let page: Int
  @EnvironmentObject private var library: LibraryUIModel
  var body: some View {
    if let source = library.pageMedia(chapter, preferred: preferred, page: page) {
      MediaPagePreview(media: source.media, index: source.index)
    } else {
      Image(systemName: "photo").foregroundStyle(.secondary)
    }
  }
}
struct PagePreview: View {
  let url: URL?
  let kind: String
  let index: Int
  var contentMode: ContentMode = .fill
  @State private var image: CGImage?
  var body: some View {
    Color.clear.overlay {
      GeometryReader { geometry in
        if let image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        } else {
          FileThumbnail(
            url: url, symbol: kind == "video" ? "play.rectangle" : "photo", contentMode: contentMode
          )
        }
      }
    }.clipped().onDisappear { image = nil }.task(id: "\(url?.path ?? ""):\(index)") {
      image = nil
      if kind == "pdf", let url {
        let result = try? await FileTasks.perform { () -> CGImage? in
          guard let document = PDFDocument(url: url), let page = document.page(at: index) else {
            return nil
          }
          #if os(macOS)
            var rect = CGRect(x: 0, y: 0, width: 300, height: 420)
            return page.thumbnail(of: rect.size, for: .mediaBox).cgImage(
              forProposedRect: &rect, context: nil, hints: nil)
          #else
            return page.thumbnail(of: CGSize(width: 300, height: 420), for: .mediaBox).cgImage
          #endif
        }
        guard !Task.isCancelled else { return }
        image = result ?? nil
      }
    }
  }
}
struct ChapterOverviewScreen: View {
  let chapter: LibraryEntity
  var editing: Bool
  var preferred: MediaVersion? = nil
  var onSelect: ((Int) -> Void)?
  var onSaved: ((LibraryEntity) -> Void)?
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @Environment(\.dismiss) private var dismiss
  @State private var order: [Int] = []
  @State private var dragging: Int?
  @State private var saving = false
  @State private var status = ""
  #if os(macOS)
    @State private var selecting = false
    @State private var selectedPages = Set<Int>()
    @State private var batchMediaId: String?
    @State private var batchRequest: PageBatchRequest?
    @State private var addingImages = false
    @State private var imageRequest: AddImagesRequest?
    private var currentChapter: LibraryEntity {
      session.entities.first { $0.id == chapter.id && !$0.deleted } ?? chapter
    }
    private var batchMedia: MediaVersion? {
      currentChapter.media.first { $0.id == batchMediaId }
        ?? currentChapter.media.first { $0.id == preferred?.id }
        ?? currentChapter.preferredMedia(AppConfiguration.preferredLanguage)
    }
  #endif
  private var media: MediaVersion? {
    editing
      ? (chapter.media.first { $0.language == chapter.originalLanguage } ?? chapter.media.first)
      : (preferred ?? chapter.preferredMedia(AppConfiguration.preferredLanguage))
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack {
          SheetHeading(editing ? "Page Order" : "All Pages", inset: 24)
          #if os(macOS)
            if library.canManage {
              Button("Add Images…", systemImage: "photo.badge.plus") { addingImages = true }
                .disabled(saving).padding(.trailing, 24)
            }
          #endif
        }
        #if os(macOS)
          if selecting, let source = batchMedia {
            selectionControls(source)
            MacPageSelectionGrid(pages: PageBatchPlan.readingOrder(source), selection: $selectedPages) { index in
              AnyView(MediaPagePreview(media: source, index: index)
                .environmentObject(library).environmentObject(session))
            }
            if !status.isEmpty { Text(status).font(.caption).padding(12) }
          } else { pageGrid }
        #else
          pageGrid
        #endif
      }.navigationTitle("")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }.disabled(saving)
          }
          #if os(macOS)
            if !editing, library.canManage, batchMedia?.kind == "images" {
              ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Edit", systemImage: selecting ? "checkmark" : "pencil") {
                  selecting.toggle()
                  selectedPages = []
                  status = ""
                }.disabled(saving)
              }
            }
          #endif
          if editing {
            ToolbarItem(placement: .confirmationAction) {
              Button(saving ? "Saving…" : "Save Reading Order", action: save).disabled(saving || media == nil)
            }
          }
        }
    }
    #if os(macOS)
      .frame(width: 850, height: 650)
      .sheet(item: $batchRequest) { request in
        PageBatchWorkflowScreen(request: request) { updated in
          onSaved?(updated)
          selectedPages = []
          selecting = false
          dismiss()
        }.environmentObject(library).environmentObject(session)
      }
      .fileImporter(isPresented: $addingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
        do {
          let urls = try result.get().sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
          let files = try urls.map { try ImportSourceAccess($0) }
          if !files.isEmpty { imageRequest = AddImagesRequest(chapter: currentChapter, files: files) }
        } catch { status = error.localizedDescription }
      }
      .sheet(item: $imageRequest) { request in
        AddImagesScreen(request: request, initialLanguage: (editing ? media?.language : batchMedia?.language) ?? AppConfiguration.preferredLanguage) { updated in
          onSaved?(updated)
          selectedPages = []
          selecting = false
          dismiss()
        }.environmentObject(library).environmentObject(session)
      }
      .onChange(of: currentChapter.revision) { _, _ in
        if selecting {
          selectedPages = []
          status = "Chapter updated. Review its current pages before selecting again."
        }
      }
    #endif
    .onAppear {
      if let media {
        order =
          editing
          ? (media.pageAlignment?.compactMap { $0 } ?? Array(0..<media.pageCount))
          : Array(
            0..<max(
              media.pageAlignment?.count ?? media.pageCount, chapter.media.first?.pageCount ?? 0))
      }
    }
  }
  private var pageGrid: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text(
          editing
            ? "Drag pages to change reading order. Source filenames stay unchanged. Saved page positions follow the new order."
            : "Choose a page to return to the reader."
        ).foregroundStyle(.secondary)
        if let media {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 18)], spacing: 22) {
            ForEach(order, id: \.self) { index in
              Button {
                if !editing {
                  onSelect?(index)
                  dismiss()
                }
              } label: {
                VStack(spacing: 8) {
                  if editing {
                    MediaPagePreview(media: media, index: index)
                      .aspectRatio(0.72, contentMode: .fit).clipShape(
                        RoundedRectangle(cornerRadius: 8))
                  } else {
                    ChapterPagePreview(chapter: chapter, preferred: media, page: index)
                      .aspectRatio(0.72, contentMode: .fit).clipShape(
                        RoundedRectangle(cornerRadius: 8))
                  }
                  Text("Page \(index + 1)").font(.caption)
                }
              }.buttonStyle(.plain)
                .onDrag {
                  if editing { dragging = index }
                  return NSItemProvider(object: String(index) as NSString)
                }
                .onDrop(
                  of: [UTType.text],
                  delegate: PageOrderDrop(
                    target: index, order: $order, dragging: $dragging, enabled: editing))
            }
          }
        }
        if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
      }.padding(24)
    }
  }
  #if os(macOS)
    private func selectionControls(_ source: MediaVersion) -> some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Picker("Media", selection: Binding(get: { source.id }, set: { batchMediaId = $0; selectedPages = [] })) {
            ForEach(currentChapter.media.filter { $0.kind == "images" }) { Text($0.languageLabel).tag($0.id) }
          }.frame(width: 180)
          Text("\(selectedPages.count) selected").foregroundStyle(.secondary)
          Spacer()
        }
        HStack {
          Button("Select All") { selectedPages = Set(PageBatchPlan.readingOrder(source)) }
          Button("Deselect All") { selectedPages = [] }
          Spacer()
          Button("Set as Translation", systemImage: "globe") { beginBatch(source, translating: true) }
            .disabled(selectedPages.isEmpty)
          Button("Delete", systemImage: "trash", role: .destructive) { beginBatch(source, translating: false) }
            .disabled(selectedPages.isEmpty)
        }
        Text("Click, Command-click, Shift-click or drag a selection rectangle. Only Commit changes files.")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(.horizontal, 24).padding(.bottom, 12)
    }
    private func beginBatch(_ source: MediaVersion, translating: Bool) {
      do {
        let plan = try PageBatchPlan(metadata: currentChapter.input, mediaId: source.id, selected: selectedPages)
        if translating && plan.metadata.media.isEmpty {
          throw LoginError.server("Keep original pages in this chapter before splitting a translation. Use Edit Chapter to change a whole version’s language.")
        }
        batchRequest = PageBatchRequest(chapter: currentChapter, plan: plan, translating: translating)
        status = ""
      } catch { status = error.localizedDescription }
    }
  #endif
  private func save() {
    guard let media,
      let current = session.entities.first(where: { $0.id == chapter.id && !$0.deleted }),
      let index = current.media.firstIndex(where: { $0.id == media.id })
    else { return }
    var input = current.input
    guard current.revision == chapter.revision else {
      status = "Chapter changed. Close and reopen page order to review the latest version."
      return
    }
    let oldOrder = media.pageAlignment?.compactMap { $0 } ?? Array(0..<media.pageCount)
    for position in input.media.indices where position != index {
      let variant = input.media[position]
      input.media[position].pageAlignment = order.map { source in
        oldOrder.firstIndex(of: source).flatMap { variant.sourcePage(at: $0) }
      }
    }
    input.media[index].pageAlignment = order.map { Optional($0) }
    saving = true
    Task {
      defer { saving = false }
      do {
        try await session.update(current, input: input)
        if let updated = session.entities.first(where: { $0.id == chapter.id }) {
          onSaved?(updated)
        }
        dismiss()
      } catch { status = error.localizedDescription }
    }
  }
}
struct PageOrderDrop: DropDelegate {
  let target: Int
  @Binding var order: [Int]
  @Binding var dragging: Int?
  var enabled: Bool
  func dropEntered(info: DropInfo) {
    guard enabled, let dragging, let from = order.firstIndex(of: dragging),
      let to = order.firstIndex(of: target), from != to
    else { return }
    withAnimation {
      order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
  }
  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: enabled ? .move : .cancel)
  }
  func performDrop(info: DropInfo) -> Bool {
    dragging = nil
    return enabled
  }
}
