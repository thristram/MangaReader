import AVKit
import SwiftUI

// One transport for the active reader, shared by the canvas and its overlay.
// AVPlayerView supplies native rendering; it never owns a second set of controls.
@MainActor final class ReaderVideoPlayback: ObservableObject {
  let player = AVPlayer()
  @Published private(set) var url: URL?
  @Published private(set) var ready = false
  @Published private(set) var unsupported = false
  @Published private(set) var playing = false
  @Published private(set) var elapsed = 0.0
  @Published private(set) var duration = 0.0
  @Published private(set) var muted = false
  private var generation = UUID()
  private var timeObserver: Any?

  init() {
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        let seconds = time.seconds
        let elapsed = seconds.isFinite ? max(0, seconds) : 0
        if self.elapsed != elapsed { self.elapsed = elapsed }
        let playing = self.player.rate != 0
        if self.playing != playing { self.playing = playing }
      }
    }
  }
  deinit { if let timeObserver { player.removeTimeObserver(timeObserver) } }

  func load(_ source: URL) async {
    if url == source, ready { return }
    reset()
    url = source
    let request = generation
    let asset = AVURLAsset(url: source)
    do {
      let playable = try await asset.load(.isPlayable)
      let length = try await asset.load(.duration).seconds
      guard generation == request, !Task.isCancelled else { return }
      guard playable else { unsupported = true; return }
      duration = length.isFinite ? max(0, length) : 0
      player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
      ready = true
    } catch {
      if generation == request, !Task.isCancelled { unsupported = true }
    }
  }
  func reset() {
    generation = UUID()
    player.pause()
    player.replaceCurrentItem(with: nil)
    url = nil
    ready = false
    unsupported = false
    playing = false
    elapsed = 0
    duration = 0
  }
  func release(_ source: URL) { if url == source { reset() } }
  func toggle() {
    guard ready else { return }
    if playing { player.pause() } else {
      if duration > 0, elapsed >= duration - 0.1 { seek(0) }
      player.play()
    }
    playing = player.rate != 0
  }
  func seek(_ seconds: Double) {
    guard ready, seconds.isFinite else { return }
    elapsed = min(max(0, seconds), duration)
    player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
  }
  func toggleMute() { muted.toggle(); player.isMuted = muted }
}

struct ReaderVideoCanvas: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .none
    view.videoGravity = .resizeAspect
    view.player = player
    view.focusRingType = .none
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct MacVideoPage: View {
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
      } else if playback.ready, playback.url == url {
        ReaderVideoCanvas(player: playback.player).allowsHitTesting(false)
      } else { ProgressView() }
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
        onComplete?()
      }
    }
  }
}

struct ReaderVideoControls: View {
  @ObservedObject var playback: ReaderVideoPlayback
  private func timestamp(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    return String(format: "%d:%02d", value / 60, value % 60)
  }
  var body: some View {
    HStack(spacing: 12) {
      Button(playback.playing ? "Pause Video" : "Play Video",
             systemImage: playback.playing ? "pause.fill" : "play.fill") {
        playback.toggle()
      }.labelStyle(.iconOnly).frame(width: 28, height: 32)
      Text(timestamp(playback.elapsed)).font(.caption.monospacedDigit()).frame(minWidth: 36)
      Slider(value: Binding(get: { playback.elapsed }, set: { playback.seek($0) }),
             in: 0...max(0.01, playback.duration))
        .accessibilityLabel("Video Position")
      Text(timestamp(playback.duration)).font(.caption.monospacedDigit()).frame(minWidth: 36)
      Button(playback.muted ? "Unmute Video" : "Mute Video",
             systemImage: playback.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
        playback.toggleMute()
      }.labelStyle(.iconOnly).frame(width: 28, height: 32)
    }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 5)
      .frame(maxWidth: 480).glassEffect(in: Capsule())
      .disabled(!playback.ready)
  }
}
