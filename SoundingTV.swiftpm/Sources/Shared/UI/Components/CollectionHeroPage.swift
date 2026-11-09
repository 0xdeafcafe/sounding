import SwiftUI

struct CollectionHeroPage<Actions: View, Row: View, Status: View, Footer: View, Shelves: View>: View {
    @ObservedObject var model: CollectionPageModel
    let metrics: CollectionHeroMetrics
    var onSubtitle: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var row: (Track, CollectionTrackRow) -> Row
    @ViewBuilder var status: () -> Status
    @ViewBuilder var footer: () -> Footer
    @ViewBuilder var shelves: () -> Shelves

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .collectionAccent(from: model.artworkURL)
        .task { await model.loadIfNeeded() }
        .task(id: model.tracks.count) { await model.refreshAnalysis() }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        if metrics.layout == .column {
            columns
        } else {
            stacked
        }
        #else
        stacked
        #endif
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollectionHero(content: model.heroContent, metrics: metrics, onSubtitle: onSubtitle, actions: actions)

            LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                rows
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.top, metrics.listTopSpacing)

            LazyVStack(alignment: .leading, spacing: 0) {
                shelves()
            }
            .padding(.top, metrics.listTopSpacing)
            .padding(.bottom, metrics.bottomInset)
        }
    }

    @ViewBuilder
    private var rows: some View {
        if model.tracks.isEmpty {
            status()
        } else {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                row(track, model.row(track, at: index))
                    .onAppear { model.noteAppeared(track) }
            }
            footer()
        }
    }

    #if os(tvOS)
    private var columns: some View {
        CollectionColumnPage(content: model.heroContent, metrics: metrics, onSubtitle: onSubtitle, actions: actions) {
            rows
        } shelves: {
            shelves()
        }
    }
    #endif
}

#if os(tvOS)
struct CollectionColumnPage<Actions: View, Rows: View, Shelves: View>: View {
    let content: CollectionHeroContent
    let metrics: CollectionHeroMetrics
    var onSubtitle: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var shelves: () -> Shelves

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollectionPinnedColumns(
                width: metrics.textMaxWidth ?? metrics.artworkSide,
                spacing: metrics.heroSpacing,
                pinTop: metrics.topInset
            ) {
                CollectionHeroHeader(content: content, metrics: metrics, onSubtitle: onSubtitle, actions: actions)
                    .environment(\.colorScheme, .dark)
                    .environment(\.collectionHeroOnArtwork, true)
            } trailing: {
                LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    rows()
                }
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.top, metrics.topInset)
            .background(alignment: .top) {
                CollectionColumnBackdrop(
                    url: content.artworkURL,
                    identity: content.id,
                    height: metrics.backdropHeight,
                    fade: metrics.backdropFade
                )
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                shelves()
            }
            .padding(.top, metrics.listTopSpacing)
            .padding(.bottom, metrics.bottomInset)
        }
    }
}

private struct CollectionColumnBackdrop: View {
    let url: URL?
    let identity: String
    let height: CGFloat
    let fade: CGFloat

    @State private var isOnScreen = true

    var body: some View {
        CollectionArtworkBackdrop(url: url, identity: identity, isActive: isOnScreen, fade: fade)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .global).maxY > 0
            } action: { isOnScreen = $0 }
    }
}

private struct CollectionPinnedColumns<Leading: View, Trailing: View>: View {
    let width: CGFloat
    let spacing: CGFloat
    let pinTop: CGFloat
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var leadingHeight: CGFloat = 0
    @State private var trailingHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            leading()
                .frame(width: width, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height.rounded()
                } action: { leadingHeight = $0 }
                .modifier(CollectionPinnedOffset(pinTop: pinTop, limit: max(0, trailingHeight - leadingHeight)))
                .focusSection()

            trailing()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height.rounded()
                } action: { trailingHeight = $0 }
                .focusSection()
        }
    }
}

private struct CollectionPinnedOffset: ViewModifier {
    let pinTop: CGFloat
    let limit: CGFloat

    @State private var top: CGFloat = 0
    @State private var hasMeasured = false

    func body(content: Content) -> some View {
        content
            .offset(y: hasMeasured ? min(max(0, pinTop - top), limit) : 0)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .scrollView(axis: .vertical)).minY.rounded()
            } action: { value in
                top = value
                hasMeasured = true
            }
    }
}
#endif
