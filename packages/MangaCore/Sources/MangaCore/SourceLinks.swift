import Foundation

extension SourceLink {
  public var displayName: String {
    switch site.lowercased() {
    case "pixiv": "Pixiv"
    case "fanbox": "FANBOX"
    case "patreon": "Patreon"
    case "ehentai": "E-Hentai"
    default: site.capitalized
    }
  }

  /// Author profiles and comic posts have different ID routes on some providers.
  public func destinationURL(author: Bool = false) -> URL? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if let url = URL(string: value), url.scheme?.lowercased() == "https",
      let host = url.host, !host.isEmpty { return url }
    // A malformed or unsupported explicit URL must not become a provider ID.
    guard !value.contains("://") else { return nil }
    let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    switch site.lowercased() {
    case "pixiv":
      return URL(string: "https://www.pixiv.net/" + (author ? "users/" : "artworks/") + escaped)
    case "fanbox":
      if author {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + value + ".fanbox.cc")
      }
      return URL(string: "https://www.fanbox.cc/posts/" + escaped)
    case "patreon": return URL(string: "https://www.patreon.com/" + escaped)
    case "ehentai": return URL(string: "https://e-hentai.org/g/" + escaped)
    default: return nil
    }
  }
}
