import SwiftUI

enum PhoneSavedCollection: String, CaseIterable {
  case starred = "Starred"
  case pages = "Saved Pages"

  var symbol: String { self == .starred ? "star" : "photo.on.rectangle" }
}

struct PhoneSavedCollectionSwitch: View {
  @Binding var selection: PhoneSavedCollection
  var body: some View {
    HStack(spacing: 4) {
      ForEach(PhoneSavedCollection.allCases, id: \.self) { collection in
        Button {
          selection = collection
        } label: {
          VStack(spacing: 4) {
            Image(systemName: collection.symbol).font(.system(size: 18))
            Text(collection.rawValue).font(.caption)
          }
          .frame(maxWidth: .infinity).padding(.vertical, 8)
          .contentShape(RoundedRectangle(cornerRadius: 14))
          .background(
            selection == collection ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collection.rawValue)
        .accessibilityAddTraits(selection == collection ? [.isSelected] : [])
        .accessibilityIdentifier(
          "saved-collection-" + (collection == .starred ? "starred" : "pages"))
      }
    }.accessibilityIdentifier("saved-collection-switch")
  }
}

struct PhoneSavedCollectionScreen: View {
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @State private var selection: PhoneSavedCollection = .pages

  var body: some View {
    let pages = selection == .pages ? library.savedPages() : []
    let comics = selection == .starred ? library.collection(.starred) : []
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        let count = selection == .pages ? pages.count : comics.count
        Text("\(selection.rawValue) · \(count) \(count == 1 ? "item" : "items")")
          .font(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("saved-collection-summary")
        if selection == .pages {
          SavedPageGrid(bookmarks: pages)
        } else if comics.isEmpty {
          LibraryEmptyState(page: .starred).frame(maxWidth: .infinity).padding(.top, 55)
        } else {
          ComicGrid(entities: comics)
        }
      }.padding(contentPadding)
    }
    .refreshable { try? await session.synchronize() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        PhoneCollectionFilterButton(savedSelection: $selection)
      }.sharedBackgroundVisibility(.hidden)
    }
  }
}

/// A native popover keeps the collection switch and its filters together.
struct PhoneCollectionFilterButton: View {
  var savedSelection: Binding<PhoneSavedCollection>? = nil
  @EnvironmentObject private var library: LibraryUIModel
  @EnvironmentObject private var session: AppSession
  @State private var presented = false

  var body: some View {
    Button {
      presented = true
    } label: {
      Image(systemName: "line.3.horizontal.decrease").font(.title3)
        .frame(width: 44, height: 44)
        .glassEffect(.regular.interactive(), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Filter and Sort")
    .accessibilityIdentifier("collection-filter")
    .popover(isPresented: $presented, arrowEdge: .top) {
      CollectionFilterPanel {
        if let savedSelection {
          PhoneSavedCollectionSwitch(selection: savedSelection)
          Divider().padding(.vertical, 8)
        }
      }.presentationCompactAdaptation(.popover)
    }
  }
}
