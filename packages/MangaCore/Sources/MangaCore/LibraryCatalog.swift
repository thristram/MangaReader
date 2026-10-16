import Foundation

/// A snapshot index. Build once when metadata changes, rather than once per visible tile.
public struct LibraryCatalog: Sendable {
  public let entities: [LibraryEntity]
  private let byID: [String: LibraryEntity]
  private let hidden: Set<String>
  private let byKind: [EntityKind: [LibraryEntity]]
  private let chaptersByParent: [String: [LibraryEntity]]

  public init(_ source: [LibraryEntity]) {
    entities = source.filter { !$0.deleted }
    var ids: [String: LibraryEntity] = [:]
    var kinds: [EntityKind: [LibraryEntity]] = [:]
    var chapters: [String: [LibraryEntity]] = [:]
    var dependents: [String: [String]] = [:]
    var blocked = Set<String>()
    var queue: [String] = []
    for entity in entities {
      ids[entity.id] = entity
      kinds[entity.kind, default: []].append(entity)
      let parents = Set([entity.authorId, entity.seriesId, entity.workId].compactMap { $0 })
      for id in parents.union(entity.tagIds) { dependents[id, default: []].append(entity.id) }
      if entity.kind == .chapter {
        for id in parents { chapters[id, default: []].append(entity) }
      }
      if entity.nsfw {
        blocked.insert(entity.id)
        queue.append(entity.id)
      }
    }
    // Reverse propagation handles cycles without repeated ancestor walks.
    var index = 0
    while index < queue.count {
      for id in dependents[queue[index]] ?? [] where blocked.insert(id).inserted {
        queue.append(id)
      }
      index += 1
    }
    byID = ids
    byKind = kinds
    chaptersByParent = chapters
    hidden = blocked
  }
  public func entity(_ id: String?, showNSFW: Bool) -> LibraryEntity? {
    guard let id, showNSFW || !hidden.contains(id) else { return nil }
    return byID[id]
  }
  public func visible(kind: EntityKind? = nil, showNSFW: Bool) -> [LibraryEntity] {
    let result = kind.map { byKind[$0] ?? [] } ?? entities
    return showNSFW ? result : result.filter { !hidden.contains($0.id) }
  }
  public func search(kind: EntityKind, query: String, limit: Int, showNSFW: Bool) -> [LibraryEntity]
  {
    guard limit > 0 else { return [] }
    var matches: [LibraryEntity] = []
    for entity in byKind[kind] ?? [] {
      if !showNSFW && hidden.contains(entity.id) { continue }
      if query.isEmpty || entity.title.localizedCaseInsensitiveContains(query) {
        matches.append(entity)
        if matches.count == limit { break }
      }
    }
    return matches
  }
  public func chapters(for parent: LibraryEntity, showNSFW: Bool) -> [LibraryEntity] {
    if parent.kind == .chapter {
      return entity(parent.id, showNSFW: showNSFW).map { [$0] } ?? []
    }
    guard [.author, .series, .work].contains(parent.kind) else { return [] }
    let result = chaptersByParent[parent.id] ?? []
    return showNSFW ? result : result.filter { !hidden.contains($0.id) }
  }
}
