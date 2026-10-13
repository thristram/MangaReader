import AppKit
import MangaCore

final class MacEditController: NSViewController {
  var entity: LibraryEntity
  let session: AppSession
  let titleField = NSTextField()
  let descriptionField = NSTextField()
  let tagField = NSComboBox()
  let nsfw = NSButton()
  let message = NSTextField(wrappingLabelWithString: "")
  var tags: [String] = []
  init(entity: LibraryEntity, session: AppSession) {
    self.entity = entity
    self.session = session
    tags = entity.tagIds
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.topAnchor.constraint(equalTo: view.topAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    let heading = NSTextField(labelWithString: "Edit " + entity.kind.rawValue)
    heading.font = .systemFont(ofSize: 22, weight: .semibold)
    stack.addArrangedSubview(heading)
    titleField.stringValue = entity.title
    descriptionField.stringValue = entity.description
    descriptionField.maximumNumberOfLines = 8
    for (label, field) in [
      ("Original title", titleField), ("Original description", descriptionField),
    ] {
      stack.addArrangedSubview(NSTextField(labelWithString: label))
      stack.addArrangedSubview(field)
      field.widthAnchor.constraint(equalToConstant: 590).isActive = true
    }
    let translate = NSButton(
      title: "Translate to " + AppConfiguration.preferredLanguage, target: self,
      action: #selector(translate))
    translate.bezelStyle = .rounded
    stack.addArrangedSubview(translate)
    let translated = entity.localizations[AppConfiguration.preferredLanguage]
    message.stringValue =
      translated.map { ($0.title ?? "") + " · " + ($0.description ?? "") }
      ?? "Untranslated fields display the original text."
    stack.addArrangedSubview(message)
    tagField.addItems(
      withObjectValues: session.entities.filter { $0.kind == .tag && !$0.deleted }.map(\.title))
    tagField.completes = true
    tagField.placeholderString = "Search tags or enter a new tag"
    tagField.widthAnchor.constraint(equalToConstant: 400).isActive = true
    let tagRow = NSStackView(views: [
      tagField, NSButton(title: "Add / Create", target: self, action: #selector(addTag)),
    ])
    stack.addArrangedSubview(tagRow)
    nsfw.setButtonType(.switch)
    nsfw.title = "NSFW — hide by default"
    nsfw.state = entity.nsfw ? .on : .off
    stack.addArrangedSubview(nsfw)
    let actions = NSStackView(views: [
      NSButton(title: "Cancel", target: self, action: #selector(cancel)),
      NSButton(title: "Save", target: self, action: #selector(save)),
    ])
    stack.addArrangedSubview(actions)
  }
  @objc func cancel() { dismiss(self) }
  @objc func addTag() {
    let name = tagField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    Task {
      do {
        let found = session.entities.first {
          $0.kind == .tag && !$0.deleted && $0.title.caseInsensitiveCompare(name) == .orderedSame
        }
        var input = MetadataInput(kind: .tag, title: name)
        input.nsfw = name.lowercased() == "nsfw"
        let id: String
        if let found { id = found.id } else { id = try await session.create(input).id }
        if !tags.contains(id) { tags.append(id) }
        tagField.stringValue = ""
        message.stringValue =
          "Tags: "
          + tags.compactMap { id in session.entities.first { $0.id == id }?.title }.joined(
            separator: ", ")
      } catch { message.stringValue = error.localizedDescription }
    }
  }
  @objc func save() {
    var input = entity.input
    input.title = titleField.stringValue
    input.description = descriptionField.stringValue
    input.tagIds = tags
    input.nsfw = nsfw.state == .on
    Task {
      do {
        try await session.update(entity, input: input)
        dismiss(self)
      } catch { message.stringValue = error.localizedDescription }
    }
  }
  @objc func translate() {
    message.stringValue = "Translating…"
    Task {
      do {
        let text = try await OllamaTranslator.translate(
          title: titleField.stringValue, description: descriptionField.stringValue,
          language: AppConfiguration.preferredLanguage)
        guard let current = session.entities.first(where: { $0.id == entity.id }) else { return }
        var input = current.input
        input.localizations[AppConfiguration.preferredLanguage] = text
        try await session.update(current, input: input)
        entity = session.entities.first(where: { $0.id == current.id }) ?? current
        message.stringValue =
          (text.title ?? entity.title) + " · " + (text.description ?? entity.description)
      } catch { message.stringValue = error.localizedDescription }
    }
  }
}
enum OllamaTranslator {
  static func translate(title: String, description: String, language: String) async throws
    -> LocalizedText
  {
    guard
      let host = URL(
        string: UserDefaults.standard.string(forKey: "OllamaURL") ?? "http://localhost:11434"),
      ["http", "https"].contains(host.scheme),
      let model = UserDefaults.standard.string(forKey: "OllamaModel"), !model.isEmpty
    else { throw LoginError.server("Configure a local Ollama URL and model in settings.") }
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
          "content": UserDefaults.standard.string(forKey: "OllamaPrompt")
            ?? "Translate faithfully. Return JSON with title and description; no commentary.",
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
    guard text.title != nil || text.description != nil else {
      throw LoginError.server("The translation contains no title or description.")
    }
    return text
  }
}
