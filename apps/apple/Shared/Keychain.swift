import Foundation
import MangaCore
import Security

struct CredentialKeychain {
  static var service: String { Bundle.main.bundleIdentifier ?? "com.thristram.mangareader" }
  static func read() -> StoredCredentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "oauth", kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return try? JSONDecoder().decode(StoredCredentials.self, from: data)
  }
  static func save(_ credentials: StoredCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "oauth",
    ]
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var insert = query
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let result = SecItemAdd(insert as CFDictionary, nil)
      guard result == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
      }
    } else if status != errSecSuccess {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }
  static func clear() {
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: "oauth",
      ] as CFDictionary)
  }
}
