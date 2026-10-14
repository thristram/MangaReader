import Foundation
import MangaCore

enum OllamaTranslator {
  static let defaultPrompt =
    "Translate titles and descriptions faithfully. Return JSON with title and description. Preserve names and meaning; add no commentary."
  static func models(host: String) async throws -> [String] {
    let url = try endpoint(host).appendingPathComponent("api/tags")
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = json["models"] as? [[String: Any]]
    else { throw LoginError.server("Unable to read installed Ollama models.") }
    return models.compactMap { $0["name"] as? String }
  }
  private static func endpoint(_ value: String) throws -> URL {
    guard let host = URL(string: value), ["http", "https"].contains(host.scheme), host.host != nil,
      host.user == nil, host.password == nil
    else { throw LoginError.server("Enter a valid Ollama service URL.") }
    return host
  }
  static func translate(title: String, description: String, language: String) async throws
    -> LocalizedText
  {
    let host = try endpoint(
      UserDefaults.standard.string(forKey: "OllamaURL") ?? "http://localhost:11434")
    guard let model = UserDefaults.standard.string(forKey: "OllamaModel"), !model.isEmpty else {
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
          "content": UserDefaults.standard.string(forKey: "OllamaPrompt") ?? defaultPrompt,
        ],
        [
          "role": "user",
          "content": "Translate to \(language). Source JSON: " + String(
            data: original, encoding: .utf8)!,
        ],
      ],
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = json["message"] as? [String: Any], let content = message["content"] as? String,
      let textData = content.data(using: .utf8)
    else { throw LoginError.server("The translation model did not return a usable response.") }
    let text = try JSONDecoder().decode(LocalizedText.self, from: textData)
    guard
      title.isEmpty || text.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      description.isEmpty
        || text.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      throw LoginError.server("The translation contains no title or description.")
    }
    return text
  }
}
