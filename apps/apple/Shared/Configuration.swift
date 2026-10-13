import Foundation

struct AppConfiguration: Sendable {
  var apiURL: URL
  var issuer: URL
  var audience: String
  var clientId: String
  var redirect: URL
  static func current() -> Self {
    let defaults = UserDefaults.standard
    func value(_ key: String, _ fallback: String) -> String {
      defaults.string(forKey: key) ?? Bundle.main.object(forInfoDictionaryKey: key) as? String
        ?? fallback
    }
    #if os(macOS)
      let scheme = "com.thristram.mangareader.mac"
    #else
      let scheme = "com.thristram.mangareader.iphone"
    #endif
    return Self(
      apiURL: URL(string: value("MangaAPIURL", "https://manga.example.com")) ?? URL(
        string: "https://manga.example.com")!,
      issuer: URL(string: value("AuthIssuer", "https://auth.example.com/api/auth")) ?? URL(
        string: "https://auth.example.com/api/auth")!,
      audience: value("MangaAPIAudience", "https://manga.example.com"),
      clientId: value("OAuthClientID", "configure-client-id"),
      redirect: URL(string: scheme + ":/oauth/callback")!)
  }
  var isConfigured: Bool {
    issuer.scheme == "https" && apiURL.scheme == "https" && issuer.host != nil && apiURL.host != nil
      && !(issuer.host ?? "").hasSuffix("example.com") && !clientId.hasPrefix("configure")
      && !clientId.hasPrefix("replace")
  }
  static var preferredLanguage: String {
    UserDefaults.standard.string(forKey: "ContentLanguage") ?? "zh"
  }
  static var showNSFW: Bool { UserDefaults.standard.bool(forKey: "ShowNSFW") }
}
