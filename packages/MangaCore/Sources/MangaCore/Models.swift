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
