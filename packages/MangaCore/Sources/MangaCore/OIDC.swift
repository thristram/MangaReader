import CryptoKit
import Foundation

public enum LoginError: Error, LocalizedError {
  case invalidConfiguration, invalidCallback, invalidToken
  case server(String)
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "Configure the API, issuer and OAuth client before signing in."
    case .invalidCallback: return "The sign-in callback could not be verified."
    case .invalidToken: return "The identity token could not be verified."
    case .server(let v): return v
    }
  }
}
public enum Base64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
  public static func decode(_ value: String) -> Data? {
    let s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
  }
}
public struct OIDCDiscovery: Codable, Sendable {
  public var issuer: String
  public var authorization_endpoint: URL
  public var token_endpoint: URL
  public var jwks_uri: URL
  public func validate(issuer expected: URL) throws {
    guard issuer == expected.absoluteString,
      [authorization_endpoint, token_endpoint, jwks_uri].allSatisfy({ $0.scheme == "https" })
    else { throw LoginError.invalidConfiguration }
  }
}
public struct TokenResponse: Codable, Sendable {
  public var access_token: String
  public var token_type: String
  public var expires_in: Int
  public var refresh_token: String?
  public var id_token: String?
}
public struct StoredCredentials: Codable, Sendable {
  public var tokens: TokenResponse
  public var expiresAt: Date
  public var ownerId: String
  public var issuer: String
  public var clientId: String
  public var audience: String
  public init(
    tokens: TokenResponse, ownerId: String, issuer: String, clientId: String, audience: String
  ) {
    self.tokens = tokens
    expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
    self.ownerId = ownerId
    self.issuer = issuer
    self.clientId = clientId
    self.audience = audience
  }
}
public enum IDTokenValidator {
  /// Thristram's configured EdDSA / Ed25519 identity tokens. Unsupported algorithms fail closed.
  public static func validate(
    _ jwt: String, jwks: Data, issuer: String, clientId: String, nonce: String, now: Date = Date()
  ) throws -> String {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, let headerData = Base64URL.decode(parts[0]),
      let payloadData = Base64URL.decode(parts[1]), let signature = Base64URL.decode(parts[2]),
      let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      header["alg"] as? String == "EdDSA", header["crit"] == nil,
      let kid = header["kid"] as? String,
      let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
      let keys = set["keys"] as? [[String: Any]],
      let jwk = keys.first(where: {
        $0["kid"] as? String == kid && $0["kty"] as? String == "OKP"
          && $0["crv"] as? String == "Ed25519"
          && ($0["use"] == nil || $0["use"] as? String == "sig")
          && ($0["alg"] == nil || $0["alg"] as? String == "EdDSA")
      }),
      let x = jwk["x"] as? String, let bytes = Base64URL.decode(x)
    else { throw LoginError.invalidToken }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    guard key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)),
      let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else { throw LoginError.invalidToken }
    let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
    let time = now.timeIntervalSince1970
    guard claims["iss"] as? String == issuer, audiences.contains(clientId),
      claims["nonce"] as? String == nonce,
      let exp = claims["exp"] as? Double, exp > time, let iat = claims["iat"] as? Double,
      iat <= time + 30,
      let sub = claims["sub"] as? String, !sub.isEmpty
    else { throw LoginError.invalidToken }
    if (audiences.count > 1 || claims["azp"] != nil) && claims["azp"] as? String != clientId {
      throw LoginError.invalidToken
    }
    if let nbf = claims["nbf"] as? Double, nbf > time + 30 { throw LoginError.invalidToken }
    return sub
  }
}

public enum OAuthForm {
  public static func encode(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let parts = fields.keys.sorted().map { key in
      key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[key]!
        .addingPercentEncoding(withAllowedCharacters: allowed)!
    }
    return Data(parts.joined(separator: "&").utf8)
  }
}
public enum AccountIdentity {
  public static func ownerId(issuer: String, subject: String) -> String {
    SHA256.hash(data: Data((issuer + "\0" + subject).utf8)).map { String(format: "%02x", $0) }
      .joined()
  }
}
