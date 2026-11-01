import Foundation

public enum MetadataHierarchy {
  public enum SelectionError: Error, LocalizedError {
    case unavailable
    public var errorDescription: String? {
      "The selected collection is unavailable. Choose it again."
    }
  }
  public static func normalized(_ input: MetadataInput, entities: [LibraryEntity]) throws
    -> MetadataInput
  {
    var result = input
    func parent(_ id: String, _ kind: EntityKind) throws -> LibraryEntity {
      guard let value = entities.first(where: { $0.id == id && !$0.deleted && $0.kind == kind })
      else { throw SelectionError.unavailable }
      return value
    }
    if result.kind == .chapter, let id = result.workId {
      let work = try parent(id, .work)
      result.authorId = work.authorId
      result.seriesId = work.seriesId
    } else if [.chapter, .work].contains(result.kind), let id = result.seriesId {
      result.authorId = try parent(id, .series).authorId
    }
    return result
  }
  public static func selecting(
    _ kind: EntityKind, id: String?, in input: MetadataInput,
    entities: [LibraryEntity]
  ) throws -> MetadataInput {
    var result = input
    let chosen = id.flatMap { id in entities.first { $0.id == id && !$0.deleted && $0.kind == kind }
    }
    guard id == nil || chosen != nil else { throw SelectionError.unavailable }
    switch kind {
    case .work:
      result.workId = id
    case .series:
      result.seriesId = id
      if let chosen { result.authorId = chosen.authorId }
      if let work = entities.first(where: { $0.id == result.workId }),
        work.seriesId != result.seriesId || work.authorId != result.authorId
      {
        result.workId = nil
      }
    case .author:
      result.authorId = id
      if let series = entities.first(where: { $0.id == result.seriesId }), series.authorId != id {
        result.seriesId = nil
      }
      if let work = entities.first(where: { $0.id == result.workId }), work.authorId != id {
        result.workId = nil
      }
    default: break
    }
    return try normalized(result, entities: entities)
  }
}
