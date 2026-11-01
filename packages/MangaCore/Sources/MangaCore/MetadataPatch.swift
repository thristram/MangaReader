import Foundation

/// Generates bounded RFC 6902 add/remove/replace operations. The server validates
/// and applies them with fast-json-patch and the full metadata schema/CAS guard.
public enum MetadataPatch {
  public static func data(from before: MetadataInput, to after: MetadataInput) throws -> Data {
    let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(before))
    let new = try JSONSerialization.jsonObject(with: JSONEncoder().encode(after))
    func equal(_ lhs: Any, _ rhs: Any) -> Bool { (lhs as? NSObject)?.isEqual(rhs) == true }
    func bytes(_ value: Any) throws -> Data {
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    func escaped(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    func diff(_ lhs: Any, _ rhs: Any, _ path: String) throws -> [[String: Any]] {
      if equal(lhs, rhs) { return [] }
      var operations: [[String: Any]] = []
      if let a = lhs as? [String: Any], let b = rhs as? [String: Any] {
        for key in a.keys.sorted() where b[key] == nil { operations.append(["op": "remove", "path": path + "/" + escaped(key)]) }
        for key in b.keys.sorted() {
          let child = path + "/" + escaped(key)
          if let original = a[key] { operations += try diff(original, b[key]!, child) }
          else { operations.append(["op": "add", "path": child, "value": b[key]!]) }
        }
      } else if let a = lhs as? [Any], let b = rhs as? [Any] {
        for i in 0..<min(a.count, b.count) { operations += try diff(a[i], b[i], path + "/\(i)") }
        if a.count > b.count {
          for i in stride(from: a.count - 1, through: b.count, by: -1) { operations.append(["op": "remove", "path": path + "/\(i)"]) }
        }
        if b.count > a.count {
          for i in a.count..<b.count { operations.append(["op": "add", "path": path + "/-", "value": b[i]]) }
        }
      } else { return [["op": "replace", "path": path, "value": rhs]] }
      // Dense reorders/renames are cheaper as a replacement of just that field.
      if !path.isEmpty {
        let replacement: [[String: Any]] = [["op": "replace", "path": path, "value": rhs]]
        if try bytes(replacement).count < bytes(operations).count { return replacement }
      }
      return operations
    }
    return try bytes(diff(old, new, ""))
  }
}
