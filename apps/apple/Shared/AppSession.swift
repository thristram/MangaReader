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
  @Published var entities: [LibraryEntity] = [] {
    didSet {
      cachedCatalog = nil
      metadataGeneration &+= 1
    }
  }
  private(set) var metadataGeneration: UInt64 = 0
  @Published var states: [PersonalState] = [] { didSet { cachedStates = nil } }
  @Published var status = "Sign in to your MangaReader library."
  @Published var busy = false
  var onChange: (() -> Void)?
  private var cachedCatalog: LibraryCatalog?
  private struct StateKey: Hashable {
    let entity: String
    let page: Int?
  }
  private var cachedStates: [StateKey: PersonalState]?
  private let snapshotWriter = SnapshotWriter()
  private var cacheWriteSequence: UInt64 = 0
  var catalog: LibraryCatalog {
    if let cachedCatalog { return cachedCatalog }
    let result = LibraryCatalog(entities)
    cachedCatalog = result
    return result
  }
  func personalState(_ id: String, page: Int? = nil) -> PersonalState? {
    if cachedStates == nil {
      var result: [StateKey: PersonalState] = [:]
      for state in states {
        result[StateKey(entity: state.entityId, page: state.pageIndex)] = state
      }
      cachedStates = result
    }
    return cachedStates?[StateKey(entity: id, page: page)]
  }
  private var credentials: StoredCredentials?
  private var webSession: ASWebAuthenticationSession?
  private var refreshTask: Task<StoredCredentials, Error>?
  private var pollTask: Task<Void, Never>?
  private var syncTask: Task<Void, Error>?
  private var scheduledSyncTask: Task<Void, Never>?
  private var idleSyncTask: Task<Void, Never>?
  private var syncETag: String?
  private var cachedAPI: (epoch: UUID, owner: String?, client: APIClient)?
  private var automaticRefreshEnabled = false
  private var appIsActive = true
  private var lastActivity = Date()
  private var lastIdleArm = Date.distantPast
  private var nextSyncAllowedAt = Date.distantPast
  private var syncFailures = 0
  var flushReadingState: (() -> Void)?
  var persistReadingState: (() async -> Void)?
  private var localCacheTask: Task<Void, Never>?
  private var epoch = UUID()
  private let cacheRoot: URL?
  private let providedAPI: APIClient?
  init(cacheRoot: URL? = nil, apiClient: APIClient? = nil) {
    self.cacheRoot = cacheRoot
    self.providedAPI = apiClient
    super.init()
  }
  var api: APIClient {
    if let providedAPI { return providedAPI }
    let config = AppConfiguration.current()
    let generation = epoch
    let owner = account?.ownerId
    if let cachedAPI, cachedAPI.epoch == generation, cachedAPI.owner == owner { return cachedAPI.client }
    let client = APIClient(
      base: config.apiURL,
      token: { [weak self] in
        guard let self else { throw LoginError.invalidToken }
        return try await self.scopedAccessToken(owner: owner, generation: generation)
      })
    cachedAPI = (generation, owner, client)
    return client
  }
  private func scopedAccessToken(owner: String?, generation: UUID) async throws -> String {
    guard owner != nil, generation == epoch, owner == account?.ownerId else {
      throw LoginError.invalidToken
    }
    let token = try await accessToken()
    guard generation == epoch, owner == account?.ownerId else { throw LoginError.invalidToken }
    return token
  }
  var cacheDirectory: URL? {
    guard let account else { return nil }
    let base =
      cacheRoot
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MangaReader/accounts", isDirectory: true)
    return base.appendingPathComponent(account.ownerId, isDirectory: true)
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
        guard single("state") == state else {
          throw LoginError.invalidCallback
        }
        if let error = single("error") {
          // Only a fixed public error code is logged; never the callback/code/token.
          let known = [
            "access_denied", "invalid_scope", "invalid_target", "invalid_client",
            "unauthorized_client", "invalid_request", "server_error", "temporarily_unavailable",
          ]
          if known.contains(error) { NSLog("MangaReader OAuth error: %@", error) }
          let message: String
          switch error {
          case "access_denied": message = "Sign-in was declined. You can try again."
          case "invalid_scope", "invalid_target":
            message = "This app is not authorized to access your manga library."
          case "invalid_client", "unauthorized_client":
            message = "This app’s sign-in registration is unavailable."
          default: message = "Sign-in could not be completed. Please try again."
          }
          throw LoginError.server(message)
        }
        guard let code = single("code") else { throw LoginError.invalidCallback }
        let tokens = try await exchange(
          endpoint: d.token_endpoint,
          fields: [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "client_id": c.clientId, "redirect_uri": c.redirect.absoluteString,
            "resource": c.audience,
          ])
        guard let id = tokens.id_token else {
          throw LoginError.server(
            "The sign-in service did not return an identity token. Please check its resource scopes."
          )
        }
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
        startAutomaticRefresh()
      } catch {
        guard epoch == attempt else { return }
        webSession = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          status = "Sign in to your MangaReader library."
        } else {
          status = error.localizedDescription
        }
      }
      guard epoch == attempt else { return }
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
    status = "Restoring your session…"
    onChange?()
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
        startAutomaticRefresh()
      } catch {
        guard epoch == attempt else { return }
        credentials = nil
        status = "Sign in to reconnect: " + error.localizedDescription
      }
      guard epoch == attempt else { return }
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
  /// Single-flight and owner-scoped. A manifest has no media paths/descriptions;
  /// only changed records are fetched. A failed batch never publishes half a sync.
  func synchronize(force: Bool = false) async throws {
    guard account != nil else { return }
    if let task = syncTask { return try await task.value }
    if !force && Date() < nextSyncAllowedAt {
      throw APIError(status: 429, retryAfter: nextSyncAllowedAt.timeIntervalSinceNow,
        message: "Sync is temporarily delayed after an error. Retry later or use Sync to check again.")
    }
    let generation = epoch
    let task = Task { try await self.performSync() }
    syncTask = task
    defer { if generation == epoch { syncTask = nil } }
    do {
      try await task.value
      if generation == epoch { syncFailures = 0; nextSyncAllowedAt = .distantPast }
    } catch {
      if generation == epoch, !(error is CancellationError) {
        syncFailures += 1
        let delay = max((error as? APIError)?.retryAfter ?? 0, min(900, 30 * pow(2, Double(min(syncFailures - 1, 5)))))
        nextSyncAllowedAt = Date().addingTimeInterval(delay)
      }
      throw error
    }
  }
  private func performSync() async throws {
    guard let owner = account?.ownerId else { return }
    let generation = epoch
    let initialEntities = Set(entities.map(\.id)), initialStates = Set(states.map(\.id))
    let client = api
    var snapshot: SyncSnapshot
    var manifest: SyncManifest?
    var etag: String?
    do {
      let result = try await client.manifest(etag: syncETag)
      guard let value = result.value else {
        guard account?.ownerId == owner, generation == epoch else { return }
        status = "Library is up to date"; return
      }
      guard value.schemaVersion == 2 else { throw LoginError.server("Unsupported sync manifest") }
      manifest = value; etag = result.etag
      let revisions = Dictionary(entities.map { ($0.id, $0.revision) }, uniquingKeysWith: max)
      let stateRevisions = Dictionary(states.map { ($0.id, $0.revision) }, uniquingKeysWith: max)
      var entityIDs = value.entities.filter { revisions[$0.id, default: 0] < $0.revision }.map(\.id)
      var stateIDs = value.states.filter { stateRevisions[$0.id, default: 0] < $0.revision }.map(\.id)
      if entityIDs.isEmpty && stateIDs.isEmpty && Set(value.entities.map(\.id)) == initialEntities && Set(value.states.map(\.id)) == initialStates {
        guard account?.ownerId == owner, generation == epoch else { return }
        syncETag = etag; status = "Library is up to date"; return
      }
      var changedEntities: [LibraryEntity] = [], changedStates: [PersonalState] = []
      while !entityIDs.isEmpty || !stateIDs.isEmpty {
        try Task.checkCancellation()
        let selectedEntities = Array(entityIDs.prefix(100)), selectedStates = Array(stateIDs.prefix(100))
        let batch = try await client.records(entities: selectedEntities, states: selectedStates)
        guard batch.schemaVersion == 1 else { throw LoginError.server("Unsupported record schema") }
        changedEntities += batch.entities; changedStates += batch.states
        let deferredEntities = batch.remainingEntities ?? [], deferredStates = batch.remainingStates ?? []
        guard Set(deferredEntities).isSubset(of: Set(selectedEntities)), Set(deferredStates).isSubset(of: Set(selectedStates)),
          deferredEntities.count + deferredStates.count < selectedEntities.count + selectedStates.count
        else { throw LoginError.server("Sync batch made no progress") }
        entityIDs.removeFirst(selectedEntities.count); stateIDs.removeFirst(selectedStates.count)
        entityIDs.insert(contentsOf: deferredEntities, at: 0); stateIDs.insert(contentsOf: deferredStates, at: 0)
      }
      // Manifest absence is authoritative only for records present at the start.
      // Preserve a local write that completed while a request was in flight.
      let remoteEntities = Set(value.entities.map(\.id)), remoteStates = Set(value.states.map(\.id))
      snapshot = SyncSnapshot(schemaVersion: 1,
        entities: entities.filter { remoteEntities.contains($0.id) || !initialEntities.contains($0.id) },
        states: states.filter { remoteStates.contains($0.id) || !initialStates.contains($0.id) })
      let currentIDs = Set(entities.map(\.id)), currentStateIDs = Set(states.map(\.id))
      for item in changedEntities {
        if initialEntities.contains(item.id) && !currentIDs.contains(item.id) { continue }
        if let i = snapshot.entities.firstIndex(where: { $0.id == item.id }) {
          if snapshot.entities[i].revision <= item.revision { snapshot.entities[i] = item }
        } else { snapshot.entities.append(item) }
      }
      for item in changedStates {
        if initialStates.contains(item.id) && !currentStateIDs.contains(item.id) { continue }
        if let i = snapshot.states.firstIndex(where: { $0.id == item.id }) {
          if snapshot.states[i].revision <= item.revision { snapshot.states[i] = item }
        } else { snapshot.states.append(item) }
      }
    } catch let error as APIError where [404,405].contains(error.status) && error.code == nil {
      // Rolling upgrade only: old servers retain their explicit bootstrap route.
      snapshot = try await client.snapshot()
    }
    guard snapshot.schemaVersion == 1 else { throw LoginError.server("Unsupported metadata schema. Update the app before syncing.") }
    guard account?.ownerId == owner, generation == epoch else { return }
    var merged = snapshot
    if manifest == nil {
      merged.entities = Self.mergeSnapshot(snapshot.entities, current: entities, initialIDs: initialEntities,
        id: { $0.id }, revision: { $0.revision })
      merged.states = Self.mergeSnapshot(snapshot.states, current: states, initialIDs: initialStates,
        id: { $0.id }, revision: { $0.revision })
    }
    entities = merged.entities; states = merged.states
    if let dir = cacheDirectory {
      cacheWriteSequence &+= 1
      try await snapshotWriter.save(merged, to: dir, sequence: cacheWriteSequence)
      guard account?.ownerId == owner, generation == epoch else { return }
    }
    if manifest != nil { syncETag = etag }
    status = "Library synced"; onChange?()
  }
  private static func mergeSnapshot<Item>(_ incoming: [Item], current: [Item], initialIDs: Set<String>,
    id: (Item) -> String, revision: (Item) -> Int) -> [Item] {
    let local = Dictionary(current.map { (id($0), $0) }, uniquingKeysWith: { first, second in
      revision(first) >= revision(second) ? first : second
    })
    // Deletes completed while this request was in flight must not be resurrected.
    let removed = initialIDs.subtracting(local.keys)
    var seen = Set<String>()
    var result = incoming.compactMap { remote -> Item? in
      let key = id(remote)
      guard !removed.contains(key), seen.insert(key).inserted else { return nil }
      if let value = local[key], revision(value) > revision(remote) { return value }
      return remote
    }
    result += current.filter { !seen.contains(id($0)) && !removed.contains(id($0)) }
    return result
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
  func startAutomaticRefresh() {
    automaticRefreshEnabled = true
    #if os(macOS)
      noteActivity()
    #else
      resumePhonePolling()
    #endif
  }
  /// Mac: one refresh per long idle period, never a recurring 30-second poll.
  func noteActivity(now: Date = Date()) {
    let returningFromIdle = now.timeIntervalSince(lastActivity) >= 600
    lastActivity = now
    guard automaticRefreshEnabled else { return }
    if returningFromIdle { scheduleRefresh(delay: 0) }
    guard now.timeIntervalSince(lastIdleArm) >= 5 else { return }
    lastIdleArm = now
    idleSyncTask?.cancel()
    idleSyncTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(600))
      guard !Task.isCancelled, let self else { return }
      // Activity within the coalescing window must not count as a full idle period.
      let remaining = 600 - Date().timeIntervalSince(self.lastActivity)
      if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
      guard !Task.isCancelled else { return }
      do { try await self.synchronize() } catch { self.status = error.localizedDescription }
    }
  }
  func setAppActive(_ active: Bool) {
    appIsActive = active
    if !active { pollTask?.cancel(); pollTask = nil; flushReadingState?() }
    #if os(iOS)
      if active, automaticRefreshEnabled {
        scheduleRefresh(delay: 0)
        resumePhonePolling()
      }
    #else
      if active { noteActivity() }
    #endif
  }
  private func resumePhonePolling() {
    guard appIsActive else { return }
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(120))
        guard !Task.isCancelled, let self, self.appIsActive else { return }
        do { try await self.synchronize() } catch { self.status = error.localizedDescription }
      }
    }
  }
  private func scheduleRefresh(delay: TimeInterval = 2) {
    guard automaticRefreshEnabled else { return }
    scheduledSyncTask?.cancel()
    scheduledSyncTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.scheduledSyncTask = nil
      do { try await self.synchronize() } catch { self.status = error.localizedDescription }
    }
  }
  private func saveLocalCacheSoon() {
    localCacheTask?.cancel()
    let owner = account?.ownerId, generation = epoch
    localCacheTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self, self.account?.ownerId == owner, self.epoch == generation,
        let directory = self.cacheDirectory else { return }
      self.cacheWriteSequence &+= 1
      do { try await self.snapshotWriter.save(SyncSnapshot(schemaVersion: 1, entities: self.entities, states: self.states), to: directory, sequence: self.cacheWriteSequence) }
      catch { self.status = error.localizedDescription }
    }
  }
  func reloadState(entity: String, page: Int?) async throws {
    let owner = account?.ownerId
    let value = try await api.personalState(entity: entity, page: page)
    guard owner == account?.ownerId else { throw LoginError.invalidToken }
    if let value {
      if let index = states.firstIndex(where: { $0.entityId == entity && $0.pageIndex == page }) { states[index] = value }
      else { states.append(value) }
    } else { states.removeAll { $0.entityId == entity && $0.pageIndex == page } }
  }
  func signOut() {
    epoch = UUID()
    busy = false
    webSession?.cancel()
    webSession = nil
    pollTask?.cancel()
    pollTask = nil
    syncTask?.cancel(); syncTask = nil
    scheduledSyncTask?.cancel(); scheduledSyncTask = nil
    idleSyncTask?.cancel(); idleSyncTask = nil
    localCacheTask?.cancel(); localCacheTask = nil
    syncETag = nil; cachedAPI = nil; automaticRefreshEnabled = false; lastIdleArm = .distantPast
    nextSyncAllowedAt = .distantPast; syncFailures = 0
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
    catalog.visible(kind: kind, showNSFW: AppConfiguration.showNSFW)
  }
  func create(_ input: MetadataInput) async throws -> LibraryEntity {
    let owner = account?.ownerId
    let entity = try await api.create(input)
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    if let i = entities.firstIndex(where: { $0.id == entity.id }) {
      if entity.revision >= entities[i].revision { entities[i] = entity }
    } else { entities.append(entity) }
    saveLocalCacheSoon(); scheduleRefresh()
    onChange?()
    return entity
  }
  func update(_ entity: LibraryEntity, input: MetadataInput) async throws {
    let owner = account?.ownerId
    let updated = try await api.update(entity, input: input)
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    if let i = entities.firstIndex(where: { $0.id == entity.id }), updated.revision >= entities[i].revision {
      entities[i] = updated
    }
    saveLocalCacheSoon(); scheduleRefresh()
    onChange?()
  }
  func delete(_ entity: LibraryEntity) async throws {
    let owner = account?.ownerId
    try await api.delete(entity)
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    entities.removeAll { $0.id == entity.id }
    states.removeAll { $0.entityId == entity.id }
    saveLocalCacheSoon(); scheduleRefresh()
    onChange?()
  }
  func deleteTag(_ tag: LibraryEntity) async throws {
    guard tag.kind == .tag else { return }
    let owner = account?.ownerId
    // Detach only this tag. Chapter metadata, personal state and files survive.
    for (reference, input) in TagRemovalPlan.updates(for: tag.id, entities: entities) {
      guard account?.ownerId == owner else { throw LoginError.invalidToken }
      try await update(reference, input: input)
    }
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    try await delete(tag)
  }
  func deleteAuthor(_ author: LibraryEntity) async throws {
    guard author.kind == .author, account?.scopes.contains("manga:manage") == true,
      let owner = account?.ownerId
    else { throw LoginError.invalidToken }
    // Use current revisions, including hidden works and changes made on another device.
    try await synchronize()
    guard owner == account?.ownerId else { throw LoginError.invalidToken }
    guard let current = entities.first(where: { $0.id == author.id && !$0.deleted }) else { return }
    let references = entities.filter { !$0.deleted && $0.authorId == current.id }
    if references.isEmpty {
      try await delete(current)
      return
    }
    guard current.title.caseInsensitiveCompare("other author") != .orderedSame else {
      throw LoginError.server("The default author is still used by comics and cannot be deleted.")
    }
    let fallback: LibraryEntity
    if let existing = entities.first(where: {
      $0.kind == .author && !$0.deleted && $0.id != current.id
        && $0.title.caseInsensitiveCompare("other author") == .orderedSame
    }) {
      fallback = existing
    } else {
      fallback = try await create(.init(kind: .author, title: "other author"))
    }
    guard owner == account?.ownerId else { throw LoginError.invalidToken }
    let changes = AuthorRemovalPlan.updates(
      for: current, replacement: fallback.id, entities: entities)
    var completed: [String: LibraryEntity] = [:]
    func publishCompleted() {
      guard owner == account?.ownerId, !completed.isEmpty else { return }
      entities = entities.map { entity in
        guard let updated = completed[entity.id], updated.revision >= entity.revision else {
          return entity
        }
        return updated
      }
      onChange?()
    }
    do {
      for (entity, input) in changes {
        try Task.checkCancellation()
        guard owner == account?.ownerId else { throw LoginError.invalidToken }
        let updated = try await api.update(entity, input: input)
        guard owner == account?.ownerId else { throw LoginError.invalidToken }
        completed[entity.id] = updated
      }
      publishCompleted()
      // The API also refuses deletion if a concurrent import added a new reference.
      guard owner == account?.ownerId else { throw LoginError.invalidToken }
      try await delete(current)
    } catch {
      publishCompleted()
      throw error
    }
  }
  func removeDestination(_ root: LibraryEntity) async throws {
    // Referenced roots stay as read-only import sources so removal from archive
    // destinations cannot orphan an existing chapter or delete its files.
    if entities.contains(where: { !$0.deleted && $0.media.contains { $0.storageRootId == root.id } }
    ) {
      var input = root.input
      input.description = LibraryDestinationIdentity.sourceOnlyDescription
      try await update(root, input: input)
    } else {
      try await delete(root)
    }
  }
  func saveState(_ input: StateInput) async throws {
    let owner = account?.ownerId
    let old = states.first { $0.entityId == input.entityId && $0.pageIndex == input.pageIndex }
    let value = try await api.state(input, revision: old?.revision ?? 0)
    guard account?.ownerId == owner else { throw LoginError.invalidToken }
    if let i = states.firstIndex(where: { $0.id == value.id }) {
      if value.revision >= states[i].revision { states[i] = value }
    } else { states.append(value) }
    onChange?()
  }
}

// Serial file writes and JSON encoding stay off the UI actor.
private actor SnapshotWriter {
  private var sequences: [String: UInt64] = [:]
  func save(_ snapshot: SyncSnapshot, to directory: URL, sequence: UInt64) throws {
    guard sequence >= (sequences[directory.path] ?? 0) else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(
      to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
    sequences[directory.path] = sequence
  }
}
