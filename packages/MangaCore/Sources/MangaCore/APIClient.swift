import Foundation

public struct APIError: Error, LocalizedError, Sendable {
  public init(status: Int, code: String? = nil, retryAfter: TimeInterval? = nil, message: String) {
    self.status = status; self.code = code; self.retryAfter = retryAfter; self.message = message
  }
  public var status: Int
  public var code: String? = nil
  public var retryAfter: TimeInterval? = nil
  public var message: String
  public var errorDescription: String? { message }
}
public actor APIClient {
  private var patchSupported = true
  private let base: URL
  private let transport: URLSession
  private let token: @Sendable () async throws -> String
  public init(
    base: URL, transport: URLSession = .shared, token: @escaping @Sendable () async throws -> String
  ) {
    self.base = base
    self.transport = transport
    self.token = token
  }
  private func response(_ path: String, method: String = "GET", body: Data? = nil,
    revision: Int? = nil, etag: String? = nil, query: [URLQueryItem] = []
  ) async throws -> (Data, HTTPURLResponse) {
    var endpoint = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { endpoint.queryItems = query }
    var r = URLRequest(url: endpoint.url!)
    r.httpMethod = method; r.httpBody = body
    r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let revision { r.setValue(String(revision), forHTTPHeaderField: "If-Match") }
    if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let (data, raw) = try await transport.data(for: r)
    guard let response = raw as? HTTPURLResponse else { throw APIError(status: 0, message: "Invalid API response") }
    let status = response.statusCode
    guard (200..<300).contains(status) || status == 304 else {
      let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let detail = error?["error"] as? [String: Any]
      throw APIError(status: status, code: detail?["code"] as? String,
        retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init),
        message: detail?["message"] as? String ?? "API request failed (\(status)).")
    }
    return (data, response)
  }
  private func request<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil, revision: Int? = nil, query: [URLQueryItem] = []
  ) async throws -> T {
    let (data, _) = try await response(path, method: method, body: body, revision: revision, query: query)
    return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
  }
  public func manifest(etag: String?) async throws -> (value: SyncManifest?, etag: String?) {
    let (data, response) = try await response("v1/sync/manifest", etag: etag)
    return (response.statusCode == 304 ? nil : try JSONDecoder().decode(SyncManifest.self, from: data), response.value(forHTTPHeaderField: "ETag"))
  }
  public func records(entities: [String], states: [String]) async throws -> SyncSnapshot {
    try await request("v1/sync/records", method: "POST", body: JSONEncoder().encode(["entities": entities, "states": states]))
  }
  public func entity(_ id: String) async throws -> LibraryEntity {
    try await request("v1/entities/" + id, query: [.init(name: "includeNSFW", value: "true")])
  }
  public func personalState(entity: String, page: Int?) async throws -> PersonalState? {
    do { return try await request("v1/states/" + entity + ":" + (page.map(String.init) ?? "entity")) }
    catch let error as APIError where error.status == 404 {
      if error.code == nil {
        struct StateList: Decodable, Sendable { let items: [PersonalState] }
        let values: StateList = try await request("v1/states", query: [.init(name: "entityId", value: entity), .init(name: "includeNSFW", value: "true")])
        return values.items.first { $0.entityId == entity && $0.pageIndex == page }
      }
      return nil
    }
  }
  public func me() async throws -> VerifiedAccount { try await request("v1/me") }
  public func snapshot() async throws -> SyncSnapshot { try await request("v1/sync") }
  public func create(_ input: MetadataInput) async throws -> LibraryEntity {
    try await request("v1/entities", method: "POST", body: JSONEncoder().encode(input))
  }
  public func update(_ entity: LibraryEntity, input: MetadataInput) async throws -> LibraryEntity {
    if patchSupported {
      struct Receipt: Decodable, Sendable { let id: String; let revision: Int; let updatedAt: String; let title: String }
      do {
        let receipt: Receipt = try await request("v1/entities/\(entity.id)", method: "PATCH",
          body: MetadataPatch.data(from: entity.input, to: input), revision: entity.revision)
        guard receipt.id == entity.id, receipt.revision == entity.revision + 1 else {
          throw APIError(status: 502, message: "Invalid mutation receipt")
        }
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
        fields["id"] = receipt.id; fields["revision"] = receipt.revision
        fields["updatedAt"] = receipt.updatedAt; fields["deleted"] = false; fields["title"] = receipt.title
        return try JSONDecoder().decode(LibraryEntity.self, from: JSONSerialization.data(withJSONObject: fields))
      } catch let error as APIError where [404,405].contains(error.status) && error.code == nil {
        // Old server/isolated fixtures: only an unrecognized route may fall back.
        // A real not_found/conflict/validation error is never retried as a PUT.
        patchSupported = false
      }
    }
    return try await request("v1/entities/\(entity.id)", method: "PUT", body: JSONEncoder().encode(input), revision: entity.revision)
  }
  public func delete(_ entity: LibraryEntity) async throws {
    struct Acknowledgement: Decodable, Sendable {}
    let _: Acknowledgement = try await request(
      "v1/entities/\(entity.id)", method: "DELETE", revision: entity.revision)
  }
  public func state(_ input: StateInput, revision: Int) async throws -> PersonalState {
    try await request(
      "v1/states", method: "PUT", body: JSONEncoder().encode(input), revision: revision)
  }
}
