import AppKit
import AVKit
import SwiftUI

// The regression harness deliberately cannot activate the user's desktop.
// Supply key-window state here; the visible preview checks real activation.
@MainActor private final class ReaderKeyTestWindow: NSWindow {
  var readerIsKey = true
  var deliveredKeys = 0
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown { deliveredKeys += 1 }
    super.sendEvent(event)
  }
  override var isKeyWindow: Bool { readerIsKey }
}

@MainActor enum ReaderControlsChecks {
  static func run(directory: URL) async throws {
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      WelcomeStateChecks.expect(value(), message)
    }
    // A real native page controller, before the canvas has received any click.
    let controller = ReaderPageController()
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let window = ReaderKeyTestWindow(contentViewController: controller)
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    var page = 1
    var playbackKeys = 0
    controller.onKeyboardPage = { page = min(3, max(0, page + $0)) }
    controller.onTogglePlayback = { playbackKeys += 1 }
    controller.installScrollMonitor()
    func key(_ code: UInt16, in target: NSWindow? = nil,
             modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: (target ?? window).windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    NSApp.sendEvent(key(124))
    expect(page == 2 && window.deliveredKeys == 0,
           "local monitor consumes navigation once, before native responder dispatch")
    page = 1
    expect(window.isKeyWindow, "reader window is key before any canvas click")
    expect(controller.handleReaderKey(key(124)) == nil && page == 2, "right advances without image focus")
    expect(controller.handleReaderKey(key(125)) == nil && page == 3, "down advances")
    _ = controller.handleReaderKey(key(125))
    expect(page == 3, "last-page keyboard navigation stays in range")
    _ = controller.handleReaderKey(key(123)); _ = controller.handleReaderKey(key(126))
    expect(page == 1, "left and up each go to previous page")
    expect(controller.handleReaderKey(key(124, modifiers: .command)) != nil && page == 1,
           "modified shortcuts pass through")
    _ = controller.handleReaderKey(key(49))
    expect(playbackKeys == 1, "space controls video without video focus")
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView!.addSubview(editor)
    window.makeFirstResponder(editor)
    expect(controller.handleReaderKey(key(124)) != nil && page == 1,
           "text editing retains its arrow keys")
    window.makeFirstResponder(nil)
    window.readerIsKey = false
    expect(controller.handleReaderKey(key(124)) != nil && page == 1,
           "an inactive reader does not intercept navigation")
    window.readerIsKey = true
    let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    expect(controller.handleReaderKey(key(124, in: other)) != nil && page == 1,
           "unrelated windows retain their keys")
    let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    window.beginSheet(sheet, completionHandler: { _ in })
    expect(controller.handleReaderKey(key(124)) != nil && page == 1,
           "All Pages and other sheets retain their own keyboard navigation")
    window.endSheet(sheet)
    controller.removeScrollMonitor()
    window.close(); sheet.close(); other.close()

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let video = directory.appendingPathComponent("transport.mp4")
    try await makeVideo(video)
    let playback = ReaderVideoPlayback()
    await playback.load(video)
    expect(playback.ready && !playback.unsupported && playback.duration >= 2.9,
           "real MP4 loads into the reader's shared player")
    let canvas = ReaderVideoCanvas(player: playback.player)
    // Exercise the actual native view through a hosting controller.
    let host = NSHostingController(rootView: canvas)
    let videoWindow = NSWindow(contentViewController: host)
    videoWindow.isReleasedWhenClosed = false
    videoWindow.orderFront(nil)
    WelcomeStateChecks.drain()
    func nativePlayer(_ view: NSView) -> AVPlayerView? {
      if let view = view as? AVPlayerView { return view }
      return view.subviews.lazy.compactMap(nativePlayer).first
    }
    expect(nativePlayer(host.view)?.controlsStyle == AVPlayerViewControlsStyle.none,
           "AVKit renders media without a competing focus/hover control bar")
    playback.toggle()
    expect(playback.playing && playback.player.rate > 0, "overlay play works without video focus")
    playback.toggle()
    expect(!playback.playing && playback.player.rate == 0, "overlay pause works")
    playback.seek(1.5)
    expect(abs(playback.elapsed - 1.5) < 0.01, "shared seek position updates")
    playback.toggleMute()
    expect(playback.muted && playback.player.isMuted, "overlay mute controls actual player")
    playback.release(directory.appendingPathComponent("old.mp4"))
    expect(playback.ready, "old page teardown cannot stop a different active video")
    playback.release(video)
    expect(!playback.ready && playback.player.currentItem == nil && playback.player.rate == 0,
           "leaving video releases playback and transport state")
    let invalid = directory.appendingPathComponent("invalid.webm")
    try Data("invalid video".utf8).write(to: invalid)
    await playback.load(invalid)
    expect(!playback.ready && playback.unsupported, "unsupported media keeps explicit fallback")
    await playback.load(video)
    expect(playback.ready && !playback.unsupported, "valid media clears previous codec error")
    videoWindow.close()
    playback.reset()
    print("PASS: reader arrows work before canvas click; all four directions/bounds; text, sheets and other-window isolation; shared video play/pause/seek/mute, native controls suppression, release and codec recovery.")
  }

  // A tiny, valid local asset; no user media, NAS, external encoder or network.
  private static func makeVideo(_ url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<3 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      var buffer: CVPixelBuffer?
      CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer)
      guard let buffer else { fatalError("fixture pixel buffer") }
      CVPixelBufferLockBaseAddress(buffer, [])
      memset(CVPixelBufferGetBaseAddress(buffer), Int32(100 + index * 20), CVPixelBufferGetDataSize(buffer))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 1))
      else { throw writer.error! }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
    await writer.finishWriting()
    if let error = writer.error { throw error }
  }
}
