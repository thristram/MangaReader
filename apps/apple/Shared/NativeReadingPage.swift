import ImageIO
import MangaCore
import PDFKit
import SwiftUI

// The worker creates these objects and hands them to the main actor once. A PDF
// document is never shared between the worker and the displayed PDFView.
enum DecodedReadingPage: @unchecked Sendable {
  case image(CGImage)
  case pdf(PDFDocument)

  var aspect: Double {
    switch self {
    case .image(let image): return Double(image.width) / Double(max(1, image.height))
    case .pdf(let document):
      let box = document.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
      return box.height > 0 ? Double(box.width / box.height) : 0.7
    }
  }
}

enum ReadingPageDecodingError: LocalizedError {
  case invalidImage, invalidPDF, missingPage
  var errorDescription: String? {
    switch self {
    case .invalidImage: return "This image could not be read. Check the file and try again."
    case .invalidPDF: return "This PDF could not be read. Check the file and try again."
    case .missingPage: return "This PDF page is unavailable."
    }
  }
}

enum ReadingPageDecoder {
  // Bound decoded memory by pixel count, not the longest edge: long strips keep
  // their readable width. Original files and exports are never modified.
  static let maximumPixels = 24_000_000.0
  static func load(url: URL, pdfPage: Int?) async throws -> DecodedReadingPage {
    try await FileTasks.perform {
      try Task.checkCancellation()
      if let pdfPage {
        guard let source = PDFDocument(url: url) else {
          throw ReadingPageDecodingError.invalidPDF
        }
        guard pdfPage >= 0, let page = source.page(at: pdfPage)?.copy() as? PDFPage else {
          throw ReadingPageDecodingError.missingPage
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        // Materialize just this page on the worker. The displayed PDF must have
        // no lazy file-backed streams that could contact a NAS during drawing.
        guard let data = document.dataRepresentation(), let detached = PDFDocument(data: data)
        else {
          throw ReadingPageDecodingError.invalidPDF
        }
        _ = detached.page(at: 0)?.bounds(for: .mediaBox)
        try Task.checkCancellation()
        return .pdf(detached)
      }
      guard
        let source = CGImageSourceCreateWithURL(
          url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { throw ReadingPageDecodingError.invalidImage }
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
      let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
      let scale = min(1, sqrt(maximumPixels / max(1, width * height)))
      let edge = max(1, Int(max(width, height) * scale))
      guard
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw ReadingPageDecodingError.invalidImage }
      try Task.checkCancellation()
      return .image(image)
    }
  }
}

struct NativeReadingPage: View {
  let url: URL
  var pdfPage: Int?
  var onSwipe: (Int) -> Void
  var isCurrent = true
  var onAspect: (Double) -> Void = { _ in }
  var decode: @Sendable (URL, Int?) async throws -> DecodedReadingPage = {
    try await ReadingPageDecoder.load(url: $0, pdfPage: $1)
  }
  @State private var content: DecodedReadingPage?
  @State private var error = ""
  @State private var retry = 0
  @State private var loadedRequest: Request?
  private struct Request: Hashable {
    let url: URL
    let page: Int?
    let retry: Int
  }
  var body: some View {
    Group {
      if let content {
        DecodedPageViewport(content: content)
      } else if !error.isEmpty {
        VStack(spacing: 12) {
          Text(error).font(.callout).multilineTextAlignment(.center)
          Button("Retry") { retry += 1 }
        }.padding(24)
      } else {
        ProgressView("Loading page…")
      }
    }
    .task(id: Request(url: url, page: pdfPage, retry: retry)) {
      let request = Request(url: url, page: pdfPage, retry: retry)
      if loadedRequest == request, let content {
        if isCurrent { onAspect(content.aspect) }
        return
      }
      content = nil
      error = ""
      do {
        let result = try await decode(url, pdfPage)
        try Task.checkCancellation()
        content = result
        loadedRequest = request
        onAspect(result.aspect)
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
    .onChange(of: isCurrent) { _, current in
      if current, let content { onAspect(content.aspect) }
    }
  }
}

#if os(macOS)
  import AppKit
  private struct DecodedPageViewport: NSViewRepresentable {
    let content: DecodedReadingPage
    func makeNSView(context: Context) -> MacReadingViewport {
      let view = MacReadingViewport()
      view.set(content: content)
      return view
    }
    func updateNSView(_ view: MacReadingViewport, context: Context) {
      view.set(content: content)
    }
  }
  final class MacReadingViewport: NSView {
    let scroll = NSScrollView()
    let image = NSImageView()
    var pdf: PDFView?
    private var currentImage: CGImage?
    private var currentPDF: PDFDocument?
    override init(frame: NSRect) {
      super.init(frame: frame)
      scroll.drawsBackground = false
      scroll.focusRingType = .none
      image.focusRingType = .none
      scroll.allowsMagnification = true
      scroll.minMagnification = 1
      scroll.maxMagnification = 6
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      image.imageScaling = .scaleProportionallyUpOrDown
      scroll.documentView = image
      addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(content: DecodedReadingPage) {
      switch content {
      case .pdf(let document):
        guard currentPDF !== document else { return }
        currentPDF = document
        currentImage = nil
        image.image = nil
        if pdf == nil {
          pdf = PDFView()
          pdf!.focusRingType = .none
          pdf!.backgroundColor = .black
          pdf!.displayMode = .singlePage
          addSubview(pdf!)
        }
        pdf?.document = document
        pdf?.isHidden = false
        scroll.isHidden = true
      case .image(let decoded):
        guard currentImage !== decoded else { return }
        currentImage = decoded
        currentPDF = nil
        pdf?.document = nil
        pdf?.isHidden = true
        scroll.isHidden = false
        image.image = NSImage(cgImage: decoded, size: .zero)
        scroll.magnification = 1
      }
      needsLayout = true
    }
    override func layout() {
      super.layout()
      scroll.frame = bounds
      pdf?.frame = bounds
      if let page = pdf?.currentPage {
        let box = page.bounds(for: .mediaBox)
        if box.height > 0 { pdf?.scaleFactor = bounds.height / box.height }
      }
      if let size = image.image?.size, size.height > 0 {
        let width = max(bounds.width, bounds.height * size.width / size.height)
        image.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
      }
    }
    override func swipe(with event: NSEvent) {
      guard scroll.magnification <= 1.01 else { return }
      super.swipe(with: event)
    }
  }
#else
  import UIKit
  private struct DecodedPageViewport: UIViewRepresentable {
    let content: DecodedReadingPage
    func makeUIView(context: Context) -> PhoneReadingViewport {
      let view = PhoneReadingViewport()
      view.set(content: content)
      return view
    }
    func updateUIView(_ view: PhoneReadingViewport, context: Context) {
      view.set(content: content)
    }
  }
  final class PhoneReadingViewport: UIView, UIScrollViewDelegate {
    let scroll = ReadingImageScrollView()
    let image = UIImageView()
    var pdf: PDFView?
    private var currentImage: CGImage?
    private var currentPDF: PDFDocument?
    private var laidOutSize = CGSize.zero
    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
      scroll.delegate = self
      scroll.minimumZoomScale = 1
      scroll.maximumZoomScale = 6
      scroll.contentInsetAdjustmentBehavior = .never
      scroll.alwaysBounceHorizontal = false
      scroll.alwaysBounceVertical = false
      scroll.showsHorizontalScrollIndicator = false
      scroll.showsVerticalScrollIndicator = false
      image.contentMode = .scaleAspectFit
      scroll.addSubview(image)
      addSubview(scroll)
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:)))
      doubleTap.numberOfTapsRequired = 2
      scroll.addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(content: DecodedReadingPage) {
      switch content {
      case .pdf(let document):
        guard currentPDF !== document else { return }
        currentPDF = document
        currentImage = nil
        image.image = nil
        if pdf == nil {
          pdf = PDFView()
          pdf!.backgroundColor = .black
          pdf!.displayMode = .singlePage
          pdf!.displaysPageBreaks = false
          pdf!.usePageViewController(false)
          addSubview(pdf!)
          NotificationCenter.default.addObserver(
            self, selector: #selector(pdfScaleChanged), name: .PDFViewScaleChanged, object: pdf!)
        }
        pdf?.document = document
        pdf?.isHidden = false
        scroll.isHidden = true
      case .image(let decoded):
        guard currentImage !== decoded else { return }
        currentImage = decoded
        currentPDF = nil
        pdf?.document = nil
        scroll.isHidden = false
        pdf?.isHidden = true
        scroll.zoomScale = 1
        image.image = UIImage(cgImage: decoded)
      }
      laidOutSize = .zero
      setNeedsLayout()
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      scroll.frame = bounds
      pdf?.frame = bounds
      guard bounds.width > 0, bounds.height > 0 else { return }
      if laidOutSize != bounds.size {
        laidOutSize = bounds.size
        if let pdf, currentPDF != nil {
          pdf.autoScales = true
          pdf.layoutIfNeeded()
          let fit = pdf.scaleFactorForSizeToFit
          if fit > 0 {
            pdf.minScaleFactor = fit
            pdf.maxScaleFactor = fit * 6
            pdf.scaleFactor = fit
          }
        }
        if let size = image.image?.size, size.width > 0, size.height > 0 {
          // Minimum zoom always contains the entire page, including wide spreads.
          // Only an explicit pinch/double-tap may crop the page to fill the screen.
          scroll.zoomScale = 1
          let fit = min(bounds.width / size.width, bounds.height / size.height)
          image.frame = CGRect(origin: .zero, size: CGSize(width: size.width * fit, height: size.height * fit))
          scroll.contentSize = image.bounds.size
          centerImage()
          scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
        }
      }
      configurePDFScrolling()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
    private func centerImage() {
      let horizontal = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
      let vertical = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
      scroll.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
    @objc private func pdfScaleChanged() { configurePDFScrolling() }
    private func configurePDFScrolling() {
      guard let pdf, !pdf.isHidden else { return }
      func configure(_ view: UIView) {
        if let inner = view as? UIScrollView {
          inner.contentInsetAdjustmentBehavior = .never
          // At fit scale the outer UIKit pager owns horizontal drags; PDFKit
          // keeps its pinch recognizer and regains panning once zoomed in.
          inner.panGestureRecognizer.isEnabled = pdf.scaleFactor > pdf.minScaleFactor * 1.01
        }
        view.subviews.forEach(configure)
      }
      configure(pdf)
    }
    @objc func zoom(_ gesture: UITapGestureRecognizer) {
      if scroll.zoomScale > 1.01 {
        scroll.setZoomScale(1, animated: true)
      } else {
        let point = gesture.location(in: image)
        let fill = max(scroll.bounds.width / max(1, image.bounds.width), scroll.bounds.height / max(1, image.bounds.height))
        let scale = min(scroll.maximumZoomScale, max(2, fill))
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height), animated: true)
      }
    }
  }
  // Do not compete with the page controller for a drag when the whole image
  // already fits. Pinch and double-tap zoom remain enabled at minimum scale.
  final class ReadingImageScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer === panGestureRecognizer, zoomScale <= minimumZoomScale * 1.01 { return false }
      return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
  }
#endif
