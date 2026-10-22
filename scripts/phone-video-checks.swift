// Simulator-only regression; synthetic local media and fixture account.
import AVKit
import MangaCore
import SwiftUI
import UIKit

@MainActor enum PhoneVideoChecks {
  static func player(in controller: UIViewController) -> PhoneReaderVideoView? {
    func find(_ view: UIView) -> PhoneReaderVideoView? {
      if let video = view as? PhoneReaderVideoView { return video }
      return view.subviews.lazy.compactMap(find).first
    }
    if controller.isViewLoaded, let video = find(controller.view) { return video }
    if let presented = controller.presentedViewController, let player = player(in: presented) { return player }
    return controller.children.lazy.compactMap { player(in: $0) }.first
  }
  static func run(window: UIWindow, session: AppSession, library: LibraryUIModel, directory: URL) async throws {
    let url = directory.appendingPathComponent("reader-video.mp4")
    try await makeVideo(url)
    for _ in 0..<3 {
      let loading = ReaderVideoPlayback()
      let first = Task { @MainActor in await loading.load(url) }
      try await PhoneReaderChecks.wait("Initial MP4 load did not create an item") { loading.player.currentItem != nil }
      first.cancel()
      // Recreated SwiftUI page attaches to the same item while metadata is loading.
      await loading.load(url)
      try await PhoneReaderChecks.wait("Cancelled page load orphaned the shared video item") { loading.ready }
      loading.reset()
      await first.value
      try PhoneReaderChecks.expect(loading.player.currentItem == nil && !loading.ready,
                                  "Old video preparation revived an item after reset")
    }
    let playback = ReaderVideoPlayback()
    await playback.load(url)
    try await PhoneReaderChecks.wait("Local MP4 item never became ready") { playback.ready && !playback.seeking }
    try PhoneReaderChecks.expect(playback.ready && playback.duration >= 9.9, "Shared iOS player cannot load a real MP4")
    try PhoneReaderChecks.expect(!playback.player.automaticallyWaitsToMinimizeStalling,
                                "Downloaded MP4 still uses streaming startup buffering")
    // A ready asset/item must not advance its clock before the video output exists.
    playback.toggle()
    try await Task.sleep(for: .milliseconds(150))
    try PhoneReaderChecks.expect(playback.playRequested && !playback.playing
      && playback.player.rate == 0 && playback.player.currentTime().seconds < 0.05,
      "Playback advances through a black frame before the native output is ready")
    playback.toggle()
    var completed = false
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    playback.player.currentItem!.add(output)
    let hosting = UIHostingController(rootView:
      ReaderVideoPage(url: url, isCurrent: true, onComplete: { completed = true }).environmentObject(playback))
    hosting.safeAreaRegions = []
    window.rootViewController = hosting
    try await PhoneReaderChecks.wait("Native iOS video canvas did not mount") { player(in: hosting) != nil }
    let native = player(in: hosting)!
    try await PhoneReaderChecks.wait("Paused local MP4 never displays its first frame") {
      native.isReadyForDisplay && playback.displayReady
    }
    try PhoneReaderChecks.expect(!playback.playing && playback.elapsed < 0.05,
                                "Preparing the first video frame starts playback")
    try PhoneReaderChecks.expect(native.subviews.isEmpty && native.player === playback.player,
                                "Video surface has a separate control/child hierarchy")
    try PhoneReaderChecks.expect(native.playerLayer.videoGravity == .resizeAspect, "Video must fit without cropping")
    try PhoneReaderChecks.expect(native.playerLayer.bounds == native.bounds
      && native.playerLayer.videoRect.width > 0, "Initial video backing-layer geometry is empty")
    playback.toggle()
    try await PhoneReaderChecks.wait("Overlay play does not start iOS video without tapping it") {
      playback.playing && playback.elapsed > 0.1
    }
    playback.toggle()
    try await PhoneReaderChecks.wait("Overlay pause state did not settle") { !playback.playing }
    try PhoneReaderChecks.expect(!playback.playing && playback.player.rate == 0, "Overlay pause does not pause AVKit")
    playback.seek(3)
    try PhoneReaderChecks.expect(abs(playback.elapsed - 3) < 0.01, "Overlay seek does not update position")
    // Rapid alternating/backward drags coalesce; stale ticks and old seeks may
    // not win over the final exact frame when the thumb is released.
    try await PhoneReaderChecks.wait("Initial seek did not finish") { !playback.seeking }
    playback.beginScrubbing()
    for target in [8.0, 1.0, 7.0, 0.5, 6.0, 2.0] { playback.seek(target) }
    try PhoneReaderChecks.expect(abs(playback.elapsed - 2) < 0.01, "Playback tick overwrites scrub target")
    playback.endScrubbing()
    try await PhoneReaderChecks.wait("Rapid backward scrubbing does not reach the final frame") {
      !playback.seeking && abs(playback.player.currentTime().seconds - 2) < 0.12
    }
    var renderedTime = CMTime.invalid
    try await PhoneReaderChecks.wait("Backward seek changes the slider but not the rendered video frame") {
      let buffer = output.copyPixelBuffer(forItemTime: CMTime(seconds: 2, preferredTimescale: 600),
                                         itemTimeForDisplay: &renderedTime)
      return buffer != nil && abs(renderedTime.seconds - 2) < 0.12
    }
    playback.toggleMute()
    try PhoneReaderChecks.expect(playback.muted && playback.player.isMuted, "Overlay mute does not control AVKit")
    playback.seek(9.8)
    playback.toggle()
    try await PhoneReaderChecks.wait("End of video leaves the overlay stuck on Pause") {
      completed && !playback.playing && playback.player.rate == 0
    }
    playback.toggle()
    try await PhoneReaderChecks.wait("Play at the end does not restart the video") {
      playback.playing && playback.elapsed < 1
    }
    window.rootViewController = UIViewController()
    try await PhoneReaderChecks.wait("Leaving the page retains the active video") { playback.player.currentItem == nil }
    let invalid = directory.appendingPathComponent("invalid.webm")
    try Data("not a supported video".utf8).write(to: invalid)
    await playback.load(invalid)
    try PhoneReaderChecks.expect(playback.unsupported && !playback.ready, "Unsupported iOS codec has no fallback")
    await playback.load(url)
    try await PhoneReaderChecks.wait("Valid video item cannot recover") { playback.ready }
    try PhoneReaderChecks.expect(playback.ready && !playback.unsupported, "Valid video cannot recover after an unsupported file")
    playback.reset()

    // A real MP4 edit list can leave the video track empty before its first sample.
    let delayed = directory.appendingPathComponent("delayed-start.mp4")
    try await makeVideo(delayed, start: 2)
    let delayedPlayback = ReaderVideoPlayback()
    let delayedHost = UIHostingController(rootView:
      ReaderVideoPage(url: delayed, isCurrent: true).environmentObject(delayedPlayback))
    window.rootViewController = delayedHost
    try await PhoneReaderChecks.wait("MP4 with a delayed video track remains black on opening") {
      delayedPlayback.ready && delayedPlayback.displayReady && !delayedPlayback.seeking
    }
    try PhoneReaderChecks.expect(delayedPlayback.player.currentTime().seconds >= 1.99
      && delayedPlayback.player.rate == 0, "MP4 initial seek did not skip its empty leading video interval")
    window.rootViewController = UIViewController()

    // Open the production full-screen reader with a downloaded synthetic video.
    // Keep this screen open after checks for actual tap/overlay inspection.
    let index = session.entities.firstIndex { $0.id == "c0-0" }!
    var chapter = session.entities[index]
    var media = chapter.media[0]
    media.id = "reader-video-layer-check"
    media.kind = "video"
    media.pageCount = 1
    media.relativePaths = ["reader-video.mp4"]
    media.pageAlignment = nil
    chapter.media = [media]
    chapter.originalLanguage = media.language
    session.entities[index] = chapter
    _ = try await library.smb.download(media, localURLs: [url])
    // The original reader may still be open in the detached hosting controller.
    library.reader = nil
    library.open(chapter, page: 0)
    try await PhoneReaderChecks.wait("Downloaded video reading context did not open") { library.reader != nil }
    let productionPlayback = ReaderVideoPlayback()
    func installReader() {
      window.rootViewController = UIHostingController(rootView:
        MangaReaderScreen(context: library.reader!, playback: productionPlayback)
          .environmentObject(library).environmentObject(session))
    }
    installReader()
    try await PhoneReaderChecks.wait("Production iOS video reader did not load") {
      player(in: window.rootViewController!)?.player?.currentItem != nil
    }
    let production = player(in: window.rootViewController!)!
    let active = production.player!
    try await PhoneReaderChecks.wait("Downloaded production reader stays black before Play") {
      production.isReadyForDisplay
    }
    try PhoneReaderChecks.expect(active.rate == 0 && active.currentTime().seconds < 0.05,
                                "Opening downloaded video silently advances before displaying a frame")
    try PhoneReaderChecks.expect(production.subviews.isEmpty, "Production reader reintroduced a nested video controller")
    let frame = production.convert(production.bounds, to: window)
    try PhoneReaderChecks.expect(abs(frame.minY) < 1 && abs(frame.height - window.bounds.height) < 1,
                                "Video viewport does not fill the reader: \(frame)")
    try PhoneReaderChecks.expect(library.stateInput(chapter.id)?.progress?.completed != true,
                                "Opening a single-file video marks it completed")
    // Only a real end-of-playback notification should complete this chapter.
    productionPlayback.seek(9.8)
    productionPlayback.toggle()
    try await PhoneReaderChecks.wait("Video completion did not persist through the production reader") {
      library.stateInput(chapter.id)?.progress?.completed == true
    }
    library.reader = nil
    window.rootViewController = UIViewController()
    try await PhoneReaderChecks.wait("Closing production preview does not release AVPlayer") { active.currentItem == nil }
    library.open(chapter, page: 0)
    try await PhoneReaderChecks.wait("Reopened video context did not open") { library.reader != nil }
    installReader()
    try await PhoneReaderChecks.wait("Video cannot reopen after closing") {
      player(in: window.rootViewController!)?.isReadyForDisplay == true
    }
    // Exercise the real animated fullScreenCover route, not only a directly
    // installed reader. Do not send any dismissal/resize gesture before first frame.
    library.reader = nil
    window.rootViewController = UIHostingController(rootView: MangaRootScreen(session: session, library: library))
    for iteration in 0..<3 {
      library.open(chapter, page: 0)
      try await PhoneReaderChecks.wait("Presented video does not render until a dismissal gesture") {
        guard let video = player(in: window.rootViewController!), video.window === window,
          video.player?.currentItem != nil, video.isReadyForDisplay,
          let presentation = video.playerLayer.presentation() else { return false }
        return video.bounds.width > 0 && video.bounds.height > 0
          && presentation.bounds.size == video.bounds.size
          && video.playerLayer.videoRect.width > 0
      }
      let surface = player(in: window.rootViewController!)!
      try PhoneReaderChecks.expect(surface.layer === surface.playerLayer,
        "Video still depends on a separately laid-out child rendering layer")
      try PhoneReaderChecks.expect(surface.player?.rate == 0,
        "First-frame rendering silently starts the presented video")
      if iteration < 2 {
        let old = surface.player!
        library.reader = nil
        try await PhoneReaderChecks.wait("Dismissed modal video retains its player") { old.currentItem == nil }
      }
    }
    print("PASS: downloaded MP4 first frame and backing-layer geometry before gestures; three actual full-screen presentations; cancelled load/reopen; leading edits; backward scrubbing and shared transport.")
  }

  private static func makeVideo(_ url: URL, start: Int64 = 0) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<10 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      var buffer: CVPixelBuffer?
      CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer)
      guard let buffer else { fatalError("fixture pixel buffer") }
      CVPixelBufferLockBaseAddress(buffer, [])
      // Four visible color blocks identify a real first frame in on-screen review.
      let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
      for y in 0..<180 {
        for x in 0..<320 {
          let pixel = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
          address[pixel] = 255
          address[pixel + 1] = x < 160 ? 220 : 40
          address[pixel + 2] = y < 90 ? 80 : 200
          address[pixel + 3] = UInt8(100 + index * 5)
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: start + Int64(index), timescale: 1))
      else { throw writer.error! }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: start + 10, timescale: 1))
    await writer.finishWriting()
    if let error = writer.error { throw error }
  }
}
