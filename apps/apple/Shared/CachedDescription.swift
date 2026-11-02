import MangaCore
import SwiftUI

/// Segmentation and caching happen off the UI actor. Lazy blocks avoid measuring
/// an entire novel before the reader's first frame or on every page change.
struct CachedDescription: View {
  let text: String
  var font: Font = .body
  @EnvironmentObject private var session: AppSession
  @State private var blocks: [String] = []
  @State private var loaded: String?
  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      if loaded == text {
        ForEach(blocks.indices, id: \.self) { index in
          Text(verbatim: blocks[index]).font(font).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else { ProgressView().controlSize(.small) }
    }
    .task(id: text) {
      let result = await DescriptionTextCache.shared.blocks(text, owner: session.account?.ownerId ?? "")
      guard !Task.isCancelled else { return }
      blocks = result; loaded = text
    }
  }
}

struct CollectionDescription: View {
  let entity: LibraryEntity
  @State private var expanded = false
  private var text: String { entity.description(in: AppConfiguration.preferredLanguage) }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Never lay out the full novel just to enter a chapter/collection.
      Text(verbatim: String(text.prefix(600))).foregroundStyle(.secondary).textSelection(.enabled)
      if !text.dropFirst(600).isEmpty {
        Button("Read Description", systemImage: "text.alignleft") { expanded = true }
      }
    }
    .sheet(isPresented: $expanded) {
      NavigationStack {
        ReaderChapterDescription(title: entity.title(in: AppConfiguration.preferredLanguage),
          description: text, sources: entity.sources).padding(20)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } } }
      }
      #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
      #endif
    }
  }
}
