#if os(iOS) || os(macOS)
import SwiftUI

extension CollectionViewMode {
    var toggled: CollectionViewMode { self == .grid ? .list : .grid }
}

struct CollectionViewModeToggle: View {
    @Binding var mode: CollectionViewMode

    var body: some View {
        Button {
            withAnimation(.smooth) { mode = mode.toggled }
        } label: {
            Label("View as \(mode.toggled.title)", systemImage: mode.toggled.symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .help("View as \(mode.toggled.title)")
    }
}

struct LibraryCollectionPlayButtons: View {
    @ObservedObject var model: LibraryCollectionsModel
    let items: [LibraryGridItem]
    var fills = true
    var isCompact = false
    let play: (_ tracks: [Track], _ shuffled: Bool) -> Void

    @State private var isPreparing = false

    var body: some View {
        CollectionHeroPlayButtons(
            isEnabled: !items.isEmpty && !isPreparing,
            fills: fills,
            isCompact: isCompact,
            onPlay: { start(shuffled: false) },
            onShuffle: { start(shuffled: true) }
        )
    }

    private func start(shuffled: Bool) {
        isPreparing = true
        Task {
            let tracks = await model.tracks(of: items)
            isPreparing = false
            guard !tracks.isEmpty else { return }
            play(tracks, shuffled)
        }
    }
}

#if os(iOS)
private struct LibraryPageTitleDisplayMode: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)
    }
}

extension View {
    func libraryPageTitleDisplayMode() -> some View {
        modifier(LibraryPageTitleDisplayMode())
    }

    func libraryPageSearchable(text: Binding<String>, prompt: String, alwaysShown: Bool = true) -> some View {
        searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: alwaysShown ? .always : .automatic),
            prompt: Text(prompt)
        )
    }
}
#endif

struct LibraryCollectionGrid<Menu: View>: View {
    let items: [LibraryGridItem]
    var minimumTile: CGFloat = 160
    var play: ((LibraryGridItem) -> Void)?
    @ViewBuilder var menu: (LibraryGridItem) -> Menu

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumTile, maximum: minimumTile * 1.5), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 24
        ) {
            ForEach(items) { item in
                tile(item)
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: LibraryGridItem) -> some View {
        #if os(macOS)
        NavigationLink(value: item.route) {
            LibraryCollectionTile(item: item)
        }
        .buttonStyle(.plain)
        .macCardHover(
            shape: item.isCircular ? .circle : .rounded,
            play: play.map { action -> () -> Void in { action(item) } }
        ) {
            menu(item)
            LibraryAlbumLinkMenuItems(route: item.route)
        }
        .help(item.title)
        #else
        NavigationLink(value: item.route) {
            LibraryCollectionTile(item: item)
        }
        .buttonStyle(.plain)
        .libraryTilePreviewShape()
        .contextMenu {
            menu(item)
            LibraryAlbumLinkMenuItems(route: item.route)
        }
        #endif
    }
}

struct LibraryCollectionTile: View {
    let item: LibraryGridItem

    var body: some View {
        VStack(alignment: item.isCircular ? .center : .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { artwork }
                .clipShape(artworkShape)
                .contentShape(artworkShape)
                #if os(iOS)
                .contentShape(.hoverEffect, artworkShape)
                .hoverEffect(.lift)
                #endif
                .padding(.bottom, 4)

            Text(item.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(item.subtitle)
                    .lineLimit(1)
                if item.sources.contains(.files) && item.sources.contains(.soundCloud) {
                    LibrarySourceMarks(sources: item.sources)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: item.isCircular ? .center : .leading)
        .multilineTextAlignment(item.isCircular ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
    }

    @ViewBuilder
    private var artwork: some View {
        #if os(macOS)
        GeometryReader { proxy in
            ArtworkThumbnail(
                url: item.artworkURL,
                identity: item.id,
                size: proxy.size.width,
                cornerRadius: item.isCircular ? proxy.size.width / 2 : 8
            )
        }
        #else
        ArtworkImage(url: item.artworkURL, variant: .standard) {
            ArtworkPlaceholder(icon: item.isCircular ? "person.fill" : "square.stack", identity: item.id)
        }
        #endif
    }

    private var artworkShape: AnyShape {
        item.isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct LibraryCollectionStates<Content: View>: View {
    @ObservedObject var model: LibraryCollectionsModel
    var minimumTile: CGFloat = 160
    var addFolder: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if model.items.isEmpty {
            if model.isLoading {
                LoadingPlaceholder(.grid(minimumTile: minimumTile, circular: model.kind == .artists))
            } else if let failure = model.failure {
                ContentUnavailableView {
                    Label("Couldn’t Load \(model.kind.title)", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { Task { await model.load(force: true) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(model.kind.emptyTitle, systemImage: model.kind.symbol)
                } description: {
                    Text(model.kind.emptyMessage)
                } actions: {
                    if let addFolder {
                        Button("Add Folder…", action: addFolder)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            content()
        }
    }
}
#endif
