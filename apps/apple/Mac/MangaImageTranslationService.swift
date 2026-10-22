import Foundation
import ImageIO
import MangaCore
import UniformTypeIdentifiers

struct MangaImageTranslationOptions: Codable, Equatable, Sendable {
  var detectionSize = 1536
  var detector = "default"
  var direction = "auto"
  var translator = "youdao"
  var targetLanguage = "CHS"
  var inpaintingSize = 2048
  var unclipRatio = 2.3
  var boxThreshold = 0.7
  var maskDilationOffset = 30
  var inpainter = "default"

  // Matches the upstream web UI's static lists, not a fabricated discovery endpoint.
  // zyddnys/manga-image-translator @ d6de6ab62a7be6afc0d07a3184149cdefbcd32f2
  static let detectionSizes = [1024, 1536, 2048, 2560]
  static let inpaintingSizes = [516, 1024, 2048, 2560]
  static let detectors = ["default", "ctd", "paddle"]
  static let directions = ["auto", "horizontal", "vertical"]
  static let inpainters = ["default", "lama_large", "lama_mpe", "sd", "none", "original"]
  static let translators = ["youdao", "baidu", "deepl", "papago", "caiyun", "sakura", "offline", "openai",
    "deepseek", "groq", "gemini", "custom_openai", "nllb", "nllb_big", "sugoi", "jparacrawl",
    "jparacrawl_big", "m2m100", "m2m100_big", "mbart50", "qwen2", "qwen2_big", "none", "original"]
  static let languages: [(api: String, media: String, name: String)] = [
    ("CHS", "zh", "简体中文"), ("CHT", "zh-Hant", "繁體中文"), ("CSY", "cs", "čeština"),
    ("NLD", "nl", "Nederlands"), ("ENG", "en", "English"), ("FRA", "fr", "français"),
    ("DEU", "de", "Deutsch"), ("HUN", "hu", "magyar nyelv"), ("ITA", "it", "italiano"),
    ("JPN", "ja", "日本語"), ("KOR", "ko", "한국어"), ("POL", "pl", "polski"),
    ("PTB", "pt-BR", "português"), ("ROM", "ro", "limba română"), ("RUS", "ru", "русский язык"),
    ("ESP", "es", "español"), ("TRK", "tr", "Türk dili"), ("UKR", "uk", "українська мова"),
    ("VIN", "vi", "Tiếng Việt"), ("ARA", "ar", "العربية"), ("CNR", "cnr", "crnogorski jezik"),
    ("SRP", "sr", "српски језик"), ("HRV", "hr", "hrvatski jezik"), ("THA", "th", "ภาษาไทย"),
    ("IND", "id", "Indonesia"), ("FIL", "fil", "Wikang Filipino")
  ]
  var mediaLanguage: String { Self.languages.first { $0.api == targetLanguage }?.media ?? "und" }
  func validate() throws {
    guard Self.detectionSizes.contains(detectionSize), Self.inpaintingSizes.contains(inpaintingSize),
      Self.detectors.contains(detector), Self.directions.contains(direction),
      Self.translators.contains(translator), Self.inpainters.contains(inpainter),
      Self.languages.contains(where: { $0.api == targetLanguage }),
      unclipRatio.isFinite, unclipRatio > 0, unclipRatio <= 10,
      boxThreshold.isFinite, (0...1).contains(boxThreshold), (0...200).contains(maskDilationOffset)
    else { throw LoginError.server("Check the image translation options and numeric ranges.") }
  }
  func configData() throws -> Data {
    try validate()
    return try JSONSerialization.data(withJSONObject: [
      "detector": ["detector": detector, "detection_size": detectionSize, "box_threshold": boxThreshold, "unclip_ratio": unclipRatio],
      "render": ["direction": direction],
      "translator": ["translator": translator, "target_lang": targetLanguage],
      "inpainter": ["inpainter": inpainter, "inpainting_size": inpaintingSize],
      "mask_dilation_offset": maskDilationOffset
    ], options: [.sortedKeys])
  }
  static func load(defaults: UserDefaults = .standard) -> Self {
    defaults.data(forKey: "ImageTranslationDefaults").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
  }
  func save(defaults: UserDefaults = .standard) throws {
    try validate()
    defaults.set(try JSONEncoder().encode(self), forKey: "ImageTranslationDefaults")
  }
}

struct MangaImageTranslationService: Sendable {
  static let defaultBaseURL = "http://localhost:8000"
  let baseURL: URL
  let session: URLSession
  init(baseURL: String, session: URLSession = .shared) throws {
    guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false,
      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
      let url = components.url else { throw LoginError.server("Enter an HTTP or HTTPS service base URL without credentials or query parameters.") }
    self.baseURL = url
    self.session = session
  }
  func testConnection() async throws {
    var request = URLRequest(url: baseURL.appendingPathComponent("openapi.json"), cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 15
    let (data, response) = try await session.data(for: request)
    try Self.checkResponse(response, data: data)
    guard let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let paths = schema["paths"] as? [String: Any],
      let route = paths["/translate/with-form/image"] as? [String: Any], route["post"] != nil
    else { throw LoginError.server("Connected, but this service does not expose the manga-image-translator image API at this base URL.") }
  }
  func translate(image: Data, options: MangaImageTranslationOptions) async throws -> Data {
    let boundary = "MangaReader-" + UUID().uuidString
    var body = Data()
    func append(_ value: String) { body.append(Data(value.utf8)) }
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"config\"\r\nContent-Type: application/json\r\n\r\n")
    body.append(try options.configData())
    append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"page.png\"\r\nContent-Type: image/png\r\n\r\n")
    body.append(image)
    append("\r\n--\(boundary)--\r\n")
    var request = URLRequest(url: baseURL.appendingPathComponent("translate/with-form/image"))
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("image/png", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 1800
    request.httpBody = body
    let (result, response) = try await session.data(for: request)
    try Self.checkResponse(response, data: result)
    try await FileTasks.perform {
      guard result.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
        let source = CGImageSourceCreateWithData(result as CFData, nil), CGImageSourceGetCount(source) > 0,
        CGImageSourceGetStatus(source) == .statusComplete,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0,
        (properties[kCGImagePropertyPixelHeight] as? Int ?? 0) > 0,
        CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 128, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
      else { throw LoginError.server("The translation service returned an invalid or incomplete PNG image.") }
    }
    return result
  }
  private static func checkResponse(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw LoginError.server("No response from the translation service.") }
    guard (200..<300).contains(http.statusCode) else {
      // Surface upstream errors, without dumping request images or headers.
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let detail = (object?["detail"] as? String) ?? (object?["error"] as? String)
      throw LoginError.server("Image translation service: HTTP \(http.statusCode)" + (detail.map { " · " + String($0.prefix(500)) } ?? ""))
    }
  }
}
