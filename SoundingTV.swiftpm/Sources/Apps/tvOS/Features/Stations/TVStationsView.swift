import SwiftUI

struct TVStationsView: View {
    @ObservedObject private var model = StationsModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: StationsFocus?
    @State private var artist: User?
    @State private var track: Track?

    private enum StationsFocus: Hashable {
        case hero
        case first
    }

    private static let heroHeight: CGFloat = 420
    private static let heroArtwork: CGFloat = 300

    var body: some View {
        NavigationStack {
            SoundCloudSectionGate(.stations) {
                content
            }
            .navigationDestination(item: $artist) { ArtistDetailView(user: $0) }
            .navigationDestination(item: $track) { BehindTheTrackView(track: $0, palette: ArtworkColors.shared.current) }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .defaultFocus($focus, model.yourStation == nil ? .first : .hero)
        .task { await model.load() }
        .alert(
            "Couldn\u{2019}t Start Station",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
        ) {
            Button("OK", role: .cancel) { model.failure = nil }
        } message: {
            Text(model.failure ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.showsLoading {
            StationsLoadingPlaceholder(
                heroHeight: Self.heroHeight,
                tile: SCBrowseMetrics.tileEdge,
                cornerRadius: SCBrowseMetrics.heroCorner,
                horizontalInset: SCBrowseMetrics.pageInset
            )
            .padding(.top, SCBrowseMetrics.contentTopInset)
        } else if model.isEmpty {
            ContentUnavailableView {
                Label("No Stations Yet", systemImage: StationSymbol.name)
            } description: {
                Text("Like, follow and play music, and stations based on it appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .remoteFocusTarget()
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                    if let seed = model.yourStation {
                        hero(seed)
                            .focusSection()
                            .transition(.opacity)
                    }
                    shelf("Recently Played", model.recents, forgets: true)
                    shelf("Liked Stations", model.liked)
                    shelf("Stations for You", model.forYou)
                    shelf("Artist Stations", model.artists)
                }
                .padding(.top, SCBrowseMetrics.contentTopInset)
                .padding(.bottom, SCBrowseMetrics.shelfGap)
                .animation(reduceMotion ? nil : .smooth, value: animationKey)
            }
            .scrollClipDisabled()
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var animationKey: [String] {
        [model.yourStation?.id ?? ""]
            + model.recents.map(\.id)
            + model.liked.map(\.id)
            + model.forYou.map(\.id)
            + model.artists.map(\.id)
    }

    private var firstShelfTitle: String? {
        [("Recently Played", model.recents), ("Liked Stations", model.liked), ("Stations for You", model.forYou), ("Artist Stations", model.artists)]
            .first { !$0.1.isEmpty }?.0
    }

    private func hero(_ seed: StationSeed) -> some View {
        HStack(spacing: SCBrowseMetrics.gutter) {
            Button { model.play(seed) } label: {
                StationHeroContent(
                    seed: seed,
                    style: .tv,
                    artworkSide: Self.heroArtwork,
                    titleFont: .system(size: 56, weight: .bold)
                ) {
                    EmptyView()
                }
                .padding(48)
                .frame(maxWidth: .infinity, minHeight: Self.heroHeight, maxHeight: Self.heroHeight, alignment: .leading)
                .background { StationHeroBackground(url: seed.artworkURL) }
                .clipShape(RoundedRectangle(cornerRadius: SCBrowseMetrics.heroCorner, style: .continuous))
                .overlay {
                    if model.startingID == seed.id {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: SCBrowseMetrics.heroCorner, sizeClass: .hero))
            .focusEffectDisabled()
            .focused($focus, equals: .hero)
            .contextMenu { menu(seed) }
            .accessibilityLabel([seed.title, "station", seed.subtitle].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Plays the station")

            Button { model.play(seed) } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.tvBodyEmph)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 18)
            }
            .buttonStyle(TVCollectionPillStyle(isProminent: true))
            .accessibilityLabel("Play \(seed.title)")
        }
        .padding(.horizontal, SCBrowseMetrics.pageInset)
    }

    @ViewBuilder
    private func shelf(_ title: String, _ seeds: [StationSeed], forgets: Bool = false) -> some View {
        if !seeds.isEmpty {
            VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
                SCSectionHeader(title: title, style: SCBrowseMetrics.header)
                    .padding(.horizontal, SCBrowseMetrics.pageInset)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
                        ForEach(Array(seeds.enumerated()), id: \.element.id) { index, seed in
                            tile(seed, forgets: forgets, isFirst: index == 0 && title == firstShelfTitle)
                        }
                    }
                }
                .scrollClipDisabled()
                .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control))
                .focusEffectDisabled()
                .prefetchArtwork(seeds.compactMap(\.artworkURL))
            }
            .focusSection()
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func tile(_ seed: StationSeed, forgets: Bool, isFirst: Bool) -> some View {
        let button = Button { model.play(seed) } label: {
            StationTileLabel(
                seed: seed,
                style: SCBrowseMetrics.tile,
                width: SCBrowseMetrics.tileEdge,
                isStarting: model.startingID == seed.id
            )
        }
        .contextMenu { menu(seed, forgets: forgets) }
        .accessibilityHint("Plays the station")
        if isFirst {
            button.focused($focus, equals: .first)
        } else {
            button
        }
    }

    private func menu(_ seed: StationSeed, forgets: Bool = false) -> some View {
        StationMenuItems(
            seed: seed,
            play: { model.play(seed) },
            start: { model.play(seed, restart: true) },
            goToArtist: { artist = $0 },
            goToTrack: { track = $0 },
            forget: forgets ? { model.forgetRecent(seed) } : nil
        )
    }
}
