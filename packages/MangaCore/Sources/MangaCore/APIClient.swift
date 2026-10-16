import Foundation

public struct APIError: Error, LocalizedError, Sendable {
  public var status: Int
  public var message: String
  public var errorDescription: String? { message }
}
public actor APIClient {
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
  private func request<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil, revision: Int? = nil
  ) async throws -> T {
    var r = URLRequest(url: base.appendingPathComponent(path))
    r.httpMethod = method
    r.httpBody = body
    r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let revision { r.setValue(String(revision), forHTTPHeaderField: "If-Match") }
    let (data, response) = try await transport.data(for: r)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let detail = error?["error"] as? [String: Any]
      throw APIError(
        status: status, message: detail?["message"] as? String ?? "API request failed (\(status)).")
    }
    return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
  }
  public func me() async throws -> VerifiedAccount { try await request("v1/me") }
  public func snapshot() async throws -> SyncSnapshot { try await request("v1/sync") }
  public func create(_ input: MetadataInput) async throws -> LibraryEntity {
    try await request("v1/entities", method: "POST", body: JSONEncoder().encode(input))
  }
  public func update(_ entity: LibraryEntity, input: MetadataInput) async throws -> LibraryEntity {
    try await request(
      "v1/entities/\(entity.id)", method: "PUT", body: JSONEncoder().encode(input),
      revision: entity.revision)
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
