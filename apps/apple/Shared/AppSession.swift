import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import MangaCore
import Security

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
@MainActor
final class AppSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding
{
  @Published var account: VerifiedAccount?
  @Published var entities: [LibraryEntity] = []
  @Published var states: [PersonalState] = []
  @Published var status = "Sign in to your MangaReader library."
  @Published var busy = false
  var onChange: (() -> Void)?
  private var credentials: StoredCredentials?
  private var webSession: ASWebAuthenticationSession?
  private var refreshTask: Task<StoredCredentials, Error>?
  private var pollTask: Task<Void, Never>?
  private var epoch = UUID()
  var api: APIClient {
    let config = AppConfiguration.current()
    return APIClient(
      base: config.apiURL,
      token: { [weak self] in
        guard let self else { throw LoginError.invalidToken }
        return try await self.accessToken()
      })
  }
  var cacheDirectory: URL? {
    guard let account else { return nil }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MangaReader/accounts/" + account.ownerId, isDirectory: true)
  }
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if os(macOS)
      return NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    #else
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      if let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) { return window }
      guard let scene = scenes.first else {
        preconditionFailure("Sign-in requires an active window scene")
      }
      return UIWindow(windowScene: scene)
    #endif
  }
  private func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw LoginError.invalidToken
    }
    return Base64URL.encode(Data(bytes))
  }
  private func discovery() async throws -> OIDCDiscovery {
    let config = AppConfiguration.current()
    guard config.isConfigured else { throw LoginError.invalidConfiguration }
    let (data, response) = try await URLSession.shared.data(
      from: config.issuer.appendingPathComponent(".well-known/openid-configuration"))
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw LoginError.server("Discovery failed.")
    }
    let d = try JSONDecoder().decode(OIDCDiscovery.self, from: data)
    try d.validate(issuer: config.issuer)
    return d
  }
  private func exchange(endpoint: URL, fields: [String: String]) async throws -> TokenResponse {
    var r = URLRequest(url: endpoint)
    r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    r.httpBody = OAuthForm.encode(fields)
    let (data, response) = try await URLSession.shared.data(for: r)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw LoginError.server("Sign-in credentials were rejected. Please sign in again.")
    }
    let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
    guard tokens.token_type.lowercased() == "bearer", tokens.expires_in > 0 else {
      throw LoginError.invalidToken
    }
    return tokens
  }
  func login() {
    guard !busy else { return }
    let attempt = epoch
    busy = true
    status = "Opening secure sign-in…"
    onChange?()
    Task {
      do {
        let c = AppConfiguration.current()
        let d = try await discovery()
        guard epoch == attempt else { return }
        let verifier = try random()
        let state = try random()
        let nonce = try random()
        let challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        #if os(macOS)
          let scopes =
            "openid profile email offline_access manga:read manga:state:write manga:manage"
        #else
          let scopes = "openid profile email offline_access manga:read manga:state:write"
        #endif
        var url = URLComponents(url: d.authorization_endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [
          "response_type": "code", "client_id": c.clientId,
          "redirect_uri": c.redirect.absoluteString, "scope": scopes, "resource": c.audience,
          "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
          "nonce": nonce,
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
          let session = ASWebAuthenticationSession(
            url: url.url!, callbackURLScheme: c.redirect.scheme
          ) { callback, error in
            if let error {
              continuation.resume(throwing: error)
            } else if let callback {
              continuation.resume(returning: callback)
            } else {
              continuation.resume(throwing: LoginError.invalidCallback)
            }
          }
          session.presentationContextProvider = self
          self.webSession = session
          if !session.start() {
            self.webSession = nil
            continuation.resume(throwing: LoginError.server("Could not start sign-in."))
          }
        }
        guard epoch == attempt else { return }
        self.webSession = nil
        guard callback.scheme == c.redirect.scheme, callback.host == c.redirect.host,
          callback.path == c.redirect.path,
          let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        else { throw LoginError.invalidCallback }
        let items = parts.queryItems ?? []
        func single(_ name: String) -> String? {
          let matches = items.filter { $0.name == name }
          return matches.count == 1 ? matches[0].value : nil
        }
        guard single("state") == state, single("error") == nil, let code = single("code") else {
          throw LoginError.invalidCallback
        }
        let tokens = try await exchange(
          endpoint: d.token_endpoint,
          fields: [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "client_id": c.clientId, "redirect_uri": c.redirect.absoluteString,
            "resource": c.audience,
          ])
        guard let id = tokens.id_token else { throw LoginError.invalidToken }
        let (jwks, response) = try await URLSession.shared.data(from: d.jwks_uri)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          throw LoginError.invalidToken
        }
        let subject = try IDTokenValidator.validate(
          id, jwks: jwks, issuer: c.issuer.absoluteString, clientId: c.clientId, nonce: nonce)
        let verified = try await APIClient(base: c.apiURL, token: { tokens.access_token }).me()
        guard verified.subject == subject, verified.issuer == c.issuer.absoluteString,
          verified.ownerId
            == AccountIdentity.ownerId(issuer: verified.issuer, subject: verified.subject)
        else {
          throw LoginError.invalidToken
        }
        let stored = StoredCredentials(
          tokens: tokens, ownerId: verified.ownerId, issuer: c.issuer.absoluteString,
          clientId: c.clientId, audience: c.audience)
        guard epoch == attempt else { throw LoginError.invalidToken }
        try CredentialKeychain.save(stored)
        credentials = stored
        account = verified
        loadCache()
        try await synchronize()
        startPolling()
      } catch { status = error.localizedDescription }
      busy = false
      onChange?()
    }
  }
  func restore() {
    let c = AppConfiguration.current()
    guard let stored = CredentialKeychain.read(), stored.issuer == c.issuer.absoluteString,
      stored.clientId == c.clientId, stored.audience == c.audience
    else { return }
    let attempt = epoch
    credentials = stored
    busy = true
    Task {
      do {
        let verified = try await api.me()
        guard epoch == attempt, verified.ownerId == stored.ownerId,
          verified.ownerId
            == AccountIdentity.ownerId(issuer: verified.issuer, subject: verified.subject)
        else {
          throw LoginError.invalidToken
        }
        account = verified
        loadCache()
        try await synchronize()
        startPolling()
      } catch {
        guard epoch == attempt else { return }
        credentials = nil
        status = "Sign in to reconnect: " + error.localizedDescription
      }
      busy = false
      onChange?()
    }
  }
  func accessToken() async throws -> String {
    guard let stored = credentials else { throw LoginError.invalidToken }
    let config = AppConfiguration.current()
    guard stored.issuer == config.issuer.absoluteString, stored.clientId == config.clientId,
      stored.audience == config.audience
    else { throw LoginError.invalidConfiguration }
    let attempt = epoch
    if stored.expiresAt.timeIntervalSinceNow > 60 { return stored.tokens.access_token }
    if let task = refreshTask { return try await task.value.tokens.access_token }
    let task = Task<StoredCredentials, Error> {
      guard let refresh = stored.tokens.refresh_token else { throw LoginError.invalidToken }
      let d = try await discovery()
      let c = AppConfiguration.current()
      var tokens = try await exchange(
        endpoint: d.token_endpoint,
        fields: [
          "grant_type": "refresh_token", "refresh_token": refresh, "client_id": c.clientId,
          "resource": c.audience,
        ])
      if tokens.refresh_token == nil { tokens.refresh_token = refresh }
      let updated = StoredCredentials(
        tokens: tokens, ownerId: stored.ownerId, issuer: stored.issuer, clientId: stored.clientId,
        audience: stored.audience)
      guard epoch == attempt, credentials?.ownerId == stored.ownerId else {
        throw LoginError.invalidToken
      }
      try CredentialKeychain.save(updated)
      return updated
    }
    refreshTask = task
    do {
      let refreshed = try await task.value
      guard epoch == attempt else { throw LoginError.invalidToken }
      refreshTask = nil
      guard credentials?.ownerId == refreshed.ownerId else { throw LoginError.invalidToken }
      credentials = refreshed
      return refreshed.tokens.access_token
    } catch {
      if epoch == attempt { refreshTask = nil }
      throw error
    }
  }
  func synchronize() async throws {
    guard let owner = account?.ownerId else { return }
    let snapshot = try await api.snapshot()
    guard snapshot.schemaVersion == 1 else {
      throw LoginError.server("Unsupported metadata schema. Update the app before syncing.")
    }
    guard account?.ownerId == owner else { return }
    entities = snapshot.entities
    states = snapshot.states
    if let dir = cacheDirectory {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try JSONEncoder().encode(snapshot).write(
        to: dir.appendingPathComponent("snapshot.json"), options: .atomic)
    }
    status = "Library synced"
    onChange?()
  }
  private func loadCache() {
    guard let dir = cacheDirectory,
      let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")),
      let snapshot = try? JSONDecoder().decode(SyncSnapshot.self, from: data),
      snapshot.schemaVersion == 1
    else { return }
    entities = snapshot.entities
    states = snapshot.states
  }
  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        do { try await self?.synchronize() } catch {
          self?.status = error.localizedDescription
          self?.onChange?()
        }
      }
    }
  }
  func signOut() {
    epoch = UUID()
    busy = false
    webSession?.cancel()
    webSession = nil
    pollTask?.cancel()
    pollTask = nil
    refreshTask?.cancel()
    refreshTask = nil
    CredentialKeychain.clear()
    credentials = nil
    account = nil
    entities = []
    states = []
    status = "Signed out"
    onChange?()
  }
  func visibleEntities(kind: EntityKind? = nil) -> [LibraryEntity] {
    entities.filter {
      (kind == nil || $0.kind == kind)
        && Visibility.visible($0, in: entities, showNSFW: AppConfiguration.showNSFW)
    }
  }
  func create(_ input: MetadataInput) async throws -> LibraryEntity {
    let owner = account?.ownerId
    let entity = try await api.create(input)
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    entities.append(entity)
    onChange?()
    return entity
  }
  func update(_ entity: LibraryEntity, input: MetadataInput) async throws {
    let owner = account?.ownerId
    let updated = try await api.update(entity, input: input)
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    if let i = entities.firstIndex(where: { $0.id == entity.id }) { entities[i] = updated }
    onChange?()
  }
  func saveState(_ input: StateInput) async throws {
    let owner = account?.ownerId
    let old = states.first { $0.entityId == input.entityId && $0.pageIndex == input.pageIndex }
    let value = try await api.state(input, revision: old?.revision ?? 0)
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    states.removeAll { $0.id == value.id }
    states.append(value)
    onChange?()
  }
}
