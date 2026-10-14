import MangaCore
import PDFKit
import SwiftUI

#if os(macOS)
  import AppKit
  struct NativeReadingPage: NSViewRepresentable {
    let url: URL
    var pdfPage: Int?
    var onSwipe: (Int) -> Void
    func makeNSView(context: Context) -> MacReadingViewport {
      let view = MacReadingViewport()
      view.set(url: url, page: pdfPage)
      view.onSwipe = nil
      return view
    }
    func updateNSView(_ view: MacReadingViewport, context: Context) {
      view.onSwipe = nil
      view.set(url: url, page: pdfPage)
    }
  }
  final class MacReadingViewport: NSView {
    let scroll = NSScrollView()
    let image = NSImageView()
    var pdf: PDFView?
    var currentURL: URL?
    var currentPage: Int?
    var sourcePDF: PDFDocument?
    var onSwipe: ((Int) -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame)
      scroll.drawsBackground = false
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
    func set(url: URL, page: Int?) {
      guard currentURL != url || currentPage != page else { return }
      currentURL = url
      currentPage = page
      if let page {
        if pdf == nil {
          pdf = PDFView()
          pdf!.backgroundColor = .black
          pdf!.displayMode = .singlePage
          addSubview(pdf!)
        }
        if sourcePDF?.documentURL != url { sourcePDF = PDFDocument(url: url) }
        if let selected = sourcePDF?.page(at: page)?.copy() as? PDFPage {
          let singlePage = PDFDocument()
          singlePage.insert(selected, at: 0)
          pdf?.document = singlePage
        } else {
          pdf?.document = nil
        }
        pdf?.isHidden = false
        scroll.isHidden = true
      } else {
        pdf?.isHidden = true
        scroll.isHidden = false
        image.image = NSImage(contentsOf: url)
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
      if let onSwipe, event.deltaX != 0 {
        onSwipe(event.deltaX > 0 ? -1 : 1)
      } else {
        super.swipe(with: event)
      }
    }
  }
#else
  import UIKit
  struct NativeReadingPage: UIViewRepresentable {
    let url: URL
    var pdfPage: Int?
    var onSwipe: (Int) -> Void
    func makeUIView(context: Context) -> PhoneReadingViewport {
      let view = PhoneReadingViewport()
      view.set(url: url, page: pdfPage)
      return view
    }
    func updateUIView(_ view: PhoneReadingViewport, context: Context) {
      view.set(url: url, page: pdfPage)
    }
  }
  final class PhoneReadingViewport: UIView, UIScrollViewDelegate {
    let scroll = UIScrollView()
    let image = UIImageView()
    var pdf: PDFView?
    var currentURL: URL?
    var currentPage: Int?
    var sourcePDF: PDFDocument?
    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
      scroll.delegate = self
      scroll.minimumZoomScale = 1
      scroll.maximumZoomScale = 6
      scroll.showsHorizontalScrollIndicator = false
      scroll.showsVerticalScrollIndicator = false
      image.contentMode = .scaleAspectFit
      scroll.addSubview(image)
      addSubview(scroll)
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom))
      doubleTap.numberOfTapsRequired = 2
      scroll.addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(url: URL, page: Int?) {
      guard currentURL != url || currentPage != page else { return }
      currentURL = url
      currentPage = page
      if let page {
        if pdf == nil {
          pdf = PDFView()
          pdf!.backgroundColor = .black
          pdf!.displayMode = .singlePage
          pdf!.usePageViewController(false)
          addSubview(pdf!)
        }
        if sourcePDF?.documentURL != url { sourcePDF = PDFDocument(url: url) }
        if let selected = sourcePDF?.page(at: page)?.copy() as? PDFPage {
          let singlePage = PDFDocument()
          singlePage.insert(selected, at: 0)
          pdf?.document = singlePage
        } else {
          pdf?.document = nil
        }
        pdf?.isHidden = false
        scroll.isHidden = true
      } else {
        scroll.isHidden = false
        pdf?.isHidden = true
        scroll.zoomScale = 1
        image.image = UIImage(contentsOfFile: url.path)
      }
      setNeedsLayout()
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      scroll.frame = bounds
      pdf?.frame = bounds
      if let page = pdf?.currentPage {
        let box = page.bounds(for: .mediaBox)
        if box.height > 0 { pdf?.scaleFactor = bounds.height / box.height }
      }
      if scroll.zoomScale == 1, let size = image.image?.size, size.height > 0 {
        let width = max(bounds.width, bounds.height * size.width / size.height)
        image.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.contentSize = image.frame.size
        scroll.contentOffset = CGPoint(x: max(0, (width - bounds.width) / 2), y: 0)
      }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    @objc func zoom() { scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2, animated: true) }
  }
#endif
