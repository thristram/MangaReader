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
      VStack(alignment: .leading, spacing: 0) {
        if let savedSelection {
          PhoneSavedCollectionSwitch(selection: savedSelection)
          Divider().padding(.vertical, 8)
        }
        Text("Filters").font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
        filterRow(
          "All Items", symbol: "square.grid.2x2",
          selected: !library.unreadOnly && library.selectedTag == nil
        ) {
          library.unreadOnly = false
          library.selectedTag = nil
        }
        filterRow("Unread", symbol: "book.closed", selected: library.unreadOnly) {
          library.unreadOnly.toggle()
        }
        Menu {
          Picker("Tag", selection: $library.selectedTag) {
            Text("All Tags").tag(String?.none)
            ForEach(session.visibleEntities(kind: .tag)) { tag in
              Text(library.title(tag)).tag(Optional(tag.id))
            }
          }
        } label: {
          row(
            library.selectedTag.flatMap { library.entity($0).map(library.title) } ?? "Tags",
            symbol: "tag", selected: library.selectedTag != nil, disclosure: true)
        }.buttonStyle(.plain).accessibilityLabel("Filter by tag")
        Divider().padding(.vertical, 8)
        Menu {
          Picker("Sort by", selection: $library.sort) {
            ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
        } label: {
          row(
            library.sort.rawValue, symbol: "arrow.up.arrow.down", selected: false, disclosure: true)
        }.buttonStyle(.plain).accessibilityLabel("Sort by " + library.sort.rawValue)
      }
      .padding(12).frame(width: 310)
      .presentationCompactAdaptation(.popover)
    }
  }

  private func filterRow(
    _ title: String, symbol: String, selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) { row(title, symbol: symbol, selected: selected) }
      .buttonStyle(.plain)
      .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func row(
    _ title: String, symbol: String, selected: Bool,
    disclosure: Bool = false
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
        .opacity(selected ? 1 : 0).frame(width: 18).accessibilityHidden(true)
      Image(systemName: symbol).frame(width: 24).accessibilityHidden(true)
      Text(title).lineLimit(1)
      Spacer(minLength: 0)
      if disclosure {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
      }
    }.frame(minHeight: 44).contentShape(Rectangle())
  }
}
