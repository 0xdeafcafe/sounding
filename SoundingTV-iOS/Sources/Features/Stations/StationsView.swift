import SwiftUI

struct StationsView: View {
    @ObservedObject private var model = StationsModel.shared
    @Environment(\.artistRouter) private var artistRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isRegular: Bool { sizeClass == .regular }
    private var tileWidth: CGFloat { isRegular ? 190 : 156 }
    private var heroArtwork: CGFloat { isRegular ? 200 : 116 }
    private var heroCorner: CGFloat { SCContentStyle.phone.cornerPanel }

    var body: some View {
        SoundCloudSectionGate(.stations) {
            content
                .navigationTitle("Stations")
                .libraryPageTitleDisplayMode()
        }
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
                heroHeight: heroArtwork + 48,
                tile: tileWidth,
                cornerRadius: heroCorner,
                horizontalInset: PhoneLayout.margin
            )
            .padding(.top, 8)
        } else if model.isEmpty {
            ContentUnavailableView {
                Label("No Stations Yet", systemImage: StationSymbol.name)
            } description: {
                Text("Like, follow and play music, and stations based on it appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PhoneLayout.shelfGap) {
                    if let seed = model.yourStation {
                        hero(seed)
                            .transition(.opacity)
                    }
                    shelf("Recently Played", model.recents, forgets: true)
                    shelf("Liked Stations", model.liked)
                    shelf("Stations for You", model.forYou)
                    shelf("Artist Stations", model.artists)
                }
                .padding(.top, 8)
                .padding(.bottom, PhoneLayout.shelfGap)
                .animation(reduceMotion ? nil : .smooth, value: animationKey)
            }
            .refreshable { await model.reload() }
        }
    }

    private var animationKey: [String] {
        [model.yourStation?.id ?? ""]
            + model.recents.map(\.id)
            + model.liked.map(\.id)
            + model.forYou.map(\.id)
            + model.artists.map(\.id)
    }

    private func hero(_ seed: StationSeed) -> some View {
        StationHeroContent(
            seed: seed,
            style: .phone,
            artworkSide: heroArtwork,
            titleFont: isRegular ? .largeTitle.weight(.bold) : .title2.weight(.bold),
            stacked: dynamicTypeSize.isAccessibilitySize
        ) {
            Button { model.play(seed) } label: {
                HStack(spacing: 8) {
                    if model.startingID == seed.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Play")
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(model.startingID != nil)
            .accessibilityLabel("Play \(seed.title)")
        }
        .padding(isRegular ? 28 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { StationHeroBackground(url: seed.artworkURL) }
        .clipShape(RoundedRectangle(cornerRadius: heroCorner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: heroCorner, style: .continuous))
        .libraryCardPreviewShape(cornerRadius: heroCorner)
        .contextMenu { menu(seed) }
        .padding(.horizontal, PhoneLayout.margin)
    }

    @ViewBuilder
    private func shelf(_ title: String, _ seeds: [StationSeed], forgets: Bool = false) -> some View {
        if !seeds.isEmpty {
            VStack(alignment: .leading, spacing: PhoneLayout.headerGap) {
                PhoneSectionTitle(title: title)
                    .padding(.horizontal, PhoneLayout.margin)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: PhoneLayout.tileGap) {
                        ForEach(seeds) { seed in
                            tile(seed, forgets: forgets)
                        }
                    }
                    .padding(.horizontal, PhoneLayout.margin)
                }
                .scrollClipDisabled()
                .prefetchArtwork(seeds.compactMap(\.artworkURL))
            }
            .transition(.opacity)
        }
    }

    private func tile(_ seed: StationSeed, forgets: Bool) -> some View {
        Button { model.play(seed) } label: {
            StationTileLabel(seed: seed, style: .phone, width: tileWidth, isStarting: model.startingID == seed.id)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: SCContentStyle.phone.artworkCorner, style: .continuous))
                .hoverEffect(.lift)
                .contentShape(Rectangle())
        }
        .buttonStyle(StationTilePressStyle())
        .disabled(model.startingID != nil && model.startingID != seed.id)
        .libraryTilePreviewShape()
        .contextMenu { menu(seed, forgets: forgets) }
        .accessibilityHint("Plays the station")
    }

    private func menu(_ seed: StationSeed, forgets: Bool = false) -> some View {
        StationMenuItems(
            seed: seed,
            play: { model.play(seed) },
            start: { model.play(seed, restart: true) },
            goToArtist: artistRouter.map { router -> (User) -> Void in { user in router.open(user) } },
            goToTrack: { BehindTheTrackPresenter.shared.present($0) },
            forget: forgets ? { model.forgetRecent(seed) } : nil
        )
    }
}

private struct StationTilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
