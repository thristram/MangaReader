import ImageIO
import MangaCore
import QuickLookThumbnailing

#if os(iOS)
  import UIKit
#endif

@MainActor final class CoverThumbnails {
  static let shared = CoverThumbnails()
  private let permits = AsyncPermitPool(limit: 2)
  private let decode: @Sendable (URL) throws -> CGImage?
  private var memoryWarningObserver: NSObjectProtocol?
  init(
    decode: @escaping @Sendable (URL) throws -> CGImage? = { try CoverThumbnails.decodeImage($0) }
  ) {
    self.decode = decode
    #if os(iOS)
      memoryWarningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.purge() }
      }
    #endif
  }
  deinit {
    if let memoryWarningObserver {
      NotificationCenter.default.removeObserver(memoryWarningObserver)
    }
  }
  func purge() { images.removeAllObjects() }
  nonisolated private static func decodeImage(_ url: URL) throws -> CGImage? {
    try Task.checkCancellation()
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 768,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
  private let images: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.countLimit = 128
    cache.totalCostLimit = 48 * 1024 * 1024
    return cache
  }()
  func image(at url: URL) async throws -> CGImage {
    try await permits.acquire()
    do {
      try Task.checkCancellation()
      let key = try await FileTasks.perform {
        // URL.resourceValues may retain attributes from before a download replaced this file.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return url.path + ":"
          + String((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
          + ":" + String((values[.size] as? NSNumber)?.intValue ?? 0)
      }
      if let image = images.object(forKey: key as NSString) {
        await permits.release()
        return image
      }
      let decode = decode
      let decoded = try await FileTasks.perform { try autoreleasepool { try decode(url) } }
      let image: CGImage
      if let decoded {
        image = decoded
      } else {
        try Task.checkCancellation()
        // System thumbnails remain the fallback for PDF and video covers.
        let request = QLThumbnailGenerator.Request(
          fileAt: url, size: CGSize(width: 550, height: 768), scale: 1,
          representationTypes: .thumbnail)
        image = try await withTaskCancellationHandler {
          try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } onCancel: {
          QLThumbnailGenerator.shared.cancel(request)
        }
      }
      try Task.checkCancellation()
      images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
      await permits.release()
      return image
    } catch {
      await permits.release()
      throw error
    }
  }
}
