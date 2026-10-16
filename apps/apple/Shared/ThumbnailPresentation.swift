import Combine
import CoreGraphics
import Foundation

/// Lazy grids can retain view state after a cell leaves the screen. Release the
/// displayed bitmap explicitly, independently of the shared thumbnail cache.
@MainActor final class ThumbnailPresentation: ObservableObject {
  @Published private(set) var image: CGImage?
  @Published private(set) var loading = false
  private var generation = UUID()
  private let loadImage: @MainActor (URL) async throws -> CGImage
  init(
    loadImage: @escaping @MainActor (URL) async throws -> CGImage = {
      try await CoverThumbnails.shared.image(at: $0)
    }
  ) { self.loadImage = loadImage }
  func clear() {
    generation = UUID()
    image = nil
    loading = false
  }
  func load(_ url: URL?) async {
    clear()
    guard let url else { return }
    let request = generation
    loading = true
    let result = try? await loadImage(url)
    guard generation == request, !Task.isCancelled else { return }
    image = result
    loading = false
  }
}
