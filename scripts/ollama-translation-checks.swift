import Foundation
import MangaCore

private final class OllamaTestProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  static var status = 200
  static var responseBody = Data()
  static var requests: [(String, Data)] = []
  static func configure(_ status: Int = 200, _ json: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: json)
    lock.withLock { self.status = status; responseBody = data; requests = [] }
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ollama-fixtures.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
    }
    let (status, data) = Self.lock.withLock {
      Self.requests.append((request.url!.path, body))
      return (Self.status, Self.responseBody)
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor enum OllamaTranslationChecks {
  static func run() async throws {
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
      if !value() { throw LoginError.server("Ollama regression: " + message) }
    }
    let suite = "ollama-checks-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("galtransl:7b", forKey: "OllamaModel")
    defaults.set("Translate Japanese fiction faithfully.", forKey: "OllamaPrompt")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OllamaTestProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    func translate(_ title: String = "雨", _ description: String = "") async throws -> LocalizedText {
      try await OllamaTranslator.translate(title: title, description: description, language: "zh",
        defaults: defaults, session: session)
    }
    func rejected(_ operation: () async throws -> Void) async throws -> String {
      do { try await operation() } catch { return error.localizedDescription }
      throw LoginError.server("Ollama regression: expected failure was accepted")
    }
    let output = ["message": ["content": "雨"], "done": true] as [String: Any]
    for (host, path) in [("https://ollama-fixtures.invalid", "/api/chat"),
      ("https://ollama-fixtures.invalid/api/", "/api/chat"),
      (" https://ollama-fixtures.invalid/proxy/api/chat/ ", "/proxy/api/chat"),
      ("https://ollama-fixtures.invalid/proxy/api/tags", "/proxy/api/chat")] {
      defaults.set(host, forKey: "OllamaURL")
      try OllamaTestProtocol.configure(200, output)
      let text = try await translate()
      try check(text.title == "雨", "translated title was lost")
      let calls = OllamaTestProtocol.lock.withLock { OllamaTestProtocol.requests }
      try check(calls.count == 1 && calls[0].0 == path, "native API route duplicated or provider called twice")
      let payload = try JSONSerialization.jsonObject(with: calls[0].1) as! [String: Any]
      let messages = payload["messages"] as! [[String: String]]
      try check(payload["model"] as? String == "galtransl:7b" && payload["stream"] as? Bool == false
        && payload["format"] == nil, "Ollama chat contract changed")
      try check(messages[0]["content"]!.contains("Translate Japanese fiction faithfully.")
        && messages[0]["content"]!.contains("Return only translated text"), "custom prompt or plain-text instructions lost")
    }
    defaults.set("https://ollama-fixtures.invalid", forKey: "OllamaURL")
    try OllamaTestProtocol.configure(404, ["error": "model 'galtransl:7b' not found"])
    let missing = try await rejected { _ = try await translate() }
    try check(missing.contains("galtransl:7b") && missing.contains("not installed") && missing.contains("HTTP 404"),
      "missing-model error was hidden")
    try check(OllamaTestProtocol.lock.withLock { OllamaTestProtocol.requests.count } == 1,
      "missing model triggered fallback, retry or installation")
    for (status, error) in [(503, "worker unavailable"), (400, "unsupported format"), (200, "runner failed")] {
      try OllamaTestProtocol.configure(status, ["error": error])
      let message = try await rejected { _ = try await translate() }
      try check(message.contains(error), "provider error was hidden")
    }
    try OllamaTestProtocol.configure(404, [:])
    let route = try await rejected { _ = try await translate() }
    try check(route.contains("HTTP 404") && !route.contains("not installed"), "route 404 misidentified as a missing model")
    try OllamaTestProtocol.configure(200, ["models": []])
    let empty = try await OllamaTranslator.models(host: "https://ollama-fixtures.invalid/api/chat", session: session)
    try check(empty.isEmpty, "empty model directory was fabricated")
    try check(OllamaTestProtocol.lock.withLock { OllamaTestProtocol.requests.first?.0 } == "/api/tags",
      "model discovery used the wrong native API route")
    try OllamaTestProtocol.configure(200, ["models": [["name": "galtransl:7b"]]])
    let installed = try await OllamaTranslator.models(host: "https://ollama-fixtures.invalid", session: session)
    try check(installed == ["galtransl:7b"], "exact installed model name changed")
    try OllamaTestProtocol.configure(200, output)
    _ = try await rejected { _ = try await translate("  ", "\n") }
    defaults.set(" \n", forKey: "OllamaModel")
    _ = try await rejected { _ = try await translate() }
    try check(OllamaTestProtocol.lock.withLock { OllamaTestProtocol.requests.isEmpty },
      "empty source or missing model sent an inference request")
    defaults.set("galtransl:7b", forKey: "OllamaModel")
    for host in ["file:///tmp", "https://user:password@ollama-fixtures.invalid", "https://ollama-fixtures.invalid?key=x"] {
      defaults.set(host, forKey: "OllamaURL")
      _ = try await rejected { _ = try await translate() }
    }
    try check(OllamaTestProtocol.lock.withLock { OllamaTestProtocol.requests.isEmpty }, "invalid endpoint sent text")
    defaults.set("https://ollama-fixtures.invalid", forKey: "OllamaURL")
    try OllamaTestProtocol.configure(200, ["message": ["content": "Plain text — no JSON required"]])
    let plain = try await translate()
    try check(plain.title == "Plain text — no JSON required", "plain model output was not accepted")
    try OllamaTestProtocol.configure(200, ["message": ["content": " "]])
    let malformed = try await rejected { _ = try await translate() }
    try check(malformed.contains("no text"), "empty model output error was opaque")
    try OllamaTestProtocol.configure(200, ["message": ["content": "partial"], "done_reason": "length"])
    let truncated = try await rejected { _ = try await translate() }
    try check(truncated.contains("token limit"), "truncated output was accepted")
    let long = String(repeating: "雨の帰り道。\n", count: 200)
    try OllamaTestProtocol.configure(200, ["message": ["content": "回家的路。"]])
    let description = try await translate("", long)
    try check(description.description == "回家的路。\n", "description-only response required a title")
    let body = OllamaTestProtocol.lock.withLock { OllamaTestProtocol.requests[0].1 }
    let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let message = (object["messages"] as! [[String: String]])[1]["content"]!
    try check(message == long.trimmingCharacters(in: .whitespacesAndNewlines),
      "description lost internal Unicode/newlines before submission")
    let options = object["options"] as! [String: Int]
    try check(options["num_ctx"] == 16384 && options["num_predict"] == 4096,
      "shared model token settings were not applied")
    print("PASS: Ollama missing-model/error bodies; native URL normalization; model discovery; custom prompt/plain-text contract and token options; empty-source refusal; title/description translation; Unicode/newlines; no implicit retry/download/provider fallback.")
  }
}
