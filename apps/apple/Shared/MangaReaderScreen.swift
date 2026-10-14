import AVKit
import ImageIO
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
  @State private var urls: [URL]
  @State private var originalURLs: [URL] = []
  @State private var page: Int
  @State private var controls = true
  @State private var thumbnails = false
  @State private var overview = false
  @State private var switching = false
  @State private var started = Date()
  @State private var activeSeconds = 0
  @State private var videoCompleted = false
  @State private var isActive = true
  @State private var pageAspect: CGFloat = 0.7
  init(context: ReadingContext) {
    self.context = context
    _version = State(initialValue: context.version)
    _urls = State(initialValue: context.urls)
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
                  PagePreview(
                    url: resolved(index).url, kind: resolved(index).kind,
                    index: resolved(index).index
                  ).frame(width: 82, height: 112).overlay(
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
              TabView(selection: $page) {
                ForEach(0..<count, id: \.self) { index in canvas(index).tag(index) }
              }.tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, direction == "rtl" ? .rightToLeft : .leftToRight)
            #else
              MacReaderPager(index: $page, count: count, rightToLeft: direction == "rtl") { index in
                AnyView(
                  canvas(index).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    .foregroundStyle(.white))
              }
              .focusable().onMoveCommand { move in
                if move == .left {
                  advance(direction == "rtl" ? 1 : -1)
                } else if move == .right {
                  advance(direction == "rtl" ? -1 : 1)
                }
              }
            #endif
            if switching { ProgressView("Loading language…").padding(18).glassEffect() }
          }
          .clipped().contentShape(Rectangle()).onTapGesture { withAnimation { controls.toggle() } }
          .overlay(alignment: .top) {
            if controls { topControls.padding(16).padding(.top, geometry.safeAreaInsets.top) }
          }
          .overlay(alignment: .bottom) {
            if controls {
              bottomControls.padding(16).padding(.bottom, geometry.safeAreaInsets.bottom)
            }
          }
          if showDescription && !descriptionOnRight {
            descriptionPane.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
              .regularMaterial)
          }
        }
        if showDescription && descriptionOnRight {
          descriptionPane.padding(24).frame(width: 235, alignment: .topLeading).frame(
            maxHeight: .infinity, alignment: .top
          ).background(.regularMaterial)
        }
      }.ignoresSafeArea()
    }
    .background(.black).foregroundStyle(.white)
    #if os(macOS)
      .toolbar(.hidden, for: .windowToolbar)
    #endif
    .sheet(isPresented: $overview) {
      ChapterOverviewScreen(chapter: chapter, editing: false, onSelect: { page = $0 })
        .environmentObject(library).environmentObject(session)
    }
    .task { await loadOriginalIfNeeded() }
    .task(id: "\(resolved(page).url?.path ?? ""):\(resolved(page).index)") { updateAspect() }
    .onAppear {
      activeSeconds = library.state(chapter.id)?.progress?.activeSeconds ?? 0
      started = Date()
      isActive = scenePhase == .active
    }
    .onChange(of: page) { _, _ in recordProgress() }
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
    }
    .accessibilityIdentifier("manga-reader")
  }
  private var topControls: some View {
    HStack(spacing: 12) {
      HStack(spacing: 10) {
        Button("Close Reader", systemImage: "chevron.left") { library.reader = nil }.labelStyle(
          .iconOnly
        ).buttonStyle(.plain).frame(width: 24, height: 24)
        Text(library.title(chapter)).font(.headline).lineLimit(1)
      }.padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular.tint(.black.opacity(0.4)), in: Capsule())
      Spacer()
      Menu {
        ForEach(chapter.media) { media in
          Button {
            switchVersion(media)
          } label: {
            if media.id == version.id {
              Label(media.language.uppercased(), systemImage: "checkmark")
            } else {
              Text(media.language.uppercased())
            }
          }
        }
      } label: {
        Label(version.language.uppercased(), systemImage: "globe")
      }.buttonStyle(.glass).disabled(switching).accessibilityLabel("Change page language")
      Menu("Reader Options", systemImage: "ellipsis") {
        Button("All Pages", systemImage: "square.grid.3x3") { overview = true }
        Toggle("Thumbnail Sidebar", isOn: $thumbnails)
        Toggle("Chapter Description", isOn: $showDescription)
        #if os(macOS)
          Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
            NSApp.keyWindow?.toggleFullScreen(nil)
          }
        #endif
      }.labelStyle(.iconOnly).buttonStyle(.glass)
    }
  }
  private var bottomControls: some View {
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
  private var descriptionPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(library.title(chapter)).font(.headline)
      Text(chapter.description(in: AppConfiguration.preferredLanguage)).font(.callout)
        .foregroundStyle(.secondary)
      SourceLinksView(links: chapter.sources)
    }
  }
  @ViewBuilder private func canvas(_ canonical: Int) -> some View {
    let resolved = resolved(canonical)
    if let url = resolved.url {
      if resolved.kind == "video" {
        NativeVideoPage(
          url: url,
          onComplete: {
            videoCompleted = true
            recordProgress()
          })
      } else {
        NativeReadingPage(
          url: url, pdfPage: resolved.kind == "pdf" ? resolved.index : nil,
          onSwipe: { advance(direction == "rtl" ? -$0 : $0) })
      }
    } else {
      ContentUnavailableView(
        "Page unavailable", systemImage: "photo",
        description: Text(
          "This language has no matching page and the original is not available on this device."))
    }
  }
  private func resolved(_ canonical: Int) -> (url: URL?, kind: String, index: Int) {
    let mapped = version.sourcePage(at: canonical)
    if let mapped, mapped >= 0, mapped < version.pageCount {
      let url = version.kind == "images" ? (mapped < urls.count ? urls[mapped] : nil) : urls.first
      return (url, version.kind, mapped)
    }
    let source = original.sourcePage(at: canonical)
    let originalURL =
      original.kind == "images"
      ? source.flatMap { $0 < originalURLs.count ? originalURLs[$0] : nil } : originalURLs.first
    return (source == nil ? nil : originalURL, original.kind, source ?? canonical)
  }
  private func advance(_ delta: Int) { page = min(max(0, page + delta), max(0, count - 1)) }
  private func switchVersion(_ media: MediaVersion) {
    guard media.id != version.id else { return }
    switching = true
    Task {
      defer { switching = false }
      do {
        let files: [URL]
        if let cached = library.cachedURLs(media) {
          files = cached
        } else {
          files = try await library.smb.download(media)
        }
        version = media
        urls = files
        page = min(page, max(0, count - 1))
        await loadOriginalIfNeeded()
      } catch { library.show(error) }
    }
  }
  private func loadOriginalIfNeeded() async {
    guard version.id != original.id else {
      originalURLs = urls
      return
    }
    if let cached = library.cachedURLs(original) {
      originalURLs = cached
      return
    }
    if version.pageAlignment?.contains(where: { $0 == nil }) == true
      || version.pageCount < original.pageCount
    {
      originalURLs = (try? await library.smb.download(original)) ?? []
    }
  }
  private func updateAspect() {
    let source = resolved(page)
    guard let url = source.url else { return }
    if source.kind == "video" {
      pageAspect = 16.0 / 9.0
      return
    }
    if source.kind == "pdf",
      let box = PDFDocument(url: url)?.page(at: source.index)?.bounds(for: .mediaBox),
      box.height > 0
    {
      pageAspect = box.width / box.height
      return
    }
    if let image = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber, height.doubleValue > 0
    {
      let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
      pageAspect =
        (5...8).contains(orientation)
        ? CGFloat(height.doubleValue / width.doubleValue)
        : CGFloat(width.doubleValue / height.doubleValue)
    }
  }
  private func accumulateTime() {
    if isActive { activeSeconds += max(0, Int(Date().timeIntervalSince(started))) }
    started = Date()
  }
  private func recordProgress() {
    guard session.account != nil, library.entity(chapter.id) != nil else { return }
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

struct NativeVideoPage: View {
  let url: URL
  var onComplete: (() -> Void)?
  @State private var player: AVPlayer?
  @State private var unsupported = false
  var body: some View {
    Group {
      if unsupported {
        ContentUnavailableView(
          "Video cannot be played", systemImage: "play.slash",
          description: Text("This device does not support the file's video codec."))
      } else if let player {
        VideoPlayer(player: player)
      } else {
        ProgressView()
      }
    }.task(id: url) {
      let asset = AVURLAsset(url: url)
      if (try? await asset.load(.isPlayable)) == true {
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      } else {
        unsupported = true
      }
    }.onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) {
      notification in
      if let item = notification.object as? AVPlayerItem, item === player?.currentItem {
        onComplete?()
      }
    }.onDisappear { player?.pause() }
  }
}
struct PagePreview: View {
  let url: URL?
  let kind: String
  let index: Int
  @State private var image: CGImage?
  var body: some View {
    ZStack {
      Rectangle().fill(.quaternary)
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
      } else {
        FileThumbnail(url: url, symbol: kind == "video" ? "play.rectangle" : "photo")
      }
    }.clipped().task(id: "\(url?.path ?? ""):\(index)") {
      image = nil
      if kind == "pdf", let url, let page = PDFDocument(url: url)?.page(at: index) {
        #if os(macOS)
          var rect = CGRect(x: 0, y: 0, width: 300, height: 420)
          image = page.thumbnail(of: rect.size, for: .mediaBox).cgImage(
            forProposedRect: &rect, context: nil, hints: nil)
        #else
          image = page.thumbnail(of: CGSize(width: 300, height: 420), for: .mediaBox).cgImage
        #endif
      }
    }
  }
}
struct ChapterOverviewScreen: View {
  let chapter: LibraryEntity
  var editing: Bool
  var onSelect: ((Int) -> Void)?
  var onSaved: ((LibraryEntity) -> Void)?
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @Environment(\.dismiss) private var dismiss
  @State private var order: [Int] = []
  @State private var dragging: Int?
  @State private var saving = false
  @State private var status = ""
  private var media: MediaVersion? {
    editing
      ? (chapter.media.first { $0.language == chapter.originalLanguage } ?? chapter.media.first)
      : chapter.preferredMedia(AppConfiguration.preferredLanguage)
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text(
            editing
              ? "Drag pages to change reading order. Source filenames stay unchanged. Saved page positions follow the new order."
              : "Choose a page to return to the reader."
          ).foregroundStyle(.secondary)
          if let media {
            let urls = library.cachedURLs(media) ?? []
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 18)], spacing: 22) {
              ForEach(order, id: \.self) { index in
                Button {
                  if !editing {
                    onSelect?(index)
                    dismiss()
                  }
                } label: {
                  VStack(spacing: 8) {
                    let source =
                      editing
                      ? (
                        url: media.kind == "images"
                          ? (index < urls.count ? urls[index] : nil) : urls.first, kind: media.kind,
                        index: index
                      ) : library.pageSource(chapter, page: index)
                    PagePreview(url: source.url, kind: source.kind, index: source.index)
                      .aspectRatio(0.72, contentMode: .fit).clipShape(
                        RoundedRectangle(cornerRadius: 8))
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
      }.navigationTitle(editing ? "Page Order" : "All Pages")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }.disabled(saving)
          }
          if editing {
            ToolbarItem(placement: .confirmationAction) {
              Button(saving ? "Saving…" : "Save Reading Order", action: save).disabled(saving)
            }
          }
        }
    }
    #if os(macOS)
      .frame(width: 850, height: 650)
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
