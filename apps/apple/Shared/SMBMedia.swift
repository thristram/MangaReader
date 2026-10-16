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
  var destinationVerified: Bool? = nil
  var encrypted: Bool
}
enum SMBConnectionStage: String {
  case network = "Waiting for NAS network access"
  case connecting = "Connecting to the encrypted SMB3 share"
  case folder = "Checking the library folder"
  case identity = "Verifying the library"
  case initializing = "Initializing the library folder"
  case saving = "Saving this device's connection"
}
struct SMBConnectionFailure: LocalizedError {
  let stage: SMBConnectionStage
  let underlying: NSError
  init(stage: SMBConnectionStage, error: Error) {
    self.stage = stage
    underlying = error as NSError
  }
  var errorDescription: String? {
    let detail = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let codeOnly = "Error code \(underlying.code):"
    let explanation =
      detail.isEmpty || detail == codeOnly
      ? "The SMB client returned no further detail." : detail
    return stage.rawValue + " failed. " + explanation
      + " (\(underlying.domain), \(underlying.code))"
  }
}
private final class TransferCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  func cancel() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}
@MainActor final class SMBMedia {
  private var checkedServers = Set<String>()
  let session: AppSession
  init(session: AppSession) { self.session = session }
  var working = false
  private var transferring: Set<String> = []
  private var availability: [String: Bool] = [:]
  private var checking: Set<String> = []
  private let cacheChecks = AsyncPermitPool(limit: 4)
  private var availabilityEpoch = UUID()
  private let pagePermits = AsyncPermitPool(limit: 3)
  private let bulkPermits = AsyncPermitPool(limit: 1)
  private let manifestStore = DownloadManifestStore()
  private let directoryListings = SMBDirectoryListings()
  private var manifests: [String: Set<Int>] = [:]
  private var signatures: [String: (String, [String], String)] = [:]
  var availabilityChanged: (() -> Void)?
  func resetAvailability() {
    availabilityEpoch = UUID()
    availability = [:]
    checking = []
    manifests = [:]
    signatures = [:]
  }
  func isDownloaded(_ media: MediaVersion) -> Bool {
    guard let directory = try? directory(media) else { return false }
    let key = directory.path + fingerprint(media)
    if let value = availability[key] { return value }
    if checking.insert(key).inserted {
      let fingerprint = fingerprint(media)
      let epoch = availabilityEpoch
      Task {
        do { try await cacheChecks.acquire() } catch { return }
        defer { Task { await cacheChecks.release() } }
        guard epoch == availabilityEpoch else { return }
        let complete =
          (try? await FileTasks.perform {
            guard
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data),
              manifest["fingerprint"] == fingerprint,
              manifest["files"] == nil
                || manifest["files"]?.split(separator: ",").count == media.relativePaths.count
            else { return false }
            return media.relativePaths.enumerated().allSatisfy { index, path in
              FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                  "\(index)." + URL(fileURLWithPath: path).pathExtension.lowercased()
                ).path)
            }
          }) ?? false
        guard (try? self.directory(media)) == directory, checking.contains(key),
          epoch == availabilityEpoch
        else { return }
        checking.remove(key)
        if availability[key] == nil {
          availability[key] = complete
          if complete { availabilityChanged?() }
        }
      }
    }
    return false
  }
  func cachedPage(_ media: MediaVersion, index: Int) async throws -> URL? {
    guard media.relativePaths.indices.contains(index) else { return nil }
    let directory = try directory(media)
    let fingerprint = fingerprint(media)
    let key = directory.path + fingerprint
    if manifests[key] == nil {
      let loaded = try await FileTasks.perform { () -> Set<Int> in
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
          let manifest = try? JSONDecoder().decode([String: String].self, from: data),
          manifest["fingerprint"] == fingerprint
        else { return [] }
        return manifest["files"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
          ?? Set(media.relativePaths.indices)
      }
      guard (try? self.directory(media)) == directory else { throw LoginError.invalidToken }
      if manifests[key] == nil { manifests[key] = loaded }
    }
    guard manifests[key]?.contains(index) == true else { return nil }
    let url = directory.appendingPathComponent(
      "\(index)." + URL(fileURLWithPath: media.relativePaths[index]).pathExtension.lowercased())
    return try await FileTasks.perform {
      FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
  }
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
      _ = try SMBReadPath.components(connection.basePath)
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
  func configureValidated(
    root: LibraryEntity, connection: SMBConnection, initialize: Bool,
    onProgress: ((String) -> Void)? = nil
  )
    async throws
  {
    guard let owner = session.account?.ownerId else { throw LoginError.invalidToken }
    #if os(macOS)
      let mayInitialize = initialize && session.account?.scopes.contains("manga:manage") == true
    #else
      let mayInitialize = false
    #endif
    guard !initialize || mayInitialize else {
      throw LoginError.server(
        "Initialize a new library folder on your Mac, then connect to it here.")
    }
    let client = try makeClient(connection)
    var stage = SMBConnectionStage.connecting
    func report(_ next: SMBConnectionStage) {
      stage = next
      onProgress?(next.rawValue + "…")
    }
    do {
      report(.network)
      try await checkNetwork(connection)
      report(.connecting)
      try await client.connectShare(name: connection.share, encrypted: connection.encrypted)
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      report(.folder)
      let folder = try await client.attributesOfItem(
        atPath: connection.basePath.isEmpty ? "/" : connection.basePath)
      guard folder[.fileResourceTypeKey] as? URLFileResourceType == .directory else {
        throw LoginError.server(
          "Base folder must point to your library directory inside the share.")
      }
      if root.isArchiveDestination {
        report(.identity)
        let path =
          (connection.basePath.isEmpty ? "" : connection.basePath + "/")
          + LibraryDestinationIdentity.filename
        var exists = true
        do { _ = try await client.attributesOfItem(atPath: path) } catch POSIXError.ENOENT {
          exists = false
        }
        if !exists {
          guard mayInitialize else {
            throw LoginError.server(
              "This is not the library folder initialized on your Mac. Check the share and base folder, or initialize a new destination on your Mac."
            )
          }
          guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
          report(.initializing)
          try await client.write(
            data: JSONEncoder().encode(
              LibraryDestinationIdentity(libraryId: owner, destinationId: root.id)), toPath: path,
            progress: nil)
        }
        report(.identity)
        try await validateMarker(client, connection: connection, libraryId: owner, rootId: root.id)
      }
      guard owner == session.account?.ownerId else { throw LoginError.invalidToken }
      report(.saving)
      var validated = connection
      validated.destinationVerified = root.isArchiveDestination
      try configure(rootId: root.id, connection: validated)
      // Cleanup failure must not turn an already saved, verified connection
      // into a misleading connection failure.
      try? await client.disconnectShare()
    } catch {
      let failure = SMBConnectionFailure(stage: stage, error: error)
      try? await client.disconnectShare()
      throw failure
    }
  }
  private func makeClient(_ connection: SMBConnection) throws -> SMB2Manager {
    guard let server = URL(string: connection.server), server.scheme == "smb", server.host != nil,
      server.user == nil, server.password == nil,
      let client = SMB2Manager(
        url: server,
        credential: URLCredential(
          user: connection.username,
          password: connection.password, persistence: .forSession))
    else { throw LoginError.invalidConfiguration }
    _ = try PathPolicy.component(connection.share)
    if !connection.basePath.isEmpty {
      _ = try SMBReadPath.components(connection.basePath)
    }
    client.timeout = 30
    return client
  }
  private func checkNetwork(_ connection: SMBConnection) async throws {
    guard let server = URL(string: connection.server) else { throw LoginError.invalidConfiguration }
    let key = (server.host ?? "") + ":" + String(server.port ?? 445)
    if checkedServers.contains(key) { return }
    try await SMBNetworkAccess.check(server)
    checkedServers.insert(key)
  }
  private func validateMarker(
    _ client: SMB2Manager, connection: SMBConnection, libraryId: String, rootId: String
  ) async throws {
    let path =
      (connection.basePath.isEmpty ? "" : connection.basePath + "/")
      + LibraryDestinationIdentity.filename
    var data = Data()
    for try await chunk in client.contents(atPath: path, range: 0..<4096) { data.append(chunk) }
    try JSONDecoder().decode(LibraryDestinationIdentity.self, from: data).validate(
      libraryId: libraryId, destinationId: rootId)
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
    if let signature = signatures[media.id], signature.0 == media.storageRootId,
      signature.1 == media.relativePaths
    {
      return signature.2
    }
    let value = Base64URL.encode(
      Data(
        SHA256.hash(
          data: Data(
            (media.storageRootId + "\0" + media.relativePaths.joined(separator: "\0")).utf8))))
    signatures[media.id] = (media.storageRootId, media.relativePaths, value)
    return value
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
    guard manifest["files"] == nil || manifest["files"]?.split(separator: ",").count == urls.count
    else { return nil }
    guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
    return urls
  }
  func download(
    _ media: MediaVersion, localURLs: [URL]? = nil, indices: [Int]? = nil,
    onProgress: (@MainActor @Sendable (Double, String) -> Void)? = nil
  ) async throws -> [URL] {
    let permits = indices == nil ? bulkPermits : pagePermits
    try await permits.acquire()
    defer { Task { await permits.release() } }
    try Task.checkCancellation()
    if indices == nil { working = true }
    defer { if indices == nil { working = false } }
    guard let owner = session.account?.ownerId else { throw LoginError.invalidToken }
    var client: SMB2Manager?
    var connection: SMBConnection?
    let requested = indices ?? Array(media.relativePaths.indices)
    var existing: [URL] = []
    for index in requested {
      guard media.relativePaths.indices.contains(index) else { throw StorageError.emptyChapter }
      if let url = try await cachedPage(media, index: index) { existing.append(url) } else { break }
    }
    if existing.count == requested.count {
      onProgress?(1, "Available offline")
      return existing
    }
    if localURLs == nil {
      let configuration = try self.connection(rootId: media.storageRootId)
      let remote = try makeClient(configuration)
      do { try await checkNetwork(configuration) } catch {
        throw SMBConnectionFailure(stage: .network, error: error)
      }
      do {
        try await remote.connectShare(name: configuration.share, encrypted: configuration.encrypted)
      } catch {
        throw SMBConnectionFailure(stage: .connecting, error: error)
      }
      do {
        do {
          try await validateMarker(
            remote, connection: configuration, libraryId: owner, rootId: media.storageRootId)
        } catch POSIXError.ENOENT {
          // Existing source connections remain readable until explicitly enrolled
          // as destinations. New connections always require their library marker.
          if configuration.destinationVerified == true { throw DestinationIdentityError.mismatch }
        }
        guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
      } catch {
        try? await remote.disconnectShare()
        throw error
      }
      client = remote
      connection = configuration
    }
    var results: [URL] = []
    do {
      let dir = try directory(media)
      try await FileTasks.perform {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }
      for (index, path) in media.relativePaths.enumerated()
      where indices == nil || indices!.contains(index) {
        let transferKey = dir.path + fingerprint(media) + ":" + String(index)
        while transferring.contains(transferKey) { try await Task.sleep(for: .milliseconds(25)) }
        try Task.checkCancellation()
        transferring.insert(transferKey)
        defer { transferring.remove(transferKey) }
        if let cached = try await cachedPage(media, index: index) {
          results.append(cached)
          onProgress?(
            Double(index + 1) / Double(max(1, media.relativePaths.count)), "Available offline")
          continue
        }
        guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
        try Task.checkCancellation()
        _ = try SMBReadPath.components(path)
        let remote =
          (connection?.basePath.isEmpty == false ? connection!.basePath + "/" : "") + path
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        _ = try PathPolicy.component(ext)
        let target = dir.appendingPathComponent("\(index)." + ext)
        let partial = dir.appendingPathComponent(UUID().uuidString + ".partial")
        let detail = "Downloading \(index+1) of \(media.relativePaths.count)"
        let fileCount = Double(max(1, media.relativePaths.count))
        onProgress?(Double(index) / fileCount, detail)
        do {
          let cancellation = TransferCancellation()
          try await withTaskCancellationHandler {
            if let localURLs, localURLs.indices.contains(index) {
              let source = localURLs[index]
              try await Task.detached {
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                  throw StorageError.collision
                }
                let output = try FileHandle(forWritingTo: partial)
                defer { try? output.close() }
                let size = max(
                  1, (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 1)
                var bytes = 0
                while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                  guard !cancellation.isCancelled else { throw CancellationError() }
                  try output.write(contentsOf: chunk)
                  bytes += chunk.count
                  let progress = (Double(index) + Double(bytes) / Double(size)) / fileCount
                  await onProgress?(progress, detail)
                }
              }.value
            } else if let client {
              let progress: @Sendable (Int64, Int64) -> Bool = { bytes, total in
                if let onProgress {
                  let value = (Double(index) + Double(bytes) / Double(max(1, total))) / fileCount
                  Task { @MainActor in onProgress(value, detail) }
                }
                return !cancellation.isCancelled
              }
              do {
                try await client.downloadItem(atPath: remote, to: partial, progress: progress)
              } catch POSIXError.ENOENT {
                try Task.checkCancellation()
                let listings = directoryListings
                let namespace =
                  owner + "\0" + media.storageRootId + "\0"
                  + (connection.map { $0.server + "/" + $0.share + "/" + $0.basePath } ?? "")
                let resolved = try await SMBReadPath.resolve(
                  path, under: connection?.basePath ?? ""
                ) { directory in
                  try await listings.entries(namespace: namespace, path: directory, client: client)
                }
                try await FileTasks.perform {
                  if FileManager.default.fileExists(atPath: partial.path) {
                    try FileManager.default.removeItem(at: partial)
                  }
                }
                try Task.checkCancellation()
                try await client.downloadItem(atPath: resolved, to: partial, progress: progress)
              }
            } else {
              throw StorageError.emptyChapter
            }
          } onCancel: {
            cancellation.cancel()
          }
          try Task.checkCancellation()
          guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
          try await FileTasks.perform {
            if FileManager.default.fileExists(atPath: target.path) {
              try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: partial, to: target)
          }
        } catch {
          try? await FileTasks.perform { try FileManager.default.removeItem(at: partial) }
          throw error
        }
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let manifestKey = dir.path + fingerprint(media)
        let files = try await manifestStore.record(
          index, fingerprint: fingerprint(media), at: manifestURL)
        guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
        manifests[manifestKey, default: []].formUnion(files)
        let availabilityKey = dir.path + fingerprint(media)
        let complete = (manifests[manifestKey]?.count ?? 0) == media.relativePaths.count
        let changed = availability[availabilityKey] != complete
        availability[availabilityKey] = complete
        if changed && complete { availabilityChanged?() }
        results.append(target)
      }
      guard session.account?.ownerId == owner else { throw LoginError.invalidToken }
      if let client { try? await client.disconnectShare() }
      return results
    } catch {
      if let client { try? await client.disconnectShare() }
      throw error
    }
  }
  func deleteDownload(_ media: MediaVersion) throws {
    let dir = try directory(media)
    availability[dir.path + fingerprint(media)] = false
    manifests[dir.path + fingerprint(media)] = []
    availabilityChanged?()
    if FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.removeItem(at: dir)
    }
  }
  func chapters(for entity: LibraryEntity) -> [LibraryEntity] {
    session.catalog.chapters(for: entity, showNSFW: AppConfiguration.showNSFW)
  }
}

// Serial read/merge/write prevents concurrent cover and reader downloads losing manifest entries.
private actor DownloadManifestStore {
  func record(_ index: Int, fingerprint: String, at url: URL) throws -> Set<Int> {
    var files = Set<Int>()
    if let data = try? Data(contentsOf: url),
      let stored = try? JSONDecoder().decode([String: String].self, from: data),
      stored["fingerprint"] == fingerprint
    {
      files = Set(stored["files"]?.split(separator: ",").compactMap { Int($0) } ?? [])
    }
    files.insert(index)
    try JSONEncoder().encode([
      "fingerprint": fingerprint, "files": files.sorted().map(String.init).joined(separator: ","),
    ]).write(to: url, options: .atomic)
    return files
  }
}
private actor SMBDirectoryListings {
  private struct Listing {
    let date: Date
    let entries: [SMBReadPath.Entry]
  }
  private var cache: [Data: Listing] = [:]
  func entries(namespace: String, path: String, client: SMB2Manager) async throws
    -> [SMBReadPath.Entry]
  {
    let key = Data((namespace + "\0" + path).utf8)
    if let hit = cache[key], Date().timeIntervalSince(hit.date) < 30 { return hit.entries }
    let entries = try await client.contentsOfDirectory(atPath: path).compactMap {
      item -> SMBReadPath.Entry? in
      guard let name = item[.nameKey] as? String else { return nil }
      return .init(
        name: name, directory: item[.fileResourceTypeKey] as? URLFileResourceType == .directory)
    }
    try Task.checkCancellation()
    if cache.count >= 64, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key {
      cache.removeValue(forKey: oldest)
    }
    cache[key] = Listing(date: Date(), entries: entries)
    return entries
  }
}
