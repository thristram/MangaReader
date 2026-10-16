import AppKit
import Foundation
import MangaCore
import SwiftUI

@main @MainActor struct WelcomeStateChecks {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }
  static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
  static func main() async throws {
    let defaults = UserDefaults.standard
    defaults.set("https://obsolete.invalid", forKey: "MangaAPIURL")
    defaults.set("https://obsolete.invalid/resource", forKey: "MangaAPIAudience")
    defaults.set(false, forKey: "ShowNSFW")
    defer {
      for key in ["MangaAPIURL", "MangaAPIAudience", "ShowNSFW"] {
        defaults.removeObject(forKey: key)
      }
    }
    expect(
      AppConfiguration.current().apiURL.absoluteString == Bundle.main.object(
        forInfoDictionaryKey: "MangaAPIURL") as? String,
      "obsolete runtime URL must not override project config")
    expect(
      AppConfiguration.current().audience == Bundle.main.object(
        forInfoDictionaryKey: "MangaAPIAudience") as? String,
      "obsolete audience must not override project config")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.finishLaunching()
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    let dropBoard = NSPasteboard.withUniqueName()
    defer { dropBoard.releaseGlobally() }
    let firstDrop = ImportWorkspaceModel(library: library)
    let dropHost = ImportDropHostingView(rootView: AnyView(Color.clear))
    dropHost.receive = { firstDrop.append($0) }
    dropHost.failure = { fatalError("Native first drop: \($0)") }
    let selected = directory.appendingPathComponent("media")
    expect(dropBoard.writeObjects([selected as NSURL]), "write native Finder URL representation")
    expect(dropHost.accept(dropBoard), "first native file drop is accepted without opening a picker")
    expect(!firstDrop.queue.isEmpty && firstDrop.sources.first?.url == selected,
           "native drop captures the original parent lease before scanning descendants")
    let count = firstDrop.queue.count
    dropHost.accepting = false
    expect(!dropHost.accept(dropBoard) && firstDrop.queue.count == count, "busy drop must be rejected")
    firstDrop.close()
    let hosting = NSHostingController(rootView: MangaRootScreen(session: session, library: library))
    hosting.sizingOptions = []
    let window = NSWindow(contentViewController: hosting)
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 1200, height: 800))
    _ = hosting.view
    drain()
    library.selection = .importing
    drain()
    hosting.view.layoutSubtreeIfNeeded()
    func nativeDrop(in view: NSView) -> ImportDropHostingView? {
      if let match = view as? ImportDropHostingView { return match }
      return view.subviews.lazy.compactMap { nativeDrop(in: $0) }.first
    }
    expect(nativeDrop(in: hosting.view).map { $0.bounds.width > 600 && $0.bounds.height > 300 } == true,
           "native drop destination must fill the import page, beyond the dashed box")
    library.selection = .library
    drain()
    expect(library.canManage, "Mac manager scope must enable editing")
    let blankSMB = SMBConnectionFailure(
      stage: .connecting,
      error: NSError(
        domain: NSPOSIXErrorDomain, code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Error code 1: "]))
    expect(
      blankSMB.localizedDescription.contains("Connecting to the encrypted SMB3 share failed")
        && blankSMB.localizedDescription.contains("no further detail")
        && blankSMB.localizedDescription.contains("NSPOSIXErrorDomain, 1"),
      "SMB error formatting must identify stage and handle a detail-free code")
    let detailedSMB = SMBConnectionFailure(
      stage: .identity,
      error: NSError(
        domain: NSPOSIXErrorDomain, code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Server denied access to the library"]))
    expect(
      detailedSMB.localizedDescription.contains("Verifying the library failed")
        && detailedSMB.localizedDescription.contains("Server denied access"),
      "SMB formatting preserves server detail and the failed operation")
    expect(library.collection(.library).count == 6, "NSFW work must be hidden")
    expect(library.collection(.history).count == 2, "history must contain chapters with progress")
    expect(
      library.collection(.continuing).count == 1,
      "completed chapters must not appear in Continue Reading")
    expect(
      library.children(session.entities.first { $0.id == "w0" }!).count == 2,
      "comic detail must list its chapters")
    library.query = "Haruka"
    expect(library.collection(.library).count == 2, "search must match authors")
    library.query = ""
    library.selectedTag = "t0"
    expect(library.collection(.library).count == 2, "tag filtering must select matching works")
    library.selectedTag = nil
    library.path = [.entity("w0"), .entity("c0-0")]
    drain()
    library.navigateBack()
    drain()
    expect(
      library.path == [.entity("w0")] && library.forwardPath == [.entity("c0-0")],
      "native back gesture must retain forward history")
    library.navigateForward()
    drain()
    expect(
      library.path == [.entity("w0"), .entity("c0-0")] && library.forwardPath.isEmpty,
      "forward gesture must restore the popped route")
    expect(
      library.taggedComics(session.entities.first { $0.id == "t0" }!).count == 2,
      "tag collection must count comics rather than duplicate chapter rows")
    let downloadWorks = ["w0", "w1"].map { id in session.entities.first { $0.id == id }! }
    for work in downloadWorks {
      for chapter in library.chapters(work) { library.removeDownload(chapter) }
    }
    for work in downloadWorks { library.download(work) }
    expect(library.activeDownloadCount == 2, "downloads must queue and count immediately")
    for _ in 0..<200 {
      if library.activeDownloadCount == 0 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    expect(
      library.activeDownloadCount == 0 && downloadWorks.allSatisfy(library.isDownloaded),
      "queued local downloads must finish with every chapter cached")
    expect(
      library.activities.allSatisfy { $0.completed && $0.progress == 1 },
      "completed pie progress must reach one")
    let retryChapter = session.entities.first { $0.id == "c0-0" }!
    library.removeDownload(retryChapter)
    let retryVersion = retryChapter.media[0]
    library.download(retryChapter)
    library.cancelDownload(retryChapter.id)
    for _ in 0..<100 {
      if library.activeDownloadCount == 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    expect(
      library.downloadActivity(retryChapter.id)?.failed == true,
      "cancelled downloads must remain retryable")
    let source = try library.local.urls(for: retryVersion)[0]
    let temporarilyMoved = source.appendingPathExtension("test-hidden")
    try FileManager.default.moveItem(at: source, to: temporarilyMoved)
    library.download(retryChapter)
    for _ in 0..<100 {
      if library.activeDownloadCount == 0 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    try FileManager.default.moveItem(at: temporarilyMoved, to: source)
    expect(
      library.downloadActivity(retryChapter.id)?.failed == true,
      "unavailable source must show retry state")
    library.download(retryChapter)
    for _ in 0..<100 {
      if library.activeDownloadCount == 0 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    expect(
      library.downloadActivity(retryChapter.id)?.completed == true,
      "retry must restart and complete without a popup")
    let tag = session.entities.first { $0.id == "t0" }!
    let taggedBefore = session.entities.filter { $0.tagIds.contains(tag.id) }
    let chapterCount = session.entities.filter { $0.kind == .chapter }.count
    var rename = tag.input
    rename.title = "Renamed inline"
    try await session.update(tag, input: rename)
    let renamed = session.entities.first { $0.id == tag.id }!
    expect(renamed.title == "Renamed inline", "tag renaming must save through the API")
    try await session.deleteTag(renamed)
    expect(
      !session.entities.contains { $0.id == tag.id || $0.tagIds.contains(tag.id) },
      "deleted tag must detach all references")
    expect(
      session.entities.filter { $0.kind == .chapter }.count == chapterCount,
      "deleting tags must keep every chapter")
    for old in taggedBefore {
      let current = session.entities.first { $0.id == old.id }!
      expect(
        current.media.map(\.id) == old.media.map(\.id) && current.title == old.title,
        "tag deletion must preserve media and titles")
    }
    let storage = session.entities.first { $0.id == "fixture-root" }!
    try await session.removeDestination(storage)
    expect(
      session.entities.first { $0.id == storage.id }?.isArchiveDestination == false,
      "removing a referenced destination must preserve its source binding")
    expect(
      library.cachedURLs(retryVersion) != nil,
      "comics must remain readable after removing their destination")

    // Covers and opening the reader must not inspect or fetch unrelated pages.
    let loadingChapter = session.entities.first { $0.id == "c0-0" }!
    var sparse = loadingChapter
    sparse.media[0].relativePaths.append("zz-missing-page.png")
    sparse.media[0].pageCount += 1
    let cover = await library.coverURL(sparse)
    expect(cover != nil, "cover must load even if an unrelated page is missing")
    let partialRoot = directory.appendingPathComponent("page-cache")
    try FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: true)
    let firstPage = partialRoot.appendingPathComponent("1.png")
    let secondPage = partialRoot.appendingPathComponent("2.png")
    let pageBytes = try Data(contentsOf: cover!)
    try pageBytes.write(to: firstPage)
    try pageBytes.write(to: secondPage)
    let partialMedia = MediaVersion(
      language: "zxx", kind: "images", storageRootId: "offline-only",
      relativePaths: ["1.png", "2.png"], pageCount: 2)
    _ = try await library.smb.download(
      partialMedia, localURLs: [firstPage, secondPage], indices: [0])
    let firstCached = try await library.smb.cachedPage(partialMedia, index: 0)
    let secondCached = try await library.smb.cachedPage(partialMedia, index: 1)
    expect(firstCached != nil && secondCached == nil, "reading one page must cache only that page")
    expect(
      library.smb.downloadedURLs(partialMedia) == nil,
      "partial reading cache must not count as a complete offline download")
    try FileManager.default.removeItem(at: firstPage)
    _ = try await library.smb.download(partialMedia, localURLs: [firstPage, secondPage])
    expect(
      library.smb.downloadedURLs(partialMedia)?.count == 2,
      "full download must reuse previously cached pages even if the original source disappeared")
    library.open(loadingChapter)
    for _ in 0..<50 {
      if library.reader != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    expect(
      library.reader?.urls.isEmpty == true,
      "reader must open before gathering or downloading a whole chapter")
    library.reader = nil
    // Regression: the first native page must fill the actual viewport, not its
    // hosting controller's initial ideal size, and must follow window resizing.
    let media = session.entities.first { $0.id == "c0-0" }!.media[0]
    let imageURL = library.cachedURLs(media)![0]
    let pager = NSHostingController(
      rootView:
        MacReaderPager(index: .constant(0), count: 1) { _ in
          AnyView(
            NativeReadingPage(url: imageURL, onSwipe: { _ in })
              .frame(maxWidth: .infinity, maxHeight: .infinity))
        })
    pager.sizingOptions = []
    let readerWindow = NSWindow(contentViewController: pager)
    readerWindow.isReleasedWhenClosed = false
    readerWindow.setContentSize(NSSize(width: 1200, height: 800))
    readerWindow.orderFront(nil)
    readerWindow.orderFront(nil)
    drain()
    func viewport(in view: NSView) -> MacReadingViewport? {
      if let viewport = view as? MacReadingViewport { return viewport }
      for child in view.subviews { if let result = viewport(in: child) { return result } }
      return nil
    }
    // Pages now decode only after appearing; wait for the asynchronous image,
    // rather than assuming a hidden window synchronously reads its source.
    for _ in 0..<200 {
      if viewport(in: pager.view) != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let firstViewport = viewport(in: pager.view)
    expect(firstViewport != nil, "native pager must mount an image viewport")
    expect(firstViewport!.bounds.height > 750, "first page must fill the window height")
    expect(
      abs(firstViewport!.image.frame.height - firstViewport!.bounds.height) < 1,
      "image must fit viewport height")
    readerWindow.setContentSize(NSSize(width: 900, height: 500))
    drain()
    expect(
      abs(firstViewport!.bounds.height - pager.view.bounds.height) < 1,
      "native page must resize with its window")
    readerWindow.close()

    let sourceWork = session.entities.first { $0.id == "w2" }!
    let sourceChapters = session.entities.filter { $0.workId == sourceWork.id && !$0.deleted }
    let originalPaths = try sourceChapters.flatMap(\.media).flatMap {
      try library.local.urls(for: $0)
    }
    try await library.deleteComic(sourceWork)
    expect(
      !session.entities.contains { $0.id == sourceWork.id || $0.workId == sourceWork.id },
      "deleting a comic must remove its chapters before the parent")
    expect(
      originalPaths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
      "unarchived original files must survive comic deletion")
    let archiveRoot = try await session.create(
      .init(kind: .storageRoot, title: "Archive Test", storageKind: "local"))
    let archiveDirectory = directory.appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
    try library.local.bind(archiveRoot, to: archiveDirectory)
    let relative = "Author/Archived Chapter/1.png"
    let archivedFile = try PathPolicy.resolve(relative, under: archiveDirectory)
    try FileManager.default.createDirectory(
      at: archivedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let archivedBytes = try Data(contentsOf: imageURL)
    try archivedBytes.write(to: archivedFile)
    let archivedMedia = MediaVersion(
      language: "ja", kind: "images", storageRootId: archiveRoot.id, relativePaths: [relative],
      pageCount: 1)
    let archivedInput = MetadataInput(
      kind: .chapter, title: "Archive Test Chapter", media: [archivedMedia])
    let firstReference = try await session.create(archivedInput)
    let lastReference = try await session.create(archivedInput)
    try await library.deleteComic(firstReference)
    expect(
      FileManager.default.fileExists(atPath: archivedFile.path),
      "a file referenced by another comic must not be recycled yet")
    NativeUIFixtures.rejectedDeleteIds.insert(lastReference.id)
    do {
      try await library.deleteComic(lastReference)
      expect(false, "fixture must reject this deletion")
    } catch is APIError {}
    NativeUIFixtures.rejectedDeleteIds.remove(lastReference.id)
    let restoredBytes = try Data(contentsOf: archivedFile)
    expect(
      library.entity(lastReference.id) != nil && restoredBytes == archivedBytes,
      "metadata failure must restore the archived files and keep the comic record")
    try await library.deleteComic(lastReference)
    expect(
      library.entity(lastReference.id) == nil
        && !FileManager.default.fileExists(atPath: archivedFile.path),
      "successful archived deletion must remove its record and original path")
    let recycled = FileManager.default.enumerator(
      at: archiveDirectory.appendingPathComponent("Recycle"), includingPropertiesForKeys: nil)!
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }
    expect(recycled.count == 1, "exactly one exclusive archive file must enter Recycle")
    let recycledBytes = try Data(contentsOf: recycled[0])
    expect(
      recycledBytes == archivedBytes,
      "archived bytes must remain recoverable inside Recycle")

    // Queue work survives closing the import UI and owns a frozen metadata snapshot.
    let queueDestination = try await session.create(
      .init(kind: .storageRoot, title: "Queue Destination", storageKind: "local"))
    let queueFolder = directory.appendingPathComponent("queue-library")
    try FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
    try library.local.bind(queueDestination, to: queueFolder)
    let queueSource = directory.appendingPathComponent("Queue Translation")
    try FileManager.default.createDirectory(at: queueSource, withIntermediateDirectories: true)
    try archivedBytes.write(to: queueSource.appendingPathComponent("1.png"))
    let queueImporter = ImportWorkspaceModel(library: library)
    queueImporter.append([queueSource])
    queueImporter.input.originalLanguage = "ja"
    queueImporter.input.workId = "w0"
    queueImporter.input.authorId = session.entities.first { $0.id == "w0" }!.authorId
    queueImporter.destinationId = queueDestination.id
    queueImporter.enqueue(move: true)
    expect(
      queueImporter.queue.isEmpty && !queueImporter.review,
      "commit must immediately dismiss review and release the import UI")
    queueImporter.input.title = "Edited after enqueue"
    queueImporter.close()
    for _ in 0..<500 {
      if library.fileQueue.items.last?.completed == true
        || library.fileQueue.items.last?.failed == true
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    expect(
      library.fileQueue.items.last?.completed == true,
      "queued import must finish after UI closure: " + (library.fileQueue.items.last?.status ?? ""))
    let queuedChapter = session.entities.first {
      $0.kind == .chapter && $0.title == "Queue Translation"
    }!
    let oldRelative = queuedChapter.media[0].relativePaths[0]
    let translatedSource = directory.appendingPathComponent("English Pages")
    try FileManager.default.createDirectory(at: translatedSource, withIntermediateDirectories: true)
    try archivedBytes.write(to: translatedSource.appendingPathComponent("1.png"))
    let translationImporter = ImportWorkspaceModel(library: library)
    translationImporter.append([translatedSource])
    translationImporter.translationOf = queuedChapter.id
    translationImporter.isTranslation = true
    translationImporter.input.title = ""
    translationImporter.input.description = "An English chapter description."
    translationImporter.input.originalLanguage = "en"
    expect(translationImporter.canSubmit, "translation can submit without a hidden chapter title")
    translationImporter.defaultDestination()
    expect(
      translationImporter.destinationId == queueDestination.id,
      "destination must default to the existing chapter's library")
    translationImporter.enqueue(move: true)
    translationImporter.close()
    for _ in 0..<500 {
      if library.fileQueue.items.last?.completed == true
        || library.fileQueue.items.last?.failed == true
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    expect(
      library.fileQueue.items.last?.completed == true,
      "translation queue must organize existing and imported media: "
        + (library.fileQueue.items.last?.status ?? ""))
    var translated = session.entities.first { $0.id == queuedChapter.id }!
    expect(translated.media.count == 2, "translation must extend the same chapter")
    expect(
      translated.title == queuedChapter.title && translated.description == queuedChapter.description
        && translated.localizations["en"]?.description == "An English chapter description.",
      "translation description belongs to media language without replacing original text")
    expect(
      translated.media[0].relativePaths[0].contains("/ja/")
        && translated.media[1].relativePaths[0].contains("/en/"),
      "both original and translated media must move into language folders")
    expect(
      !FileManager.default.fileExists(atPath: queueFolder.appendingPathComponent(oldRelative).path),
      "old flat file must be removed after metadata commits")
    for media in translated.media {
      let url = try await library.mediaURL(media, index: 0)
      let bytes = try Data(contentsOf: url)
      expect(bytes == archivedBytes, "organized media must preserve exact file bytes")
    }
    expect(
      !FileManager.default.fileExists(
        atPath: translatedSource.appendingPathComponent("1.png").path),
      "translation source must be cleaned only after successful commit")
    // Correct an already imported media language through the actual commit
    // service. Merely reviewing/cancelling a plan must not mutate anything.
    let translationId = translated.media[1].id
    let oldTranslationURL = try await library.mediaURL(translated.media[1], index: 0)
    let oldLanguageFolder = oldTranslationURL.deletingLastPathComponent()
    try Data("sidecar".utf8).write(to: oldLanguageFolder.appendingPathComponent("notes.txt"))
    let correction = try MediaLanguageChangePlan(
      metadata: translated.input, mediaId: translationId, language: "zh")
    let correctedFolder = queueFolder.appendingPathComponent(correction.destinationDirectory!)
    expect(
      library.entity(translated.id)?.media[1].language == "en"
        && FileManager.default.fileExists(atPath: oldLanguageFolder.path)
        && !FileManager.default.fileExists(atPath: correctedFolder.path),
      "language review alone must leave metadata and source paths unchanged")
    let staleReview = MediaLanguageReview(chapter: translated, plan: correction)
    try await session.update(translated, input: translated.input)
    do {
      _ = try await library.commitMediaLanguageChange(staleReview)
      expect(false, "stale language review must not move files")
    } catch {}
    translated = library.entity(translated.id)!
    let beforeCorrection = translated
    translated = try await library.commitMediaLanguageChange(
      .init(chapter: translated, plan: correction))
    expect(
      translated.media[1].language == "zh" && translated.media[1].id == translationId
        && translated.media[1].pageAlignment == beforeCorrection.media[1].pageAlignment
        && translated.media[0].relativePaths == beforeCorrection.media[0].relativePaths
        && translated.localizations == beforeCorrection.localizations,
      "language correction preserves identity, alignment, original version and text locales")
    let correctedURL = try await library.mediaURL(translated.media[1], index: 0)
    let correctedBytes = try Data(contentsOf: correctedURL)
    let sidecarBytes = try Data(contentsOf: correctedFolder.appendingPathComponent("notes.txt"))
    expect(
      correctedBytes == archivedBytes && sidecarBytes == Data("sidecar".utf8)
        && !FileManager.default.fileExists(atPath: oldLanguageFolder.path),
      "whole language folder is renamed without dropping sidecar files")
    let failedCorrection = try MediaLanguageChangePlan(
      metadata: translated.input, mediaId: translationId, language: "ko")
    NativeUIFixtures.rejectedUpdateIds.insert(translated.id)
    do {
      _ = try await library.commitMediaLanguageChange(
        .init(chapter: translated, plan: failedCorrection))
      expect(false, "rejected metadata update must leave a recoverable commit")
    } catch {
      expect(
        error is MediaLanguageCommitFailure, "file staging failure must request journal recovery")
    }
    NativeUIFixtures.rejectedUpdateIds.remove(translated.id)
    let pendingFolder = queueFolder.appendingPathComponent(failedCorrection.destinationDirectory!)
    expect(
      library.entity(translated.id)?.media[1].language == "zh"
        && FileManager.default.fileExists(atPath: correctedFolder.path)
        && FileManager.default.fileExists(atPath: pendingFolder.path),
      "metadata failure keeps original readable and new folder available for recovery")
    let commitDirectory = session.cacheDirectory!.appendingPathComponent("commit-journals")
    let pendingMove = try FileManager.default.contentsOfDirectory(
      at: commitDirectory, includingPropertiesForKeys: nil
    ).compactMap { url -> MoveJournal? in
      guard url.pathExtension == "json", !url.lastPathComponent.hasSuffix("-metadata.json") else {
        return nil
      }
      return try? JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: url))
    }.first { $0.destination == pendingFolder.path && $0.phase == "filesMoved_metadataPending" }!
    try await session.update(translated, input: failedCorrection.metadata)
    try FileCommit.finish(pendingMove, in: commitDirectory)
    translated = library.entity(translated.id)!
    expect(
      translated.media[1].language == "ko"
        && !FileManager.default.fileExists(atPath: correctedFolder.path),
      "existing commit recovery completes the corrected language folder")
    // Shared media keeps its old folder, while the corrected version gets its
    // own verified copy. An unrelated destination folder is never overwritten.
    var sharedTranslation = translated.media[1]
    sharedTranslation.id = UUID().uuidString
    _ = try await session.create(
      .init(
        kind: .chapter, title: "Shared language source", authorId: translated.authorId,
        workId: translated.workId, media: [sharedTranslation]))
    let sharedCorrection = try MediaLanguageChangePlan(
      metadata: translated.input, mediaId: translationId, language: "en")
    translated = try await library.commitMediaLanguageChange(
      .init(chapter: translated, plan: sharedCorrection))
    expect(
      FileManager.default.fileExists(atPath: pendingFolder.path),
      "shared source folder must remain readable")
    let collisionFolder = queueFolder.appendingPathComponent(correction.destinationDirectory!)
    try FileManager.default.createDirectory(at: collisionFolder, withIntermediateDirectories: true)
    try Data("unrelated".utf8).write(to: collisionFolder.appendingPathComponent("other.txt"))
    do {
      _ = try await library.commitMediaLanguageChange(
        .init(
          chapter: translated,
          plan: try MediaLanguageChangePlan(
            metadata: translated.input, mediaId: translationId, language: "zh")))
      expect(false, "an existing target folder must block language correction")
    } catch {
      expect(
        !(error is MediaLanguageCommitFailure),
        "preflight collision does not create a pending commit")
    }
    let unrelatedBytes = try Data(contentsOf: collisionFolder.appendingPathComponent("other.txt"))
    expect(unrelatedBytes == Data("unrelated".utf8), "language collision preserves unrelated files")
    print(
      "PASS: media-language review/cancel, stale revision rejection, verified folder correction, metadata failure recovery, shared sources and collision refusal."
    )
    // Retry a failed job after the import screen closes, without reimporting or
    // discarding its original source lease, bookmark, or entered metadata.
    let retrySource = directory.appendingPathComponent("134675894_お帰りなさい")
    try FileManager.default.createDirectory(at: retrySource, withIntermediateDirectories: true)
    try archivedBytes.write(to: retrySource.appendingPathComponent("1.png"))
    let retryImporter = ImportWorkspaceModel(library: library)
    retryImporter.append([retrySource])
    expect(retryImporter.input.title == "お帰りなさい", "strip Pixiv prefix from imported title")
    expect(
      retryImporter.input.sources.first { $0.site == "pixiv" }?.value == "134675894",
      "fill Pixiv ID when selecting import candidate")
    weak var retainedSource = retryImporter.sources.first
    retryImporter.destinationId = queueDestination.id
    retryImporter.input.authorId = translated.authorId
    retryImporter.input.workId = translated.workId
    let marker = queueFolder.appendingPathComponent(LibraryDestinationIdentity.filename)
    let heldMarker = queueFolder.appendingPathComponent("held-marker.json")
    try FileManager.default.moveItem(at: marker, to: heldMarker)
    retryImporter.enqueue(move: true)
    retryImporter.close()
    for _ in 0..<500 {
      if library.fileQueue.items.last?.failed == true { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    expect(library.fileQueue.items.last?.failed == true, "simulate destination access failure")
    expect(
      retainedSource != nil, "failed job retains original grant after workspace and worker close")
    let retryJob = library.fileQueue.items.last!.id
    try FileManager.default.moveItem(at: heldMarker, to: marker)
    library.fileQueue.retry(retryJob)
    for _ in 0..<500 {
      if library.fileQueue.items.last?.completed == true
        || library.fileQueue.items.last?.failed == true
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    expect(
      library.fileQueue.items.last?.completed == true,
      "retry completes without reimport: " + (library.fileQueue.items.last?.status ?? ""))
    expect(retainedSource == nil, "completed retry releases its shared source lease")
    // One directory grant must survive several independently queued descendant
    // chapters, including a PDF, after the import workspace has closed.
    let batchFolder = directory.appendingPathComponent("Batch Selection")
    for name in ["Collection One/Chapter A", "Collection One/Chapter B"] {
      let folder = batchFolder.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try archivedBytes.write(to: folder.appendingPathComponent("1.png"))
      try archivedBytes.write(to: folder.appendingPathComponent("2.png"))
    }
    let pdfFolder = batchFolder.appendingPathComponent("Collection Two")
    try FileManager.default.createDirectory(at: pdfFolder, withIntermediateDirectories: true)
    let pdfMedia = session.entities.flatMap(\.media).first { $0.kind == "pdf" }!
    let pdfBytes = try Data(contentsOf: try await library.mediaURL(pdfMedia, index: 0))
    let incomingPDF = pdfFolder.appendingPathComponent("Batch PDF.pdf")
    try pdfBytes.write(to: incomingPDF)
    let rootsBeforeBatch = Set(session.entities.filter { $0.kind == .storageRoot }.map(\.id))
    let batchStart = library.fileQueue.items.count
    let batchImporter = ImportWorkspaceModel(library: library)
    batchImporter.append([batchFolder])
    expect(
      batchImporter.queue.count == 3, "nested selection discovers two image chapters and a PDF")
    let batchCandidates = batchImporter.queue
    while !batchImporter.queue.isEmpty {
      batchImporter.input.originalLanguage = "ja"
      batchImporter.input.authorId = translated.authorId
      batchImporter.input.workId = translated.workId
      batchImporter.destinationId = queueDestination.id
      batchImporter.enqueue(move: true)
    }
    batchImporter.close()
    for _ in 0..<500 {
      let jobs = library.fileQueue.items.dropFirst(batchStart)
      if jobs.allSatisfy({ $0.completed }) || jobs.contains(where: { $0.failed }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let batchJobs = library.fileQueue.items.dropFirst(batchStart)
    expect(
      batchJobs.count == 3 && batchJobs.allSatisfy { $0.completed },
      "all nested chapters move after UI closure: "
        + batchJobs.map(\.status).joined(separator: "; "))
    let batchRoots = session.entities.filter {
      $0.kind == .storageRoot && !rootsBeforeBatch.contains($0.id)
    }
    expect(batchRoots.count == 1, "descendant chapters share their explicitly selected source root")
    library.local.release()
    let reboundBatchFolder = try library.local.rootURL(batchRoots[0].id)
    expect(
      reboundBatchFolder.resolvingSymlinksInPath() == batchFolder.resolvingSymlinksInPath(),
      "source bookmark must still point to selected parent after child directories moved")
    for candidate in batchCandidates {
      expect(
        !FileManager.default.fileExists(atPath: candidate.source.path),
        "completed child source is removed independently")
      let chapter = session.entities.first { $0.kind == .chapter && $0.title == candidate.title }!
      expect(
        chapter.media[0].storageRootId == queueDestination.id,
        "each nested chapter references the archive root")
      let url = try await library.mediaURL(chapter.media[0], index: 0)
      let bytes = try Data(contentsOf: url)
      expect(
        bytes == (candidate.kind == "pdf" ? pdfBytes : archivedBytes),
        "nested image/PDF bytes survive queue movement")
    }
    // Add-only imports use the same granted parent and retain nested paths.
    let keptSelection = directory.appendingPathComponent("Kept Selection")
    let keptChapter = keptSelection.appendingPathComponent("Nested/Kept Chapter")
    try FileManager.default.createDirectory(at: keptChapter, withIntermediateDirectories: true)
    try archivedBytes.write(to: keptChapter.appendingPathComponent("1.png"))
    let keptImporter = ImportWorkspaceModel(library: library)
    keptImporter.append([keptSelection])
    keptImporter.input.authorId = translated.authorId
    keptImporter.input.workId = translated.workId
    await keptImporter.process(move: false)?.value
    expect(keptImporter.queue.isEmpty, "add-only nested chapter completes: " + keptImporter.status)
    keptImporter.close()
    library.local.release()
    let keptEntity = session.entities.first { $0.title == "Kept Chapter" && $0.kind == .chapter }!
    expect(
      keptEntity.media[0].relativePaths == ["Nested/Kept Chapter/1.png"],
      "add-only chapter keeps its full path relative to selected parent")
    let keptURL = try await library.mediaURL(keptEntity.media[0], index: 0)
    let keptBytes = try Data(contentsOf: keptURL)
    expect(keptBytes == archivedBytes, "nested add-only media reopens after release")
    let singleLanguage = keptEntity.media[0].language == "en" ? "ja" : "en"
    let singleCorrection = try MediaLanguageChangePlan(
      metadata: keptEntity.input, mediaId: keptEntity.media[0].id, language: singleLanguage)
    let correctedSingle = try await library.commitMediaLanguageChange(
      .init(chapter: keptEntity, plan: singleCorrection))
    expect(
      correctedSingle.media[0].language == singleLanguage
        && correctedSingle.media[0].relativePaths == keptEntity.media[0].relativePaths
        && correctedSingle.originalLanguage == keptEntity.originalLanguage,
      "single media correction commits language without adding a folder or changing text language")
    // Deleting one chapter must preserve its parent and sibling chapters.
    let siblingInput = MetadataInput(
      kind: .chapter, title: "Sibling", authorId: translated.authorId,
      workId: translated.workId, media: [])
    let sibling = try await session.create(siblingInput)
    try await library.deleteComic(translated)
    expect(
      session.entities.contains { $0.id == sibling.id }
        && session.entities.contains { $0.id == "w0" },
      "single chapter deletion must preserve siblings and parent comic")
    if let mount = ProcessInfo.processInfo.environment["MANGA_TEST_SECOND_VOLUME"] {
      let destination = URL(fileURLWithPath: mount).appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: destination) }
      let root = try await session.create(
        .init(kind: .storageRoot, title: "Cross-volume Test", storageKind: "local"))
      try library.local.bind(root, to: destination)
      let incoming = directory.appendingPathComponent("Cross Volume Import Test")
      try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
      try archivedBytes.write(to: incoming.appendingPathComponent("1.png"))
      let importer = ImportWorkspaceModel(library: library)
      importer.append([incoming])
      importer.destinationId = root.id
      importer.process(move: true)
      for _ in 0..<500 {
        if !importer.busy { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      expect(
        !importer.busy && importer.queue.isEmpty,
        "cross-volume import must commit files and metadata: " + importer.status)
      guard
        let imported = session.entities.first(where: {
          $0.kind == .chapter && $0.title == "Cross Volume Import Test"
        })
      else {
        expect(false, "imported chapter must exist")
        return
      }
      expect(
        imported.media[0].storageRootId == root.id,
        "imported chapter must point to the chosen manual destination")
      let importedURLs = try library.local.urls(for: imported.media[0])
      expect(
        importedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
          && !FileManager.default.fileExists(atPath: incoming.path),
        "originals must be removed only after the cross-volume metadata update")
      try await library.deleteComic(imported)
      expect(
        library.entity(imported.id) == nil
          && !FileManager.default.fileExists(atPath: importedURLs[0].path),
        "a newly moved comic must recycle through the normal deletion flow")
      let recycleFiles = FileManager.default.enumerator(
        at: destination.appendingPathComponent("Recycle"), includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }
      expect(
        recycleFiles.count == 1,
        "the cross-volume import must retain its bytes in Recycle after deletion")
      let preserved = try Data(contentsOf: recycleFiles[0])
      expect(preserved == archivedBytes, "move and recycle must preserve exact image bytes")
    }

    let chapter = session.entities.first { $0.id == "c0-0" }!
    library.reader = ReadingContext(
      chapter: chapter, version: chapter.media[0], urls: library.cachedURLs(chapter.media[0])!,
      page: 3)
    library.editor = .init(entity: chapter, kind: .chapter)
    library.path = [.entity("w0")]
    drain()
    var next = session.account!
    next.ownerId = "another-fixture-owner"
    session.account = next
    drain()
    expect(
      library.reader == nil && library.editor == nil && library.path.isEmpty,
      "account change must dismiss private presentations and clear navigation")
    session.account = nil
    drain()
    expect(
      !library.canManage && library.reader == nil,
      "signed-out app must not offer management/readers")
    session.login()
    for _ in 0..<100 {
      if !session.busy { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    expect(
      session.account == nil && !session.busy
        && session.status == "Sign-in is not configured for this build.",
      "unconfigured sign-in must fail locally and remain retryable")
    window.close()
    try await ReaderControlsChecks.run(directory: directory.appendingPathComponent("reader-controls"))
    try await AuthorRemovalChecks.run(directory: directory.appendingPathComponent("author-removal"))
    try await ImportResponsivenessChecks.run(directory: directory.appendingPathComponent("import-response"))
    try await SingleFileImportChecks.run(directory: directory.appendingPathComponent("single-file-import"))
    print(
      "PASS: asynchronous single-file cover despite missing unrelated page; per-page cache and reuse without original source; reader opens without whole-chapter file scan; background import survives UI closure and snapshots metadata; translation relocates both languages before source cleanup; nested image/PDF batch moves share selected parent bookmark; add-only nested paths reopen after source release; single chapter deletion preserves siblings and parent; real cross-volume import/API commit/recycle when test volume is provided; unarchived comic deletion preserving originals; archived comic recycling; shared-file protection; API failure restores files; tag rename/delete without deleting comics; destination removal without losing media; download queue/progress/failure/retry; native pager first layout/resize; SwiftUI account gating/reset; NSFW, history, collections, author search and tag filters; build endpoint policy; retryable sign-in error. No server calls."
    )
  }
}
