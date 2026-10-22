import AppKit
import MangaCore
import SwiftUI

@MainActor enum PageBatchChecks {
  static func run(directory: URL) async throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
      if !condition() { throw LoginError.server("Page batch: " + message) }
    }
    let session = NativeUIFixtures.makeSession(cacheRoot: directory.appendingPathComponent("cache"))
    let library = try NativeUIFixtures.seed(session: session, directory: directory)
    defer { library.reset() }
    let chapter = session.entities.first { $0.id == "c0-0" }!
    let source = chapter.media[0]
    let root = session.entities.first { $0.id == source.storageRootId }!
    let sourceURLs = try await library.local.availableURLs(for: source)
    let bytes = try sourceURLs.map { try Data(contentsOf: $0) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let originalMetadata = try encoder.encode(chapter.input)
    var plan = try PageBatchPlan(metadata: chapter.input, mediaId: source.id, selected: [4, 5])
    try plan.setTranslation(language: "fr", alignment: [0, 1, nil, nil], id: "split-fr")
    let request = PageBatchRequest(chapter: chapter, plan: plan, translating: true)
    // Preparing/cancelling either UI step cannot change metadata or files.
    let unchangedMetadata = try encoder.encode(session.entities.first { $0.id == chapter.id }!.input)
    try check(unchangedMetadata == originalMetadata, "preparing a plan changed metadata")
    try check(sourceURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "preparing a plan moved files")
    let updated = try await library.commitPageBatch(request, plan: plan, destinationId: root.id)
    let translated = updated.media.first { $0.id == "split-fr" }!
    try check(translated.language == "fr" && translated.relativePaths.count == 2, "split translation missing")
    let translatedURLs = try await library.local.availableURLs(for: translated)
    let translatedBytes = try translatedURLs.map { try Data(contentsOf: $0) }
    try check(translatedBytes == Array(bytes.suffix(2)), "split pages lost reading order or contents")
    try check(updated.media.first { $0.id == source.id }?.pageCount == 4, "original still includes translated pages")
    try check(updated.description == chapter.description && updated.sources.count == chapter.sources.count,
              "page split changed chapter text or links")
    try check(updated.media.allSatisfy { media in media.relativePaths.allSatisfy { $0.contains("/" + media.language + "/") } },
              "split files did not enter language folders")
    var staleRejected = false
    do {
      _ = try await library.commitPageBatch(request, plan: plan, destinationId: root.id)
    } catch { staleRejected = true }
    try check(staleRejected && updated.revision != chapter.revision, "stale batch was not rejected")

    // A partial translated-version delete preserves canonical holes and protects shared originals.
    var sharedMedia = translated; sharedMedia.id = "shared-translation"
    let shared = try await session.create(.init(kind: .chapter, title: "Shared image", authorId: updated.authorId,
                                              media: [sharedMedia]))
    let deletion = try PageBatchPlan(metadata: updated.input, mediaId: translated.id, selected: [0])
    let deletionRequest = PageBatchRequest(chapter: updated, plan: deletion, translating: false)
    let deleted = try await library.commitPageBatch(deletionRequest, plan: deletion, destinationId: root.id)
    try check(deleted.media.first { $0.id == translated.id }?.pageAlignment == [nil, 0, nil, nil],
              "translated deletion did not fall back to original")
    try check(FileManager.default.fileExists(atPath: translatedURLs[0].path), "shared image was removed")
    let archive = try await library.local.readingRootURL(root.id)
    let recycled = archive.appendingPathComponent("Recycle/PageEdits/" + deletionRequest.id + "/1-" + translatedURLs[0].lastPathComponent)
    let recycledBytes = try Data(contentsOf: recycled)
    try check(recycledBytes == bytes[4], "deleted page has no verified Recycle copy")

    let ordinary = session.entities.first { $0.id == "c1-1" }!
    let ordinarySource = ordinary.media[0]
    let ordinaryURLs = try await library.local.availableURLs(for: ordinarySource)
    let deleteAll = try PageBatchPlan(metadata: ordinary.input, mediaId: ordinarySource.id,
      selected: Set(PageBatchPlan.readingOrder(ordinarySource)))
    let allRequest = PageBatchRequest(chapter: ordinary, plan: deleteAll, translating: false)
    let empty = try await library.commitPageBatch(allRequest, plan: deleteAll, destinationId: root.id)
    try check(empty.media.isEmpty && empty.title == ordinary.title, "all-page delete removed chapter metadata")
    try check(ordinaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "deleted originals survived without shared references")

    // Re-create an emptied chapter, append duplicate filenames safely, then add a new language.
    let fm = FileManager.default
    let incoming = directory.appendingPathComponent("additional-images")
    try fm.createDirectory(at: incoming.appendingPathComponent("other"), withIntermediateDirectories: true)
    let first = incoming.appendingPathComponent("page.png")
    let second = incoming.appendingPathComponent("other/page.png")
    try bytes[0].write(to: first)
    try bytes[1].write(to: second)
    let addRequest = AddImagesRequest(chapter: empty, files: [try ImportSourceAccess(first), try ImportSourceAccess(second)])
    let recreated = try await library.commitAddedImages(addRequest, language: "ja", destinationId: root.id)
    try check(recreated.media.count == 1 && recreated.media[0].pageCount == 2, "empty chapter was not recreated")
    let recreatedURLs = try await library.local.availableURLs(for: recreated.media[0])
    let recreatedBytes = try recreatedURLs.map { try Data(contentsOf: $0) }
    try check(recreatedBytes == Array(bytes.prefix(2)), "new image bytes or order changed")
    try check(Set(recreated.media[0].relativePaths).count == 2, "duplicate filenames were overwritten")
    try check(fm.fileExists(atPath: first.path) && fm.fileExists(atPath: second.path), "external images were moved")
    let newLanguage = AddImagesRequest(chapter: recreated, files: [try ImportSourceAccess(first)])
    let bilingual = try await library.commitAddedImages(newLanguage, language: "en", destinationId: root.id)
    try check(bilingual.media.count == 2 && bilingual.media.allSatisfy { media in
      media.relativePaths.allSatisfy { $0.contains("/" + media.language + "/") }
    }, "adding a language did not create language folders")
    let english = bilingual.media.first { $0.language == "en" }!
    let englishURL = try await library.local.url(for: english, file: 0)
    let englishFolder = englishURL.deletingLastPathComponent()
    let whole = try PageBatchPlan(metadata: bilingual.input, mediaId: english.id, selected: [], removeEntireVersion: true)
    let removeRequest = PageBatchRequest(chapter: bilingual, plan: whole, translating: false)
    let monolingual = try await library.commitPageBatch(removeRequest, plan: whole, destinationId: root.id)
    try check(monolingual.media.count == 1 && !fm.fileExists(atPath: englishFolder.path), "whole translation folder survived")
    let chapterFolder = (try await library.local.url(for: monolingual.media[0], file: 0)).deletingLastPathComponent().deletingLastPathComponent()
    try await library.deleteComic(monolingual)
    try check(!fm.fileExists(atPath: chapterFolder.path), "whole chapter folder survived deletion")

    let pdfChapter = session.entities.first { $0.id == "c5-1" }!
    let pdf = pdfChapter.media[0]
    let pdfPlan = try PageBatchPlan(metadata: pdfChapter.input, mediaId: pdf.id, selected: [], removeEntireVersion: true)
    let pdfRequest = PageBatchRequest(chapter: pdfChapter, plan: pdfPlan, translating: false)
    let removedPDF = try await library.commitPageBatch(pdfRequest, plan: pdfPlan, destinationId: root.id)
    try check(removedPDF.media.isEmpty, "sole PDF version could not be deleted")

    let replacementFolder = incoming.appendingPathComponent("replacement-translation")
    try fm.createDirectory(at: replacementFolder, withIntermediateDirectories: true)
    try bytes[0].write(to: replacementFolder.appendingPathComponent("1.png"))
    let replacementImport = ImportWorkspaceModel(library: library)
    replacementImport.append([replacementFolder])
    replacementImport.translationOf = removedPDF.id
    replacementImport.input.originalLanguage = "zh"
    replacementImport.destinationId = root.id
    await replacementImport.process(move: true)?.value
    try check(replacementImport.queue.isEmpty, "re-import into an empty chapter failed: " + replacementImport.status)
    let reimported = session.entities.first { $0.id == removedPDF.id }!
    try check(reimported.media.count == 1 && reimported.media[0].sourcePage(at: 0) == 0,
      "re-imported empty chapter has an empty page alignment")
    let reimportedURL = try await library.local.url(for: reimported.media[0], file: 0)
    try check(fm.fileExists(atPath: reimportedURL.path), "re-import did not recreate chapter directory")
    replacementImport.close()

    // A failed append persists picker grants and finishes from the same journal without duplicate pages.
    let appendFailure = session.entities.first { $0.id == "c3-1" }!
    let appendOriginal = try await library.local.url(for: appendFailure.media[0], file: 0)
    NativeUIFixtures.rejectedUpdateIds.insert(appendFailure.id)
    do {
      let adding = AddImagesRequest(chapter: appendFailure, files: [try ImportSourceAccess(first)])
      _ = try await library.commitAddedImages(adding, language: "ja", destinationId: root.id)
      throw LoginError.server("append metadata rejection did not fail")
    } catch {
      try check(fm.fileExists(atPath: appendOriginal.path), "failed append removed originals")
    }
    NativeUIFixtures.rejectedUpdateIds.remove(appendFailure.id)
    let journalDirectory = session.cacheDirectory!.appendingPathComponent("organization-journals")
    let pendingAppend = try fm.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try JSONDecoder().decode(OrganizationJournal.self, from: Data(contentsOf: $0)) }
      .first { $0.entityId == appendFailure.id && $0.phase != "complete" }!
    try check(pendingAppend.sourceBookmarks?.count == 1 && pendingAppend.cleanupFolders != nil,
      "append recovery lost source grants or directory cleanup")
    let stagedAppend = try FileOrganization.stage(pendingAppend, in: journalDirectory)
    try await session.update(appendFailure, input: stagedAppend.metadata)
    try FileOrganization.finish(stagedAppend, in: journalDirectory)
    try FileOrganization.finish(stagedAppend, in: journalDirectory)
    let recoveredAppend = session.entities.first { $0.id == appendFailure.id }!
    try check(recoveredAppend.media[0].pageCount == appendFailure.media[0].pageCount + 1,
      "append recovery duplicated or lost pages")
    try check(fm.fileExists(atPath: first.path), "append recovery removed selected external original")

    let failing = session.entities.first { $0.id == "c2-1" }!
    let failurePlan = try PageBatchPlan(metadata: failing.input, mediaId: failing.media[0].id, selected: [0])
    let failureRequest = PageBatchRequest(chapter: failing, plan: failurePlan, translating: false)
    let failureURL = try await library.local.url(for: failing.media[0], file: 0)
    NativeUIFixtures.rejectedUpdateIds.insert(failing.id)
    defer { NativeUIFixtures.rejectedUpdateIds.remove(failing.id) }
    do {
      _ = try await library.commitPageBatch(failureRequest, plan: failurePlan, destinationId: root.id)
      throw LoginError.server("metadata rejection did not fail")
    } catch {
      try check(FileManager.default.fileExists(atPath: failureURL.path), "metadata failure removed the original")
      let pending = try await library.pendingFileOrganizationIds()
      try check(pending.contains(failing.id), "metadata failure has no recoverable journal")
    }
    _ = shared
    var selection = Set<Int>()
    let host = NSHostingController(rootView: MacPageSelectionGrid(pages: [2, 0, 3, 1],
      selection: Binding(get: { selection }, set: { selection = $0 }), content: { AnyView(Text("Page \($0)")) }))
    let window = NSWindow(contentViewController: host)
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 800, height: 500)); window.orderFront(nil)
    WelcomeStateChecks.drain()
    func collection(_ view: NSView) -> NSCollectionView? {
      if let match = view as? NSCollectionView { return match }
      return view.subviews.lazy.compactMap(collection).first
    }
    let grid = collection(host.view)!
    try check(grid.allowsMultipleSelection && grid.isSelectable && grid.numberOfItems(inSection: 0) == 4,
              "native grid does not support multi-selection")
    let indexes: Set<IndexPath> = [IndexPath(item: 1, section: 0), IndexPath(item: 3, section: 0)]
    grid.selectItems(at: indexes, scrollPosition: [])
    (grid.delegate as! MacPageSelectionGrid.Coordinator).collectionView(grid, didSelectItemsAt: indexes)
    try check(selection == [0, 1], "native selection does not map visible reading order to source pages")
    window.close()
    print("PASS: native multi-selection/source mapping; prepare/cancel leaves files untouched; split translation preserves order and language folders; shared-image Recycle; all-page deletion; add images/recreate/language directories; whole-version and PDF deletion; chapter directory cleanup; stale revision refusal; metadata-failure recovery.")
  }
}
