import SwiftUI
import AppKit

struct MacStationsView: View {
    @ObservedObject private var model = StationsModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tile: CGFloat = 160
    private static let heroArtwork: CGFloat = 196
    private static let heroCorner: CGFloat = SCContentStyle.mac.cornerHero
    private static let inset: CGFloat = 20

    var body: some View {
        SoundCloudSectionGate(.stations) {
            page
        }
        .navigationTitle("Stations")
        .toolbar(removing: .title)
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
    private var page: some View {
        if model.showsLoading {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                StationsLoadingPlaceholder(
                    heroHeight: Self.heroArtwork + 56,
                    tile: Self.tile,
                    cornerRadius: Self.heroCorner,
                    horizontalInset: Self.inset
                )
                .padding(.top, SCContentStyle.mac.spaceBase)
            }
        } else if model.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                ContentUnavailableView {
                    Label("No Stations Yet", systemImage: StationSymbol.name)
                } description: {
                    Text("Like, follow and play music, and stations based on it appear here.")
                }
                .macFillsPane()
            }
        } else {
            MacViewportScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    titleRow
                    if let seed = model.yourStation {
                        hero(seed)
                            .transition(.opacity)
                    }
                    shelf("Recently Played", model.recents, forgets: true)
                    shelf("Liked Stations", model.liked)
                    shelf("Stations for You", model.forYou)
                    shelf("Artist Stations", model.artists)
                }
                .padding(.bottom, 32)
                .animation(reduceMotion ? nil : .smooth, value: animationKey)
            }
            .defaultScrollAnchor(.top, for: .alignment)
        }
    }

    private var animationKey: [String] {
        [model.yourStation?.id ?? ""]
            + model.recents.map(\.id)
            + model.liked.map(\.id)
            + model.forYou.map(\.id)
            + model.artists.map(\.id)
    }

    private var titleRow: some View {
        Text("Stations")
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
            .macFadesUnderToolbar(over: 18)
            .padding(.horizontal, Self.inset)
            .padding(.top, 22)
    }

    private func hero(_ seed: StationSeed) -> some View {
        StationHeroContent(
            seed: seed,
            style: .mac,
            artworkSide: Self.heroArtwork,
            titleFont: .largeTitle.weight(.bold)
        ) {
            Button { model.play(seed) } label: {
                HStack(spacing: 6) {
                    if model.startingID == seed.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Play")
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(model.startingID != nil)
            .accessibilityLabel("Play \(seed.title)")
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { StationHeroBackground(url: seed.artworkURL) }
        .clipShape(RoundedRectangle(cornerRadius: Self.heroCorner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Self.heroCorner, style: .continuous))
        .contextMenu { menu(seed) }
        .padding(.horizontal, Self.inset)
    }

    @ViewBuilder
    private func shelf(_ title: String, _ seeds: [StationSeed], forgets: Bool = false) -> some View {
        if !seeds.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SCSectionHeader(title: title, style: .mac)
                    .macFadesUnderToolbar()
                    .padding(.horizontal, Self.inset)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                        ForEach(seeds) { seed in
                            tile(seed, forgets: forgets)
                        }
                    }
                    .padding(.horizontal, Self.inset)
                }
                .scrollClipDisabled()
                .prefetchArtwork(seeds.compactMap(\.artworkURL))
            }
            .transition(.opacity)
        }
    }

    private func tile(_ seed: StationSeed, forgets: Bool) -> some View {
        Button { model.play(seed) } label: {
            StationTileLabel(seed: seed, style: .mac, width: Self.tile, isStarting: model.startingID == seed.id)
        }
        .buttonStyle(.plain)
        .macCardHover(artworkSide: Self.tile, play: { model.play(seed) }) {
            menu(seed, forgets: forgets)
        }
        .accessibilityHint("Plays the station")
    }

    private func menu(_ seed: StationSeed, forgets: Bool = false) -> some View {
        StationMenuItems(
            seed: seed,
            play: { model.play(seed) },
            start: { model.play(seed, restart: true) },
            goToArtist: { MacRootSelection.shared.request(artist: $0) },
            goToTrack: { BehindTheTrackPresenter.shared.present($0) },
            forget: forgets ? { model.forgetRecent(seed) } : nil
        )
    }
}
