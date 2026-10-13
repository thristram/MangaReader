import AMSMB2
import CryptoKit
import Foundation
import MangaCore
import Security

struct SMBConnection: Codable, Sendable {
  var server: String
  var share: String
  var basePath: String
  var username: String
  var password: String
  var encrypted: Bool
}
@MainActor final class SMBMedia {
  let session: AppSession
  var working = false
  var progress: ((String) -> Void)?
  init(session: AppSession) { self.session = session }
  private func key(_ rootId: String) throws -> String {
    guard let owner = session.account?.ownerId else { throw LoginError.invalidToken }
    return "smb:\(owner):\(rootId)"
  }
  func configure(rootId: String, connection: SMBConnection) throws {
    guard let server = URL(string: connection.server), server.scheme == "smb", server.host != nil,
      server.user == nil, server.password == nil
    else { throw LoginError.server("Use smb://hostname without credentials in the URL.") }
    _ = try PathPolicy.component(connection.share)
    if !connection.basePath.isEmpty {
      _ = try PathPolicy.resolve(connection.basePath, under: URL(fileURLWithPath: "/virtual-root"))
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: CredentialKeychain.service,
      kSecAttrAccount as String: try key(rootId),
    ]
    let data = try JSONEncoder().encode(connection)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var q = query
      q[kSecValueData as String] = data
      q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let s = SecItemAdd(q as CFDictionary, nil)
      guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    } else if status != errSecSuccess {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }
  func connection(rootId: String) throws -> SMBConnection {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: CredentialKeychain.service,
      kSecAttrAccount as String: try key(rootId), kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data
    else { throw LoginError.server("Configure this chapter’s SMB root in Connections first.") }
    return try JSONDecoder().decode(SMBConnection.self, from: data)
  }
  private func directory(_ media: MediaVersion) throws -> URL {
    guard let dir = session.cacheDirectory else { throw LoginError.invalidToken }
    _ = try PathPolicy.component(media.id)
    return dir.appendingPathComponent("downloads/" + media.id, isDirectory: true)
  }
  private func fingerprint(_ media: MediaVersion) -> String {
    Base64URL.encode(
      Data(
        SHA256.hash(
          data: Data(
            (media.storageRootId + "\0" + media.relativePaths.joined(separator: "\0")).utf8))))
  }
  func downloadedURLs(_ media: MediaVersion) -> [URL]? {
    guard let dir = try? directory(media),
      let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
      let manifest = try? JSONDecoder().decode([String: String].self, from: data),
      manifest["fingerprint"] == fingerprint(media)
    else { return nil }
    let urls = media.relativePaths.enumerated().map {
      dir.appendingPathComponent(
        "\($0.offset)." + URL(fileURLWithPath: $0.element).pathExtension.lowercased())
    }
    guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
    return urls
  }
  func download(_ media: MediaVersion) async throws -> [URL] {
    if let urls = downloadedURLs(media) { return urls }
    guard !working else { throw LoginError.server("Another download is in progress.") }
    working = true
    defer { working = false }
    let owner = session.account?.ownerId
    let connection = try connection(rootId: media.storageRootId)
    guard let server = URL(string: connection.server),
      let client = SMB2Manager(
        url: server,
        credential: URLCredential(
          user: connection.username, password: connection.password, persistence: .forSession))
    else { throw LoginError.invalidConfiguration }
    client.timeout = 30
    try await client.connectShare(name: connection.share, encrypted: connection.encrypted)
    let dir = try directory(media)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var results: [URL] = []
    do {
      for (index, path) in media.relativePaths.enumerated() {
        guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
        try Task.checkCancellation()
        _ = try PathPolicy.resolve(path, under: URL(fileURLWithPath: "/virtual-root"))
        let remote = (connection.basePath.isEmpty ? "" : connection.basePath + "/") + path
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        _ = try PathPolicy.component(ext)
        let target = dir.appendingPathComponent("\(index)." + ext)
        let partial = dir.appendingPathComponent(UUID().uuidString + ".partial")
        progress?("Downloading \(index+1) of \(media.relativePaths.count)")
        do {
          try await client.downloadItem(
            atPath: remote, to: partial, progress: { _, _ in !Task.isCancelled })
          guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
          if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
          }
          try FileManager.default.moveItem(at: partial, to: target)
        } catch {
          try? FileManager.default.removeItem(at: partial)
          throw error
        }
        results.append(target)
      }
      guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
      try JSONEncoder().encode(["fingerprint": fingerprint(media)]).write(
        to: dir.appendingPathComponent("manifest.json"), options: .atomic)
      try await client.disconnectShare()
      return results
    } catch {
      try? await client.disconnectShare()
      throw error
    }
  }
  func deleteDownload(_ media: MediaVersion) throws {
    let dir = try directory(media)
    if FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.removeItem(at: dir)
    }
  }
  func chapters(for entity: LibraryEntity) -> [LibraryEntity] {
    let visible = session.visibleEntities(kind: .chapter)
    switch entity.kind {
    case .chapter: return [entity]
    case .author: return visible.filter { $0.authorId == entity.id }
    case .series: return visible.filter { $0.seriesId == entity.id }
    case .work: return visible.filter { $0.workId == entity.id }
    default: return []
    }
  }
  func download(_ entity: LibraryEntity) async throws {
    for chapter in chapters(for: entity) {
      guard let version = chapter.preferredMedia(AppConfiguration.preferredLanguage) else {
        continue
      }
      _ = try await download(version)
    }
  }
}
