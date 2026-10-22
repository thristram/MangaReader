import Foundation

public struct PageBatchPlan: Sendable {
  public let source: MediaVersion
  public let selectedIndices: [Int]
  public let selectedPaths: [String]
  public var metadata: MetadataInput
  public var translationId: String?
  public var originalCanonicalIndices: [Int]

  // Physical page indices in reading order, not click order or filename order.
  public static func readingOrder(_ media: MediaVersion) -> [Int] {
    var seen = Set<Int>()
    return (media.pageAlignment?.compactMap { $0 } ?? Array(0..<media.pageCount)).filter {
      media.relativePaths.indices.contains($0) && seen.insert($0).inserted
    }
  }

  public init(metadata input: MetadataInput, mediaId: String, selected requested: Set<Int>, removeEntireVersion: Bool = false) throws {
    guard input.kind == .chapter, let position = input.media.firstIndex(where: { $0.id == mediaId }),
      (input.media[position].kind == "images" || removeEntireVersion)
    else { throw LoginError.server("Select image pages from one media version.") }
    let source = input.media[position]
    let available = removeEntireVersion ? Array(source.relativePaths.indices) : Self.readingOrder(source)
    let selected = removeEntireVersion ? Set(available) : requested
    guard !selected.isEmpty, selected.isSubset(of: Set(available)) else {
      throw LoginError.server("Select image pages from one media version.")
    }
    self.source = source
    selectedIndices = available.filter { selected.contains($0) }
    selectedPaths = selectedIndices.map { source.relativePaths[$0] }
    metadata = input
    let original = input.media.first { $0.language == input.originalLanguage } ?? input.media[0]
    let canonicalCount = original.pageAlignment?.count ?? original.pageCount
    originalCanonicalIndices = Array(0..<canonicalCount)
    let retained = source.relativePaths.indices.filter { !selected.contains($0) }
    let renumber = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.element, $0.offset) })
    if source.id == original.id {
      originalCanonicalIndices = originalCanonicalIndices.filter {
        original.sourcePage(at: $0).map { !selected.contains($0) } ?? false
      }
      for index in metadata.media.indices where index != position {
        metadata.media[index].pageAlignment = originalCanonicalIndices.map { input.media[index].sourcePage(at: $0) }
      }
    }
    if retained.isEmpty {
      metadata.media.remove(at: position)
      if source.id == original.id, let replacement = metadata.media.first {
        let previous = input.media.first { $0.id == replacement.id }!
        originalCanonicalIndices = Array(0..<canonicalCount).filter { previous.sourcePage(at: $0) != nil }
        for index in metadata.media.indices {
          let prior = input.media.first { $0.id == metadata.media[index].id }!
          metadata.media[index].pageAlignment = originalCanonicalIndices.map { prior.sourcePage(at: $0) }
        }
      }
    } else {
      metadata.media[position].relativePaths = retained.map { source.relativePaths[$0] }
      metadata.media[position].pageCount = retained.count
      let canonical = source.id == original.id ? originalCanonicalIndices
        : Array(0..<(source.pageAlignment?.count ?? canonicalCount))
      metadata.media[position].pageAlignment = canonical.map {
        source.sourcePage(at: $0).flatMap { renumber[$0] }
      }
    }
  }

  public mutating func setTranslation(language: String, alignment: [Int?], id: String = UUID().uuidString.lowercased()) throws {
    let language = try PathPolicy.component(language).lowercased()
    guard !metadata.media.isEmpty,
      !metadata.media.contains(where: { $0.language.lowercased() == language }),
      language != source.language.lowercased()
    else { throw LoginError.server("Keep some source pages and choose a new media language.") }
    let original = metadata.media.first { $0.language == metadata.originalLanguage } ?? metadata.media[0]
    let count = original.pageAlignment?.count ?? original.pageCount
    guard alignment.count == count,
      alignment.allSatisfy({ $0 == nil || (0..<selectedIndices.count).contains($0!) })
    else { throw LoginError.server("Review the page alignment before committing.") }
    var translation = MediaVersion(id: id, language: language, kind: "images",
      storageRootId: source.storageRootId, relativePaths: selectedPaths, pageCount: selectedPaths.count)
    translation.pageAlignment = alignment
    metadata.media.append(translation)
    translationId = translation.id
  }
}

/// Append physical image files while preserving each version's existing reading order.
public struct PageAppendPlan: Sendable {
  public var metadata: MetadataInput
  public let mediaId: String
  public init(metadata input: MetadataInput, language: String, rootId: String, paths: [String]) throws {
    let language = try PathPolicy.component(language).lowercased()
    guard input.kind == .chapter, !paths.isEmpty else { throw StorageError.emptyChapter }
    metadata = input
    if let index = metadata.media.firstIndex(where: { $0.language.lowercased() == language }) {
      guard metadata.media[index].kind == "images" else {
        throw LoginError.server("That language contains PDF or video content. Choose another media language for images.")
      }
      let old = metadata.media[index]
      guard old.storageRootId == rootId else { throw StorageError.unsafePath }
      metadata.media[index].relativePaths += paths
      metadata.media[index].pageCount += paths.count
      let order = old.pageAlignment ?? (0..<old.pageCount).map { Optional($0) }
      metadata.media[index].pageAlignment = order + (old.pageCount..<(old.pageCount + paths.count)).map { Optional($0) }
      mediaId = old.id
    } else {
      let media = MediaVersion(language: language, kind: "images", storageRootId: rootId,
        relativePaths: paths, pageCount: paths.count)
      metadata.media.append(media)
      mediaId = media.id
    }
    let count = metadata.media.map { $0.pageAlignment?.count ?? $0.pageCount }.max() ?? 0
    for index in metadata.media.indices {
      let media = metadata.media[index]
      let order = media.pageAlignment ?? (0..<media.pageCount).map { Optional($0) }
      metadata.media[index].pageAlignment = order + Array(repeating: nil, count: max(0, count - order.count))
    }
  }
}
