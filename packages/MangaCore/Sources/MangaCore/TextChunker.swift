import Foundation
import CryptoKit

public enum TextChunkingError: Error, LocalizedError, Sendable {
  case sentenceTooLong(Int, Int)
  public var errorDescription: String? {
    switch self {
    case .sentenceTooLong(let count, let limit):
      return "A sentence has \(count) characters, exceeding the \(limit)-character chunk limit. Increase Maximum chunk characters or add a sentence/paragraph break. Nothing was truncated."
    }
  }
}

/// Lossless source partitioning. Chapter markers are hard boundaries; paragraphs
/// are preferred, and oversized paragraphs fall back to complete sentences.
public enum TextChunker {
  public static func chunks(_ source: String, maximum: Int) throws -> [String] {
    let limit = max(1, maximum)
    let regex = try NSRegularExpression(pattern: "\\[chapter:[^\\]\\r\\n]+\\]", options: .caseInsensitive)
    let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
    var starts = [source.startIndex]
    starts += matches.compactMap { Range($0.range, in: source)?.lowerBound }.filter { $0 != source.startIndex }
    starts.append(source.endIndex)
    var result: [String] = []
    for index in 0..<(starts.count - 1) {
      let section = String(source[starts[index]..<starts[index + 1]])
      var units: [String] = [], paragraph = ""
      for character in section {
        paragraph.append(character)
        if character.isNewline { units.append(paragraph); paragraph = "" }
      }
      if !paragraph.isEmpty { units.append(paragraph) }
      var packed = "", length = 0
      for unit in units {
        let pieces: [String]
        if unit.count <= limit { pieces = [unit] }
        else {
          var sentences: [String] = [], sentence = "", ended = false
          for character in unit {
            if ended && sentence.last == "." && character.isNumber { ended = false }
            if ended && !character.isWhitespace && !"」』”’\"）)]】。！？.!?…".contains(character) {
              sentences.append(sentence); sentence = ""; ended = false
            }
            sentence.append(character)
            if "。！？.!?…".contains(character) { ended = true }
          }
          if !sentence.isEmpty { sentences.append(sentence) }
          pieces = sentences
        }
        for piece in pieces {
          let count = piece.count
          guard count <= limit else { throw TextChunkingError.sentenceTooLong(count, limit) }
          if length + count > limit && !packed.isEmpty { result.append(packed); packed = ""; length = 0 }
          packed += piece; length += count
        }
      }
      if !packed.isEmpty { result.append(packed) }
    }
    return result
  }

  /// Display-only blocks are lossless and bounded even for unpunctuated text.
  public static func displayBlocks(_ text: String, maximum: Int = 1200) -> [String] {
    var blocks: [String] = [], block = "", count = 0
    for character in text {
      block.append(character); count += 1
      if count >= maximum || character.isNewline && count >= maximum / 2 {
        blocks.append(block); block = ""; count = 0
      }
    }
    if !block.isEmpty { blocks.append(block) }
    return blocks
  }
}

/// Account-scoped, bounded layout-input cache. Work runs on this actor, not the UI.
public actor DescriptionTextCache {
  public static let shared = DescriptionTextCache()
  private struct Entry { let blocks: [String]; let cost: Int; var used: Int }
  private var entries: [String: Entry] = [:]
  private var clock = 0
  private var cost = 0
  private let budget: Int
  public init(budget: Int = 8_000_000) { self.budget = max(0, budget) }
  public func blocks(_ text: String, owner: String) -> [String] {
    let key = owner + ":" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    clock += 1
    if var entry = entries[key] { entry.used = clock; entries[key] = entry; return entry.blocks }
    let blocks = TextChunker.displayBlocks(text)
    let bytes = text.utf8.count
    if bytes <= budget {
      while cost + bytes > budget || entries.count >= 32 {
        guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
        cost -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
      }
      entries[key] = Entry(blocks: blocks, cost: bytes, used: clock); cost += bytes
    }
    return blocks
  }
  public func removeAll() { entries = [:]; cost = 0 }
  public var entryCount: Int { entries.count }
}
