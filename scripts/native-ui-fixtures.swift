// Compiled only into the separate preview/check application, never the real app.
import CryptoKit
import Foundation
import MangaCore
import PDFKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor enum NativeUIFixtures {
  static func seed(session: AppSession, directory: URL) throws -> LibraryUIModel {
    let media = directory.appendingPathComponent("media")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let account =
      [
        "ownerId": AccountIdentity.ownerId(
          issuer: "https://preview.invalid", subject: "ui-fixture"),
        "issuer": "https://preview.invalid", "subject": "ui-fixture",
        "scopes": ["manga:read", "manga:state:write", "manga:manage"],
      ] as [String: Any]
    session.account = try JSONDecoder().decode(
      VerifiedAccount.self, from: JSONSerialization.data(withJSONObject: account))
    let library = LibraryUIModel(session: session)
    func entity(_ id: String, _ input: MetadataInput) throws -> LibraryEntity {
      var data =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
      data["id"] = id
      data["revision"] = 1
      data["deleted"] = false
      data["updatedAt"] = "2026-10-13T19:00:00Z"
      return try JSONDecoder().decode(
        LibraryEntity.self, from: JSONSerialization.data(withJSONObject: data))
    }
    let root = try entity(
      "fixture-root", .init(kind: .storageRoot, title: "Preview Collection", storageKind: "local"))
    session.entities = [root]
    try library.local.bind(root, to: media)
    let authors = ["Haruka Aoi", "Nagi Shiraishi", "Sumi Mizuno"]
    for (index, name) in authors.enumerated() {
      session.entities.append(try entity("a\(index)", .init(kind: .author, title: name)))
    }
    for (index, name) in ["Everyday", "Warm Stories", "Fantasy", "Short Stories", "NSFW"]
      .enumerated()
    {
      var input = MetadataInput(kind: .tag, title: name)
      input.nsfw = name == "NSFW"
      session.entities.append(try entity("t\(index)", input))
    }
    for (index, name) in ["Letters Through the Seasons", "Across the Sea"].enumerated() {
      session.entities.append(
        try entity(
          "s\(index)",
          .init(
            kind: .series, title: name,
            description: "Small stories, collected across changing seasons.", authorId: "a\(index)")
        ))
    }
    let titles = [
      "The Way Home in the Rain", "Beyond the Blue", "Paper Moon", "The Last Train",
      "A Garden in Winter", "Letters from Tomorrow",
    ]
    for (index, name) in titles.enumerated() {
      var input = MetadataInput(
        kind: .work, title: name, originalLanguage: "ja",
        description: "A quiet walk home, and a conversation that lasts beyond the rain.",
        authorId: "a\(index % 3)", seriesId: index % 3 < 2 ? "s\(index % 3)" : nil)
      input.tagIds = ["t\(index % 4)"]
      session.entities.append(try entity("w\(index)", input))
      for chapter in 0..<2 {
        let id = "c\(index)-\(chapter)"
        var paths: [String] = []
        for page in 0..<6 {
          let filename = "\(id)-\(page).png"
          try drawPage(
            title: chapter == 0 ? name : "Chapter 2 · By the Station", index: index, page: page,
            cover: page == 0
          ).write(to: media.appendingPathComponent(filename))
          paths.append(filename)
        }
        var kind = "images"
        let pageCount = paths.count
        if index == 5 && chapter == 1 {
          let document = PDFDocument()
          for (position, filename) in paths.enumerated() {
            #if os(macOS)
              let image = NSImage(contentsOf: media.appendingPathComponent(filename))!
            #else
              let image = UIImage(contentsOfFile: media.appendingPathComponent(filename).path)!
            #endif
            if let page = PDFPage(image: image) { document.insert(page, at: position) }
          }
          let filename = id + ".pdf"
          guard document.write(to: media.appendingPathComponent(filename)) else {
            throw StorageError.emptyChapter
          }
          paths = [filename]
          kind = "pdf"
        }
        let version = MediaVersion(
          id: "v-" + id, language: "ja", kind: kind, storageRootId: root.id,
          relativePaths: paths, pageCount: pageCount)
        var chapterInput = MetadataInput(
          kind: .chapter,
          title: chapter == 0 ? "Chapter 1 · Summer Rain" : "Chapter 2 · By the Station",
          originalLanguage: "ja",
          description: "An unexpected reunion by the station after the rain.",
          authorId: "a\(index % 3)", seriesId: index % 3 < 2 ? "s\(index % 3)" : nil,
          workId: "w\(index)",
          media: [version])
        chapterInput.sources = [.init(site: "pixiv", value: "123456")]
        session.entities.append(try entity(id, chapterInput))
        // Deliberately partial translated media exercises original-page fallback.
        if index == 0 && chapter == 0 {
          var translated = MediaVersion(
            id: "zh-" + id, language: "zh", kind: "images", storageRootId: root.id,
            relativePaths: Array(paths.prefix(3)), pageCount: 3)
          translated.pageAlignment = [0, 1, nil, nil, 2, nil]
          session.entities[session.entities.count - 1].media.append(translated)
        }
        // Device-local offline files let iPhone previews show actual thumbnails.
        if let cache = session.cacheDirectory {
          for version in session.entities.last!.media {
            let download = cache.appendingPathComponent("downloads/" + version.id)
            try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
            for (page, filename) in version.relativePaths.enumerated() {
              try Data(contentsOf: media.appendingPathComponent(filename)).write(
                to: download.appendingPathComponent(
                  "\(page)." + URL(fileURLWithPath: filename).pathExtension))
            }
            let fingerprint = Base64URL.encode(
              Data(
                SHA256.hash(
                  data: Data((root.id + "\0" + version.relativePaths.joined(separator: "\0")).utf8))
              ))
            try JSONEncoder().encode(["fingerprint": fingerprint]).write(
              to: download.appendingPathComponent("manifest.json"))
          }
        }
      }
    }
    var privateInput = MetadataInput(kind: .work, title: "Hidden fixture", authorId: "a0")
    privateInput.tagIds = ["t4"]
    session.entities.append(try entity("private", privateInput))
    let states: [[String: Any]] = [
      [
        "id": "p1", "entityId": "c0-0", "favorite": true, "starred": false,
        "progress": [
          "mediaId": "v-c0-0", "pageIndex": 2, "completed": false, "activeSeconds": 1080,
        ], "revision": 1, "updatedAt": "2026-10-13T20:00:00Z",
      ],
      [
        "id": "p2", "entityId": "c1-0", "favorite": false, "starred": true,
        "progress": ["mediaId": "v-c1-0", "pageIndex": 5, "completed": true, "activeSeconds": 720],
        "revision": 1, "updatedAt": "2026-10-12T20:00:00Z",
      ],
      [
        "id": "p3", "entityId": "w0", "favorite": true, "starred": false, "revision": 1,
        "updatedAt": "2026-10-13T20:00:00Z",
      ],
      [
        "id": "p4", "entityId": "w2", "favorite": false, "starred": true, "revision": 1,
        "updatedAt": "2026-10-13T20:00:00Z",
      ],
      [
        "id": "p5", "entityId": "c0-0", "pageIndex": 3, "favorite": true, "starred": true,
        "revision": 1, "updatedAt": "2026-10-13T20:00:00Z",
      ],
    ]
    session.states = try JSONDecoder().decode(
      [PersonalState].self, from: JSONSerialization.data(withJSONObject: states))
    session.status = "Preview data · no server connection"
    return library
  }
  static func drawPage(title: String, index: Int, page: Int, cover: Bool) throws -> Data {
    let size = CGSize(width: 360, height: 510)
    #if os(macOS)
      let image = NSImage(size: size)
      image.lockFocus()
      paint(title: title, index: index, page: page, cover: cover, size: size)
      image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
      else { throw StorageError.emptyChapter }
      return data
    #else
      let image = UIGraphicsImageRenderer(size: size).image { _ in
        paint(title: title, index: index, page: page, cover: cover, size: size)
      }
      return image.pngData()!
    #endif
  }
  private static func paint(title: String, index: Int, page: Int, cover: Bool, size: CGSize) {
    #if os(macOS)
      typealias Color = NSColor
      typealias Font = NSFont
      func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(rect: rect).fill()
      }
    #else
      typealias Color = UIColor
      typealias Font = UIFont
      func fill(_ rect: CGRect, _ color: UIColor) {
        color.setFill()
        UIBezierPath(rect: rect).fill()
      }
    #endif
    let colors: [Color] = [
      .init(red: 0.27, green: 0.45, blue: 0.47, alpha: 1),
      .init(red: 0.23, green: 0.41, blue: 0.6, alpha: 1),
      .init(red: 0.67, green: 0.42, blue: 0.27, alpha: 1),
      .init(red: 0.41, green: 0.4, blue: 0.56, alpha: 1),
      .init(red: 0.44, green: 0.55, blue: 0.39, alpha: 1),
      .init(red: 0.63, green: 0.34, blue: 0.41, alpha: 1),
    ]
    fill(CGRect(origin: .zero, size: size), cover ? colors[index % colors.count] : .white)
    if cover {
      fill(CGRect(x: 30, y: 90, width: 300, height: 230), .white.withAlphaComponent(0.1))
      fill(CGRect(x: 50, y: 115, width: 100, height: 250), .black.withAlphaComponent(0.12))
      fill(CGRect(x: 170, y: 80, width: 145, height: 260), .white.withAlphaComponent(0.08))
      (title as NSString).draw(
        in: CGRect(x: 26, y: 350, width: 300, height: 110),
        withAttributes: [
          .font: Font.systemFont(ofSize: 31, weight: .semibold), .foregroundColor: Color.white,
        ])
      ("NATIVE UI PREVIEW" as NSString).draw(
        at: CGPoint(x: 28, y: 40),
        withAttributes: [
          .font: Font.systemFont(ofSize: 11, weight: .medium),
          .foregroundColor: Color.white.withAlphaComponent(0.6),
        ])
    } else {
      for panel in 0..<3 {
        fill(
          CGRect(x: 20, y: 20 + panel * 160, width: 320, height: 140),
          colors[index % colors.count].withAlphaComponent(0.2))
        fill(CGRect(x: 22, y: 22 + panel * 160, width: 316, height: 3), .black)
      }
      ("Page \(page + 1)\nA quiet moment after the rain." as NSString).draw(
        in: CGRect(x: 45, y: 80, width: 255, height: 90),
        withAttributes: [.font: Font.systemFont(ofSize: 20), .foregroundColor: Color.black])
    }
  }
}
