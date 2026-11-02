import Foundation
import MangaCore

enum OllamaTranslator {
  static let defaultPrompt =
    "Translate faithfully. Preserve names, meaning, paragraph breaks and [chapter:...] markers. Return only the translated text, without JSON, markdown fences or commentary."
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
  struct Settings: Codable, Sendable {
    var host: String
    var model: String
    var prompt: String
    var maximumCharacters: Int
    var contextTokens: Int
    var outputTokens: Int
    init(defaults: UserDefaults = .standard) {
      host = defaults.string(forKey: "OllamaURL") ?? "http://localhost:11434"
      model = (defaults.string(forKey: "OllamaModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let stored = defaults.string(forKey: "OllamaPrompt")
      prompt = stored == "Translate titles and descriptions faithfully. Return JSON with title and description. Preserve names and meaning; add no commentary." ? defaultPrompt : stored ?? defaultPrompt
      maximumCharacters = min(10000, max(100, defaults.object(forKey: "TranslationChunkCharacters") == nil ? 1500 : defaults.integer(forKey: "TranslationChunkCharacters")))
      contextTokens = min(131072, max(1024, defaults.object(forKey: "TranslationContextTokens") == nil ? 16384 : defaults.integer(forKey: "TranslationContextTokens")))
      outputTokens = min(contextTokens - 512, max(128, defaults.object(forKey: "TranslationOutputTokens") == nil ? 4096 : defaults.integer(forKey: "TranslationOutputTokens")))
    }
  }
  static func translateChunk(_ source: String, language: String, settings: Settings,
    session: URLSession = .shared) async throws -> String {
    let content = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if content.isEmpty { return source }
    let host = try endpoint(settings.host)
    guard !settings.model.isEmpty else { throw LoginError.server("Choose an Ollama model in Translation settings.") }
    let system = settings.prompt + "\n\nTranslate to \(language). Return only translated text. Do not output JSON or explanations. Preserve [chapter:...] markers verbatim and preserve paragraph breaks."
    // UTF-8 byte count is a deliberately conservative budget estimate, not a
    // tokenizer. Do not silently truncate a prompt or carry growing chat history.
    guard system.utf8.count + content.utf8.count + 512 <= settings.contextTokens - settings.outputTokens else {
      throw LoginError.server("This chunk and system prompt exceed the conservative context budget. Reduce Maximum chunk characters or shorten the system prompt; no text was truncated.")
    }
    var request = URLRequest(url: host.appendingPathComponent("api/chat"))
    request.httpMethod = "POST"; request.timeoutInterval = 600
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": settings.model, "stream": false,
      "options": ["num_ctx": settings.contextTokens, "num_predict": settings.outputTokens],
      "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
    ])
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    let json = try checkedJSON(data, response: response, model: settings.model)
    if json["done_reason"] as? String == "length" || json["done"] as? Bool == false {
      throw LoginError.server("The model reached its output token limit. This chunk was not saved. Reduce Maximum chunk characters, then retry with current settings.")
    }
    guard let message = json["message"] as? [String: Any], let output = message["content"] as? String,
      !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw LoginError.server("The translation model returned no text.") }
    let leading = String(source.prefix(while: { $0.isWhitespace }))
    let trailing = String(source.reversed().prefix(while: { $0.isWhitespace }).reversed())
    return leading + output.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
  }
  static func translate(title: String, description: String, language: String,
    defaults: UserDefaults = .standard, session: URLSession = .shared) async throws -> LocalizedText {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw LoginError.server("There is no source title or description to translate.") }
    let settings = Settings(defaults: defaults)
    var text = LocalizedText()
    if !title.isEmpty { text.title = try await translateChunk(title, language: language, settings: settings, session: session) }
    if !description.isEmpty {
      let chunks = try await Task.detached { try TextChunker.chunks(description, maximum: settings.maximumCharacters) }.value
      var output = ""
      for chunk in chunks { output += try await translateChunk(chunk, language: language, settings: settings, session: session) }
      text.description = output
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
