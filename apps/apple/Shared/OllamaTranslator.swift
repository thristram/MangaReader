import Foundation
import MangaCore

enum OllamaTranslator {
  static let defaultPrompt =
    "Translate titles and descriptions faithfully. Return JSON with title and description. Preserve names and meaning; add no commentary."
  static func models(host: String, session: URLSession = .shared) async throws -> [String] {
    let url = try endpoint(host).appendingPathComponent("api/tags")
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 15
    let (data, response) = try await session.data(for: request)
    let json = try checkedJSON(data, response: response)
    guard let models = json["models"] as? [[String: Any]]
    else { throw LoginError.server("Unable to read installed Ollama models.") }
    return models.compactMap { $0["name"] as? String }
  }
  private static func endpoint(_ value: String) throws -> URL {
    guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false,
      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
    else { throw LoginError.server("Enter a valid Ollama service URL.") }
    // Accept pasted native API URLs as well as a base URL, retaining proxy prefixes.
    var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    for suffix in ["api/chat", "api/tags", "api"] {
      if path == suffix { path = ""; break }
      if path.hasSuffix("/" + suffix) { path.removeLast(suffix.count + 1); break }
    }
    components.path = path.isEmpty ? "" : "/" + path
    guard let host = components.url else { throw LoginError.server("Enter a valid Ollama service URL.") }
    return host
  }
  static func translate(title: String, description: String, language: String,
    defaults: UserDefaults = .standard, session: URLSession = .shared) async throws
    -> LocalizedText
  {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LoginError.server("There is no source title or description to translate.")
    }
    let host = try endpoint(
      defaults.string(forKey: "OllamaURL") ?? "http://localhost:11434")
    guard let model = defaults.string(forKey: "OllamaModel")?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
      throw LoginError.server("Choose an Ollama model in Translation settings.")
    }
    var request = URLRequest(url: host.appendingPathComponent("api/chat"))
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let original = try JSONSerialization.data(withJSONObject: [
      "title": title, "description": description,
    ])
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "stream": false, "format": "json",
      "messages": [
        [
          "role": "system",
          "content": (defaults.string(forKey: "OllamaPrompt") ?? defaultPrompt)
            + "\n\nReturn only a JSON object with string fields title and description. Translate their values into the requested language; keep an empty source field empty. Do not add markdown or commentary.",
        ],
        [
          "role": "user",
          "content": "Translate to \(language). Source JSON: " + String(
            data: original, encoding: .utf8)!,
        ],
      ],
    ])
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    let json = try checkedJSON(data, response: response, model: model)
    guard let message = json["message"] as? [String: Any], let content = message["content"] as? String,
      let textData = content.data(using: .utf8)
    else { throw LoginError.server("The translation model did not return a usable response.") }
    let text: LocalizedText
    do { text = try JSONDecoder().decode(LocalizedText.self, from: textData) }
    catch { throw LoginError.server("The translation model did not return valid JSON with title and description. Check the model and system prompt in Ollama Translation settings.") }
    guard
      title.isEmpty || text.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      description.isEmpty
        || text.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      throw LoginError.server("The translation contains no title or description.")
    }
    return text
  }
  private static func checkedJSON(_ data: Data, response: URLResponse, model: String? = nil) throws -> [String: Any] {
    guard let http = response as? HTTPURLResponse else {
      throw LoginError.server("No response from the Ollama service.")
    }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let detail = (json?["error"] as? String).map { String($0.prefix(500)) }
    if !(200..<300).contains(http.statusCode) || detail != nil {
      let message = "Ollama HTTP \(http.statusCode)" + (detail.map { ": " + $0 } ?? "")
      if http.statusCode == 404, let model, let detail,
        detail.lowercased().contains("model"), detail.lowercased().contains("not found") {
        throw LoginError.server("Model “\(model)” is not installed on this Ollama host. Select an installed model in Settings → Ollama Translation, or install it on that host. " + message)
      }
      throw LoginError.server(message)
    }
    guard let json else { throw LoginError.server("The Ollama service returned invalid JSON. Check the service URL.") }
    return json
  }
}
