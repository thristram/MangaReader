import AVKit
import SwiftUI

// One transport for the active reader, shared by the canvas and its overlay.
// AVKit supplies native rendering; neither platform owns a second control bar.
@MainActor final class ReaderVideoPlayback: ObservableObject {
  let player = AVPlayer()
  @Published private(set) var url: URL?
  @Published private(set) var ready = false
  @Published private(set) var displayReady = false
  @Published private(set) var unsupported = false
  @Published private(set) var playing = false
  @Published private(set) var playRequested = false
  @Published private(set) var elapsed = 0.0
  @Published private(set) var duration = 0.0
  @Published private(set) var muted = false
  private var generation = UUID()
  private var timeObserver: Any?
  private var itemObserver: NSKeyValueObservation?
  private var transportObserver: NSKeyValueObservation?
  private var assetPrepared = false
  private var initialPosition = 0.0
  private var preparation: Task<Void, Never>?
  @Published private(set) var scrubbing = false
  private var seekInFlight = false
  private var seekSerial = 0
  private var pendingSeek: (time: Double, exact: Bool, serial: Int)?
  var seeking: Bool { seekInFlight || pendingSeek != nil }

  init() {
    transportObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in self?.updatePlayingState() }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        // The slider owns its displayed position during a drag/chasing seek.
        // Old playback ticks must never pull it back toward the previous time.
        guard !self.scrubbing, !self.seeking else { return }
        let seconds = time.seconds
        let elapsed = seconds.isFinite ? max(0, seconds) : 0
        if self.elapsed != elapsed { self.elapsed = elapsed }
        self.updatePlayingState()
      }
    }
  }
  deinit { if let timeObserver { player.removeTimeObserver(timeObserver) } }

  func load(_ source: URL) async {
    guard !Task.isCancelled else { return }
    if url == source, player.currentItem != nil, !unsupported {
      await preparation?.value
      return
    }
    reset()
    url = source
    let request = generation
    // SwiftUI may cancel/recreate a page task while preserving its native view.
    // Keep one reader-owned preparation so a new waiter cannot inherit an item
    // whose cancelled predecessor left it permanently unprepared.
    let task = Task { @MainActor [weak self] in
      guard let self, request == self.generation else { return }
      await self.prepare(source, request: request)
    }
    preparation = task
    await task.value
    if generation == request { preparation = nil }
  }
  private func prepare(_ source: URL, request: UUID) async {
    let asset = AVURLAsset(url: source)
    // Attach the item immediately so AVKit can prepare its renderer while asset
    // properties load. Finder-mounted NAS paths are also file URLs, so determine
    // whether this is a local volume off the main actor before changing buffering.
    player.automaticallyWaitsToMinimizeStalling = true
    let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable"])
    itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
      Task { @MainActor in
        guard let self, let item, request == self.generation, item === self.player.currentItem else { return }
        self.itemChanged(item)
      }
    }
    player.replaceCurrentItem(with: item)
    do {
      async let playable = asset.load(.isPlayable)
      async let length = asset.load(.duration)
      async let videoTracks = asset.loadTracks(withMediaType: .video)
      async let localFile = FileTasks.perform {
        source.isFileURL
          && (try? source.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
      }
      let properties = try await (playable, length, videoTracks, localFile)
      guard let track = properties.2.first else {
        if generation == request, !Task.isCancelled { fail() }
        return
      }
      async let decodable = track.load(.isDecodable)
      async let range = track.load(.timeRange)
      async let segments = track.load(.segments)
      let video = try await (decodable, range, segments)
      guard generation == request, !Task.isCancelled else { return }
      guard properties.0, video.0 else { fail(); return }
      player.automaticallyWaitsToMinimizeStalling = !properties.3
      let seconds = properties.1.seconds
      duration = seconds.isFinite ? max(0, seconds) : 0
      let start = video.1.start.seconds
      let firstSample = video.2.filter { !$0.isEmpty }
        .map { $0.timeMapping.target.start.seconds }.filter { $0.isFinite }.min() ?? 0
      initialPosition = max(start.isFinite ? max(0, start) : 0, firstSample)
      assetPrepared = true
      itemChanged(item)
    } catch {
      if generation == request, !Task.isCancelled { fail() }
    }
  }
  private func itemChanged(_ item: AVPlayerItem) {
    switch item.status {
    case .readyToPlay:
      guard assetPrepared, !ready else { return }
      let seconds = item.duration.seconds
      if seconds.isFinite { duration = max(0, seconds) }
      ready = true
      // Decode the initial frame while paused instead of waiting for Play to
      // wake the video renderer. This also uses the serialized seek path.
      // MP4 edit lists can put the first video frame after time zero. Skip that
      // empty leading interval instead of playing a black screen through it.
      elapsed = initialPosition
      enqueueSeek(initialPosition, exact: true)
    case .failed: fail()
    default: break
    }
  }
  private func fail() {
    unsupported = true
    ready = false
    displayReady = false
    playRequested = false
    player.pause()
    updatePlayingState()
  }
  func displayed(_ item: AVPlayerItem, ready: Bool) {
    guard item === player.currentItem, url != nil, !unsupported else { return }
    guard displayReady != ready else { return }
    displayReady = ready
    reconcilePlayback()
  }
  private func updatePlayingState() {
    let active = ready && displayReady && player.timeControlStatus == .playing
    if playing != active { playing = active }
  }
  private func reconcilePlayback() {
    if ready && displayReady && playRequested && !scrubbing && !seeking {
      if player.rate == 0 { player.play() }
    } else { player.pause() }
    updatePlayingState()
  }
  func reset() {
    generation = UUID()
    preparation?.cancel()
    preparation = nil
    itemObserver?.invalidate()
    itemObserver = nil
    assetPrepared = false
    initialPosition = 0
    pendingSeek = nil
    seekInFlight = false
    scrubbing = false
    player.currentItem?.cancelPendingSeeks()
    player.pause()
    player.replaceCurrentItem(with: nil)
    url = nil
    ready = false
    displayReady = false
    unsupported = false
    playing = false
    playRequested = false
    elapsed = 0
    duration = 0
  }
  func release(_ source: URL) { if url == source { reset() } }
  func toggle() {
    guard ready else { return }
    playRequested.toggle()
    if playRequested, duration > 0, elapsed >= duration - 0.1 { seek(initialPosition) }
    reconcilePlayback()
  }
  func beginScrubbing() {
    guard ready else { return }
    scrubbing = true
    player.pause()
    updatePlayingState()
  }
  func endScrubbing() {
    guard ready else { return }
    scrubbing = false
    // Preview seeks permit a small tolerance; releasing the thumb always
    // requests the exact final frame before playback resumes.
    enqueueSeek(elapsed, exact: true)
  }
  func seek(_ seconds: Double) {
    guard ready, seconds.isFinite else { return }
    elapsed = min(max(0, seconds), duration)
    player.pause()
    updatePlayingState()
    enqueueSeek(elapsed, exact: !scrubbing)
  }
  private func enqueueSeek(_ seconds: Double, exact: Bool) {
    seekSerial += 1
    pendingSeek = (seconds, exact, seekSerial)
    chaseSeek()
  }
  private func chaseSeek() {
    guard !seekInFlight, let target = pendingSeek, let item = player.currentItem else { return }
    seekInFlight = true
    let request = generation
    let tolerance = CMTime(seconds: target.exact ? 0 : 0.08, preferredTimescale: 600)
    player.seek(to: CMTime(seconds: target.time, preferredTimescale: 600),
                toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak item] _ in
      Task { @MainActor in
        guard let self, request == self.generation, item === self.player.currentItem else { return }
        self.seekInFlight = false
        if self.pendingSeek?.serial == target.serial {
          self.pendingSeek = nil
          if !self.scrubbing {
            let actual = self.player.currentTime().seconds
            if actual.isFinite { self.elapsed = min(max(0, actual), self.duration) }
            self.reconcilePlayback()
          }
        } else { self.chaseSeek() }
      }
    }
  }
  func toggleMute() { muted.toggle(); player.isMuted = muted }
  @discardableResult func finished(_ item: AVPlayerItem) -> Bool {
    guard item === player.currentItem, !scrubbing, !seeking else { return false }
    player.pause()
    playing = false
    playRequested = false
    elapsed = duration
    return true
  }
}

#if os(macOS)
private typealias ReaderNativeVideoView = AVPlayerView
#else
private typealias ReaderNativeVideoView = AVPlayerLayer
#endif

// Keep the native output mounted during loading and observe the first displayed
// frame. AVPlayerItem.readyToPlay alone does not mean AVKit has shown video.
@MainActor final class ReaderVideoDisplayObserver {
  private weak var view: ReaderNativeVideoView?
  private var observation: NSKeyValueObservation?
  var onDisplay: (AVPlayerItem, Bool) -> Void = { _, _ in }
  fileprivate func bind(_ view: ReaderNativeVideoView) {
    guard self.view !== view else {
      Task { @MainActor [weak self] in self?.refresh() }
      return
    }
    self.view = view
    observation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  func refresh() {
    guard let view, let item = view.player?.currentItem else { return }
    onDisplay(item, view.isReadyForDisplay)
  }
  func release() { observation?.invalidate(); observation = nil; view = nil }
}

#if os(macOS)
struct ReaderVideoCanvas: NSViewRepresentable {
  let player: AVPlayer
  var onDisplay: (AVPlayerItem, Bool) -> Void = { _, _ in }
  func makeCoordinator() -> ReaderVideoDisplayObserver { ReaderVideoDisplayObserver() }
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .none
    view.videoGravity = .resizeAspect
    view.player = player
    view.focusRingType = .none
    context.coordinator.onDisplay = onDisplay
    context.coordinator.bind(view)
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
    context.coordinator.onDisplay = onDisplay
    context.coordinator.bind(view)
  }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ReaderVideoDisplayObserver) {
    coordinator.release(); view.player = nil
  }
}

#else
// The reader already supplies controls and presentation. A backing AVPlayerLayer
// avoids a second view-controller/remote-video hierarchy whose initial layout
// could stay stale inside the collection-cell -> hosting-controller -> SwiftUI
// chain until an interactive dismissal changed the root transform.
final class PhoneReaderVideoView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  var player: AVPlayer? {
    get { playerLayer.player }
    set { if playerLayer.player !== newValue { playerLayer.player = newValue } }
  }
  var isReadyForDisplay: Bool { playerLayer.isReadyForDisplay }
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    playerLayer.videoGravity = .resizeAspect
  }
  required init?(coder: NSCoder) { fatalError() }
}

struct ReaderVideoCanvas: UIViewRepresentable {
  let player: AVPlayer
  var onDisplay: (AVPlayerItem, Bool) -> Void = { _, _ in }
  func makeCoordinator() -> ReaderVideoDisplayObserver { ReaderVideoDisplayObserver() }
  func makeUIView(context: Context) -> PhoneReaderVideoView {
    let view = PhoneReaderVideoView()
    view.player = player
    context.coordinator.onDisplay = onDisplay
    context.coordinator.bind(view.playerLayer)
    return view
  }
  func updateUIView(_ view: PhoneReaderVideoView, context: Context) {
    view.player = player
    context.coordinator.onDisplay = onDisplay
    context.coordinator.bind(view.playerLayer)
  }
  static func dismantleUIView(_ view: PhoneReaderVideoView, coordinator: ReaderVideoDisplayObserver) {
    coordinator.release()
    view.player = nil
  }
}
#endif

struct ReaderVideoPage: View {
  let url: URL
  var isCurrent: Bool
  var onComplete: (() -> Void)?
  @EnvironmentObject private var playback: ReaderVideoPlayback
  var body: some View {
    Group {
      if !isCurrent { Color.black }
      else if playback.unsupported {
        ContentUnavailableView("Video cannot be played", systemImage: "play.slash",
          description: Text("This device does not support the file's video codec."))
      } else {
        ZStack {
          ReaderVideoCanvas(player: playback.player, onDisplay: { playback.displayed($0, ready: $1) })
            .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
          if !playback.displayReady || playback.url != url { ProgressView("Loading video…") }
        }
      }
    }
    .task(id: "\(url):\(isCurrent)") {
      if isCurrent { await playback.load(url) }
    }
    .onChange(of: isCurrent) { _, current in if !current { playback.release(url) } }
    .onDisappear { playback.release(url) }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) {
      notification in
      if isCurrent, playback.url == url,
        let item = notification.object as? AVPlayerItem, item === playback.player.currentItem {
        if playback.finished(item) { onComplete?() }
      }
    }
  }
}

struct ReaderVideoControls: View {
  @ObservedObject var playback: ReaderVideoPlayback
  private var buttonSize: CGFloat {
    #if os(iOS)
      44
    #else
      28
    #endif
  }
  private func timestamp(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    return String(format: "%d:%02d", value / 60, value % 60)
  }
  var body: some View {
    HStack(spacing: 12) {
      Button(playback.playRequested ? "Pause Video" : "Play Video",
             systemImage: playback.playRequested ? "pause.fill" : "play.fill") {
        playback.toggle()
      }.labelStyle(.iconOnly).frame(width: buttonSize, height: max(32, buttonSize))
      Text(timestamp(playback.elapsed)).font(.caption.monospacedDigit()).frame(minWidth: 36)
      Slider(value: Binding(get: { playback.elapsed }, set: { playback.seek($0) }),
             in: 0...max(0.01, playback.duration), onEditingChanged: { editing in
               if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
             })
        .accessibilityLabel("Video Position")
      Text(timestamp(playback.duration)).font(.caption.monospacedDigit()).frame(minWidth: 36)
      Button(playback.muted ? "Unmute Video" : "Mute Video",
             systemImage: playback.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
        playback.toggleMute()
      }.labelStyle(.iconOnly).frame(width: buttonSize, height: max(32, buttonSize))
    }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 5)
      .frame(maxWidth: 480).glassEffect(in: Capsule())
      .disabled(!playback.ready)
  }
}
