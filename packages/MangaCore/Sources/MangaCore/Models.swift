import Foundation

public enum EntityKind: String, Codable, CaseIterable, Sendable {
  case author, series, work, chapter, tag, storageRoot
}
public struct LocalizedText: Codable, Sendable, Equatable {
  public var title: String?
  public var description: String?
  public init(title: String? = nil, description: String? = nil) {
    self.title = title
    self.description = description
  }
}
public struct SourceLink: Codable, Sendable {
  public var site: String
  public var value: String
  public init(site: String, value: String) {
    self.site = site
    self.value = value
  }
}
public struct MediaVersion: Codable, Sendable, Identifiable {
  public var id: String
  public var language: String
  public var kind: String
  public var storageRootId: String
  public var relativePaths: [String]
  public var pageCount: Int
  public var pageAlignment: [Int?]?
  public init(
    id: String = UUID().uuidString.lowercased(), language: String, kind: String,
    storageRootId: String, relativePaths: [String], pageCount: Int
  ) {
    self.id = id
    self.language = language
    self.kind = kind
    self.storageRootId = storageRootId
    self.relativePaths = relativePaths
    self.pageCount = pageCount
  }
}
extension MediaVersion {
  public var languageLabel: String { language == "zxx" ? "No text" : language.uppercased() }
  /// Canonical page -> source page. Explicit missing entries fall back to original media.
  public func sourcePage(at canonical: Int) -> Int? {
    guard canonical >= 0 else { return nil }
    if let pageAlignment {
      guard canonical < pageAlignment.count, let index = pageAlignment[canonical], index >= 0,
        index < pageCount
      else { return nil }
      return index
    }
    return canonical < pageCount ? canonical : nil
  }
}
public struct MetadataInput: Codable, Sendable {
  public var kind: EntityKind
  public var title: String
  public var originalLanguage: String
  public var description: String
  public var localizations: [String: LocalizedText]
  public var authorId: String?
  public var seriesId: String?
  public var workId: String?
  public var tagIds: [String]
  public var nsfw: Bool
  public var sources: [SourceLink]
  public var media: [MediaVersion]
  public var storageKind: String?
  public init(
    kind: EntityKind, title: String, originalLanguage: String = "und", description: String = "",
    authorId: String? = nil, seriesId: String? = nil, workId: String? = nil,
    media: [MediaVersion] = [], storageKind: String? = nil
  ) {
    self.kind = kind
    self.title = title
    self.originalLanguage = originalLanguage
    self.description = description
    self.authorId = authorId
    self.seriesId = seriesId
    self.workId = workId
    self.media = media
    self.storageKind = storageKind
    localizations = [:]
    tagIds = []
    nsfw = false
    sources = []
  }
}
public struct LibraryEntity: Codable, Sendable, Identifiable {
  public var id: String
  public var kind: EntityKind
  public var title: String
  public var originalLanguage: String
  public var description: String
  public var localizations: [String: LocalizedText]
  public var authorId: String?
  public var seriesId: String?
  public var workId: String?
  public var tagIds: [String]
  public var nsfw: Bool
  public var sources: [SourceLink]
  public var media: [MediaVersion]
  public var storageKind: String?
  public var revision: Int
  public var updatedAt: String
  public var deleted: Bool
  public func title(in locale: String) -> String { localizations[locale]?.title ?? title }
  public func description(in locale: String) -> String {
    localizations[locale]?.description ?? description
  }
  public func preferredMedia(_ locale: String) -> MediaVersion? {
    media.first { $0.language == locale } ?? media.first { $0.language == originalLanguage }
      ?? media.first
  }
  public var input: MetadataInput {
    var v = MetadataInput(
      kind: kind, title: title, originalLanguage: originalLanguage, description: description,
      authorId: authorId, seriesId: seriesId, workId: workId, media: media, storageKind: storageKind
    )
    v.localizations = localizations
    v.tagIds = tagIds
    v.nsfw = nsfw
    v.sources = sources
    return v
  }
}
public struct ReadingProgress: Codable, Sendable {
  public var mediaId: String
  public var pageIndex: Int
  public var completed: Bool
  public var activeSeconds: Int
  public init(mediaId: String, pageIndex: Int, completed: Bool, activeSeconds: Int = 0) {
    self.mediaId = mediaId
    self.pageIndex = pageIndex
    self.completed = completed
    self.activeSeconds = activeSeconds
  }
}
public struct StateInput: Codable, Sendable {
  public var entityId: String
  public var pageIndex: Int?
  public var favorite: Bool
  public var starred: Bool
  public var progress: ReadingProgress?
  public init(
    entityId: String, pageIndex: Int? = nil, favorite: Bool = false, starred: Bool = false,
    progress: ReadingProgress? = nil
  ) {
    self.entityId = entityId
    self.pageIndex = pageIndex
    self.favorite = favorite
    self.starred = starred
    self.progress = progress
  }
}
public struct PersonalState: Codable, Sendable, Identifiable {
  public var id: String
  public var entityId: String
  public var pageIndex: Int?
  public var favorite: Bool
  public var starred: Bool
  public var progress: ReadingProgress?
  public var revision: Int
  public var updatedAt: String
}
public struct SyncSnapshot: Codable, Sendable {
  public var schemaVersion: Int
  public var entities: [LibraryEntity]
  public var states: [PersonalState]
}
public struct VerifiedAccount: Codable, Sendable {
  public var ownerId: String
  public var issuer: String
  public var subject: String
  public var scopes: [String]
}
public enum Visibility {
  public static func visible(_ entity: LibraryEntity, in entities: [LibraryEntity], showNSFW: Bool)
    -> Bool
  {
    guard !entity.deleted else { return false }
    if showNSFW { return true }
    var seen = Set<String>()
    func hidden(_ e: LibraryEntity) -> Bool {
      guard seen.insert(e.id).inserted else { return false }
      if e.nsfw { return true }
      let refs = e.tagIds + [e.authorId, e.seriesId, e.workId].compactMap { $0 }
      return refs.contains { id in
        entities.first(where: { $0.id == id && !$0.deleted }).map(hidden) ?? false
      }
    }
    return !hidden(entity)
  }
}

extension SourceLink {
  public static let supportedSites = ["pixiv", "fanbox", "patreon", "ehentai"]
  public static func nextUnusedSite(in links: [SourceLink]) -> String {
    supportedSites.first { site in !links.contains { $0.site == site } } ?? supportedSites[0]
  }
}
extension LibraryEntity {
  public var isArchiveDestination: Bool {
    kind == .storageRoot && !deleted
      && description != LibraryDestinationIdentity.sourceOnlyDescription
  }
}

public enum TagRemovalPlan {
  public static func updates(for tagId: String, entities: [LibraryEntity]) -> [(
    LibraryEntity, MetadataInput
  )] {
    entities.filter { !$0.deleted && $0.tagIds.contains(tagId) }.map { entity in
      var input = entity.input
      input.tagIds.removeAll { $0 == tagId }
      return (entity, input)
    }
  }
}

public enum AuthorRemovalPlan {
  /// Parents first, so each API write can validate the replacement hierarchy.
  /// Media paths and personal state references are intentionally preserved.
  public static func updates(
    for author: LibraryEntity, replacement: String,
    entities: [LibraryEntity]
  ) -> [(LibraryEntity, MetadataInput)] {
    guard author.kind == .author, !author.deleted, replacement != author.id else { return [] }
    func rank(_ kind: EntityKind) -> Int {
      switch kind {
      case .series: 0
      case .work: 1
      case .chapter: 2
      default: 3
      }
    }
    return entities.filter { !$0.deleted && $0.authorId == author.id }
      .sorted { rank($0.kind) == rank($1.kind) ? $0.id < $1.id : rank($0.kind) < rank($1.kind) }
      .map { entity in
        var input = entity.input
        input.authorId = replacement
        input.nsfw = input.nsfw || author.nsfw
        // Removing inherited author tags must not expose previously hidden comics.
        input.tagIds += author.tagIds.filter { !input.tagIds.contains($0) }
        return (entity, input)
      }
  }
}

public enum ComicDeletionPlan {
  public static func entities(for comic: LibraryEntity, in entities: [LibraryEntity])
    -> [LibraryEntity]
  {
    guard [.work, .chapter].contains(comic.kind), !comic.deleted else { return [] }
    if comic.kind == .chapter { return [comic] }
    return entities.filter { !$0.deleted && $0.kind == .chapter && $0.workId == comic.id } + [comic]
  }
  public static func exclusivePaths(
    _ media: MediaVersion, deleting ids: Set<String>, entities: [LibraryEntity]
  ) -> [String] {
    let shared = Set(
      entities.filter { !$0.deleted && !ids.contains($0.id) }.flatMap { $0.media }
        .filter { $0.storageRootId == media.storageRootId }.flatMap(\.relativePaths))
    let normalized = Set(shared.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
    return media.relativePaths.filter {
      !normalized.contains($0.precomposedStringWithCanonicalMapping.lowercased())
        && $0.contains("/")
    }
  }
}
