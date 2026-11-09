import SwiftUI

enum StationSymbol {
    static let name = "dot.radiowaves.left.and.right"
}

struct StationBadge: View {
    var style: SCContentStyle = .phone

    var body: some View {
        Label("Station", systemImage: StationSymbol.name)
            .labelStyle(.titleAndIcon)
            .font(style.fontCaptionEmphasis)
            .foregroundStyle(.white)
            .padding(.horizontal, style.spaceTight)
            .padding(.vertical, style.spaceHair)
            .background(.black.opacity(0.5), in: Capsule(style: .continuous))
            .padding(style.spaceTight)
            .accessibilityHidden(true)
    }
}

struct StationArtwork: View {
    let seed: StationSeed
    var style: SCContentStyle = .phone
    var cornerRadius: CGFloat?
    var showsBadge = true

    var body: some View {
        SCArtworkResolver(url: seed.artworkURL) { image in
            SCArtwork(
                image: image,
                identity: seed.artIdentity,
                style: style,
                cornerRadius: cornerRadius,
                subject: .station
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            if showsBadge { StationBadge(style: style) }
        }
    }
}

struct StationTileLabel: View {
    let seed: StationSeed
    var style: SCContentStyle = .phone
    var width: CGFloat
    var isStarting = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: style.spaceTight) {
            StationArtwork(seed: seed, style: style)
                .overlay {
                    if isStarting {
                        ZStack {
                            RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous)
                                .fill(.black.opacity(0.4))
                            ProgressView()
                                .tint(.white)
                        }
                        .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(seed.title)
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                if let subtitle = seed.subtitle {
                    Text(subtitle)
                        .font(style.fontCaption)
                        .foregroundStyle(style.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([seed.title, "station", seed.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(isStarting ? "Loading" : "")
    }
}

struct StationHeroBackground: View {
    let url: URL?

    var body: some View {
        StationHeroGround(url: url)
            .collectionAccent(from: url)
    }
}

private struct StationHeroGround: View {
    let url: URL?

    @Environment(\.collectionAccent) private var accent

    var body: some View {
        ZStack {
            accent?.wash(for: .dark) ?? Color(white: 0.16)
            CollectionPageMesh(url: url)
                .environment(\.colorScheme, .dark)
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct StationHeroContent<Actions: View>: View {
    let seed: StationSeed
    var style: SCContentStyle = .phone
    var artworkSide: CGFloat
    var titleFont: Font = .title.weight(.bold)
    var stacked = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: style.spaceBase))
            : AnyLayout(HStackLayout(alignment: .center, spacing: style.spaceRoomy))
        layout {
            StationArtwork(seed: seed, style: style, cornerRadius: style.cornerCard, showsBadge: false)
                .frame(width: artworkSide, height: artworkSide)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: style.spaceTight) {
                Label("Station", systemImage: StationSymbol.name)
                    .font(style.fontEyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.72))
                Text(seed.title)
                    .font(titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = seed.subtitle {
                    Text(subtitle)
                        .font(style.fontSubheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                actions()
                    .padding(.top, style.spaceTight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.colorScheme, .dark)
    }
}

struct StationMenuItems: View {
    let seed: StationSeed
    let play: () -> Void
    let start: () -> Void
    var goToArtist: ((User) -> Void)?
    var goToTrack: ((Track) -> Void)?
    var forget: (() -> Void)?

    var body: some View {
        Button(action: play) {
            Label("Play", systemImage: "play")
        }
        Button(action: start) {
            Label("Start Station", systemImage: StationSymbol.name)
        }
        if let goToArtist, let artist = seed.goToArtist, seed.kind != .personal {
            Button { goToArtist(artist) } label: {
                Label("Go to Artist", systemImage: "person.crop.circle")
            }
        }
        if let goToTrack, let track = seed.track, seed.kind == .track {
            Button { goToTrack(track) } label: {
                Label("Go to Track", systemImage: "music.note")
            }
        }
        #if !os(tvOS)
        if let url = shareURL {
            ShareLink(item: url, preview: SharePreview(seed.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        #endif
        if let forget {
            Button(role: .destructive, action: forget) {
                Label("Remove from Recently Played", systemImage: "minus.circle")
            }
        }
    }

    private var shareURL: URL? {
        switch seed.kind {
        case .soundCloud: return seed.system?.permalinkURL
        case .track: return seed.track?.permalinkURL
        case .artist: return seed.artist?.permalinkURL
        case .personal: return nil
        }
    }
}

struct StartStationMenuButton: View {
    private let seed: StationSeed?

    init(track: Track) {
        seed = (track.isLocal || LocalTrackFile.isLocalTrackID(track.id)) ? nil : StationSeed.track(track)
    }

    init(artist: User) {
        seed = StationSeed.artist(artist)
    }

    var body: some View {
        if let seed {
            Button {
                Task { await StationPlayer.start(seed, restart: true) }
            } label: {
                Label("Start Station", systemImage: StationSymbol.name)
            }
        }
    }
}

struct StationNowPlayingLine: View {
    let source: PlaybackQueueSource?

    @ObservedObject private var library = StationLibrary.shared
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        if !player.isPlayingSoundCloudPreview, let caption = library.caption(for: source) {
            Text(caption)
                .lineLimit(1)
        }
    }
}

struct StationsLoadingPlaceholder: View {
    var heroHeight: CGFloat
    var tile: CGFloat
    var cornerRadius: CGFloat
    var horizontalInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
                .frame(height: heroHeight)
                .padding(.horizontal, horizontalInset)
                .loadingShimmer()
                .accessibilityHidden(true)
            ForEach(0..<2, id: \.self) { _ in
                LoadingPlaceholder(.shelf(tile: tile), count: 8, insets: false)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, horizontalInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
