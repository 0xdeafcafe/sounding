import SwiftUI

struct CollectionHeroContent: Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var metadata: String?
    var description: String?
    var artworkURL: URL?
    var crownUser: User?
    var tags: [String] = []
    var likes = 0
    var reposts = 0
    var subtitleLabel: String?
    var isPrivate = false

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        metadata: String? = nil,
        description: String? = nil,
        artworkURL: URL? = nil,
        crownUser: User? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.metadata = metadata
        self.description = description
        self.artworkURL = artworkURL
        self.crownUser = crownUser
    }

    init(playlist: Playlist, loadedTrackCount: Int = 0) {
        let text = playlist.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: playlist.id,
            title: playlist.title,
            subtitle: playlist.user.displayName,
            metadata: playlist.collectionMetadataLine(loadedTrackCount: loadedTrackCount),
            description: (text?.isEmpty ?? true) ? nil : text,
            artworkURL: playlist.largeDisplayArtworkURL,
            crownUser: playlist.user
        )
        tags = playlist.displayTags
        likes = playlist.likeCount
        reposts = playlist.repostCount
        subtitleLabel = "\(playlist.releaseTypeWord) by \(playlist.user.displayName)"
        isPrivate = playlist.isPrivate
    }
}

extension Playlist {
    func collectionMetadataLine(loadedTrackCount: Int = 0) -> String {
        var parts = [releaseTypeWord]
        if let displayGenre { parts.append(displayGenre) }
        if CollectionPageKind(playlist: self) != .album, let updatedText {
            parts.append(updatedText)
        } else {
            parts.append(String(Calendar.current.component(.year, from: releaseDate ?? createdAt)))
        }
        return parts.joined(separator: " · ")
    }
}

struct CollectionHeroMetrics {
    enum Layout {
        case stacked
        case leading
        case slim
        case overlayCentered
        case overlayLeading
        #if os(tvOS)
        case column
        #endif
    }

    enum Backdrop {
        case artwork
        case fullBleed
        case blurredArtwork
        case accentWash
        case none
    }

    var layout: Layout
    var backdrop: Backdrop = .blurredArtwork
    var artworkSide: CGFloat
    var artworkCorner: CGFloat
    var backdropHeight: CGFloat
    var backdropBlur: CGFloat
    var backdropHeadroom: CGFloat = 0
    var backdropFade: CGFloat = 64
    var backdropPadsFade = true
    var horizontalInset: CGFloat
    var topInset: CGFloat
    var heroSpacing: CGFloat
    var textSpacing: CGFloat
    var rowSpacing: CGFloat
    var listTopSpacing: CGFloat
    var bottomInset: CGFloat
    var titleFont: Font
    var artistFont: Font
    var metadataFont: Font
    var descriptionFont: Font
    var titleLines: Int = 2
    var descriptionLines: Int = 2
    var textMaxWidth: CGFloat? = nil
    var fullBleedMaxHeight: CGFloat = .infinity
}

struct CollectionHeroBackdrop: View {
    let url: URL?
    let identity: String
    let height: CGFloat
    let blur: CGFloat
    var style: CollectionHeroMetrics.Backdrop = .blurredArtwork

    @Environment(\.collectionAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch style {
        case .blurredArtwork:
            blurred
        case .accentWash:
            wash
        case .artwork:
            CollectionArtworkBackdrop(url: url, identity: identity, fade: max(height * 0.45, 64))
                .frame(maxWidth: .infinity)
                .frame(height: height)
        case .fullBleed:
            CollectionFullBleedArtwork(url: url, identity: identity)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        case .none:
            Color.clear.frame(height: 0)
        }
    }

    private var blurred: some View {
        SCArtworkResolver(url: url, variant: blur >= 20 ? .standard : .hero) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: identity, subject: .collection)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .blur(radius: blur, opaque: true)
        .overlay {
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .overlay {
            if let accent {
                accent.wash(for: .dark).opacity(0.35).blendMode(.overlay)
            }
        }
        .clipped()
        .mask {
            LinearGradient(
                stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
    }

    private var wash: some View {
        LinearGradient(
            stops: [
                .init(color: accent?.wash(for: colorScheme) ?? .clear, location: 0),
                .init(color: accent?.pageTint(for: colorScheme) ?? .clear, location: 0.6),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .animation(.smooth, value: accent)
        .accessibilityHidden(true)
    }
}

struct CollectionHeroArtwork: View {
    let url: URL?
    let identity: String
    let side: CGFloat
    let corner: CGFloat
    var crownUser: User?
    var crownContext: String?

    var body: some View {
        SCArtworkResolver(url: url, variant: .hero) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: identity, subject: .collection)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .kyleCrowned(user: crownUser, context: crownContext)
        .shadow(color: .black.opacity(0.3), radius: side * 0.06, y: side * 0.03)
        .accessibilityHidden(true)
    }
}

struct CollectionHeroHeader<Actions: View>: View {
    let content: CollectionHeroContent
    let metrics: CollectionHeroMetrics
    var onSubtitle: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    @Environment(\.collectionAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.collectionHeroOnArtwork) private var onArtwork

    var body: some View {
        switch metrics.layout {
        case .leading:
            HStack(alignment: .bottom, spacing: metrics.heroSpacing) {
                artwork
                VStack(alignment: .leading, spacing: metrics.heroSpacing / 2) {
                    text(alignment: .leading)
                    actions().collectionAccentTint()
                }
                .frame(maxWidth: metrics.textMaxWidth ?? .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .stacked:
            VStack(spacing: metrics.heroSpacing / 2) {
                artwork
                text(alignment: .center)
                actions().collectionAccentTint()
            }
            .frame(maxWidth: .infinity)
        case .overlayCentered:
            VStack(spacing: metrics.heroSpacing / 2) {
                text(alignment: .center)
                actions().collectionAccentTint()
            }
            .frame(maxWidth: .infinity)
        case .overlayLeading:
            VStack(alignment: .leading, spacing: metrics.heroSpacing / 2) {
                text(alignment: .leading)
                actions().collectionAccentTint()
            }
            .frame(maxWidth: metrics.textMaxWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        case .column:
            VStack(alignment: .leading, spacing: metrics.heroSpacing / 2) {
                artwork
                text(alignment: .leading)
                actions().collectionAccentTint()
            }
            .frame(maxWidth: metrics.textMaxWidth ?? .infinity, alignment: .leading)
        #endif
        case .slim:
            HStack(spacing: metrics.heroSpacing) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(metrics.titleFont)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let line = [content.metadata, content.subtitle].compactMap({ $0 }).first {
                        Text(privateMarked: line, isPrivate: content.isPrivate)
                            .font(metrics.metadataFont)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions().collectionAccentTint()
            }
        }
    }

    private var artwork: some View {
        CollectionHeroArtwork(
            url: content.artworkURL,
            identity: content.id,
            side: metrics.artworkSide,
            corner: metrics.artworkCorner,
            crownUser: content.crownUser,
            crownContext: content.title
        )
        .nowPlayingZoomSource(id: NowPlayingReveal.collectionSourceID(content.id))
    }

    private var subtitleStyle: AnyShapeStyle {
        if onArtwork { return AnyShapeStyle(.primary) }
        if let accent { return AnyShapeStyle(accent.tint(for: colorScheme)) }
        return AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let text = content.subtitle {
            let label = Text(text)
                .font(metrics.artistFont)
                .foregroundStyle(subtitleStyle)
                .lineLimit(1)
            if let onSubtitle {
                Button(action: onSubtitle) { label }
                    #if os(tvOS)
                    .buttonStyle(TVCollectionLinkStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityLabel(content.subtitleLabel ?? text)
                    .accessibilityHint("Shows \(text)")
            } else {
                label
                    .accessibilityLabel(content.subtitleLabel ?? text)
            }
        }
    }

    private func text(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: metrics.textSpacing) {
            Text(content.title)
                .font(metrics.titleFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(textAlignment)
                .lineLimit(metrics.titleLines)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
            subtitle
            if let metadata = SoundCloudStatsText.text(content.metadata, likes: content.likes, reposts: content.reposts, isPrivate: content.isPrivate) {
                metadata
                    .font(metrics.metadataFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(2)
                    .accessibilityLabel(SoundCloudStatsText.accessibilityLabel(content.metadata, likes: content.likes, reposts: content.reposts, isPrivate: content.isPrivate))
            }
            if let description = content.description {
                SoundCloudExpandableText(
                    description,
                    font: metrics.descriptionFont,
                    lineLimit: metrics.descriptionLines,
                    alignment: textAlignment
                )
                .padding(.top, metrics.textSpacing)
            }
            if !content.tags.isEmpty {
                SoundCloudTagPills(tags: content.tags, alignment: alignment)
                    .padding(.top, metrics.textSpacing)
            }
        }
    }
}

struct CollectionHero<Actions: View>: View {
    let content: CollectionHeroContent
    let metrics: CollectionHeroMetrics
    var onSubtitle: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        if metrics.backdrop == .fullBleed {
            CollectionFullBleedHero(content: content, metrics: metrics, onSubtitle: onSubtitle, actions: actions)
        } else if metrics.backdrop == .artwork {
            CollectionHeroHeader(content: content, metrics: metrics, onSubtitle: onSubtitle, actions: actions)
                .padding(.horizontal, metrics.horizontalInset)
                .padding(.top, metrics.topInset)
                .frame(maxWidth: .infinity, minHeight: metrics.backdropHeight > 0 ? metrics.backdropHeight : nil, alignment: .bottom)
                .collectionArtworkBackdrop(
                    url: content.artworkURL,
                    identity: content.id,
                    headroom: metrics.backdropHeadroom,
                    fade: metrics.backdropFade,
                    padsFade: metrics.backdropPadsFade
                )
        } else {
            layered
        }
    }

    private var layered: some View {
        ZStack(alignment: metrics.layout == .slim ? .center : .bottom) {
            CollectionHeroBackdrop(
                url: content.artworkURL,
                identity: content.id,
                height: metrics.backdropHeight,
                blur: metrics.backdropBlur,
                style: metrics.backdrop
            )
            CollectionHeroHeader(content: content, metrics: metrics, onSubtitle: onSubtitle, actions: actions)
                .padding(.horizontal, metrics.horizontalInset)
                .padding(.top, metrics.topInset)
                .padding(.bottom, metrics.layout == .slim ? metrics.topInset : 0)
        }
        .frame(maxWidth: .infinity, minHeight: metrics.layout == .slim || metrics.backdrop == .none ? nil : metrics.backdropHeight, alignment: .bottom)
    }
}

struct CollectionFullBleedHero<Actions: View>: View {
    let content: CollectionHeroContent
    let metrics: CollectionHeroMetrics
    var onSubtitle: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    @Environment(\.collectionTopInset) private var topInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.collectionScrollBackdrop) private var host
    @State private var width: CGFloat = 0

    private var artHeight: CGFloat {
        min(width > 0 ? width : 390, metrics.fullBleedMaxHeight)
    }

    var body: some View {
        CollectionHeroHeader(content: content, metrics: metrics, onSubtitle: onSubtitle, actions: actions)
            .environment(\.collectionHeroOnArtwork, true)
            .collectionPageScheme()
            .visualEffect { [topInset, reduceMotion] effect, proxy in
                let minY = proxy.frame(in: .scrollView).minY
                let progress = min(max((topInset + 24 - minY) / 96, 0), 1)
                return effect
                    .opacity(1 - progress)
                    .scaleEffect(reduceMotion ? 1 : 1 - 0.04 * progress, anchor: .bottom)
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.top, metrics.topInset)
            .padding(.bottom, metrics.bottomInset)
            .frame(maxWidth: .infinity, minHeight: max(artHeight - topInset, 0), alignment: .bottom)
            .background(alignment: .bottom) {
                if host == nil {
                    CollectionFullBleedArtwork(url: content.artworkURL, identity: content.id)
                        .nowPlayingZoomSource(id: NowPlayingReveal.collectionSourceID(content.id))
                        .padding(.top, -topInset)
                }
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: proxy.size.width.rounded(), height: proxy.size.height.rounded())
            } action: { value in
                width = value.width
                if let host, host.heroHeight != value.height { host.heroHeight = value.height }
            }
    }
}

struct PersonHeroContent: Equatable {
    var id: String
    var name: String
    var badge: String?
    var badgeSymbol: String?
    var bannerURL: URL?
    var avatarURL: URL?
    var seed: UInt64
    var crownUser: User?

    init(user: User, bannerURL: URL?, avatarURL: URL?, badge: String? = nil, badgeSymbol: String? = nil) {
        id = user.id
        name = user.displayName
        self.badge = badge
        self.badgeSymbol = badgeSymbol
        self.bannerURL = bannerURL
        self.avatarURL = avatarURL
        seed = user.artSeed
        crownUser = user
    }

    var accentURL: URL? { bannerURL ?? avatarURL }
    var backdropURL: URL? { bannerURL ?? avatarURL }
    var backdropVariant: ArtworkVariant { bannerURL != nil ? .signed : .thumbnail }
}

struct PersonHeroMetrics {
    var heightFraction: CGFloat
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var nameSize: CGFloat
    var nameLines: Int = 2
    var badgeFont: Font
    var horizontalInset: CGFloat
    var bottomInset: CGFloat
    var spacing: CGFloat
    var avatarBlur: CGFloat = 48
    var avatarSize: CGFloat = 0
    var blursBanner = false

    func height(for pageHeight: CGFloat) -> CGFloat {
        guard pageHeight > 0 else { return minHeight }
        return min(max(pageHeight * heightFraction, minHeight), maxHeight)
    }
}

struct PersonHeroImage: View {
    let bannerURL: URL?
    let avatarURL: URL?
    let seed: UInt64
    var avatarBlur: CGFloat = 48
    var backdropIdentity: String? = nil
    var blursBanner = false
    var isActive = true

    var body: some View {
        Color.black
            .overlay {
                if let bannerURL, blursBanner, let backdropIdentity {
                    CollectionArtworkBackdrop(url: bannerURL, identity: backdropIdentity, isActive: isActive, fade: 0, variant: .signed)
                } else if let bannerURL {
                    SCArtworkResolver(url: bannerURL, variant: .signed) { image in
                        if let image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            avatarOrArt
                        }
                    }
                } else {
                    avatarOrArt
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarOrArt: some View {
        if let avatarURL, let backdropIdentity {
            CollectionArtworkBackdrop(url: avatarURL, identity: backdropIdentity, isActive: isActive, fade: 0)
        } else if let avatarURL {
            SCArtworkResolver(url: avatarURL, variant: .hero) { image in
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.3)
                        .blur(radius: avatarBlur, opaque: true)
                        .saturation(1.3)
                        .overlay(Color.black.opacity(0.2))
                } else {
                    SoundingLineArt(seed: seed, style: .banner, loop: .once)
                }
            }
        } else {
            SoundingLineArt(seed: seed, style: .banner, loop: .once)
        }
    }
}

struct PersonHeroScrim: View {
    var measured: Double? = nil

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let strong = contrast == .increased
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(strong ? 0.55 : 0.35), location: 0),
                    .init(color: .black.opacity(0), location: 0.28),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(stops: nameStops(strong: strong), startPoint: .top, endPoint: .bottom)
        }
        .animation(.smooth(duration: 0.5), value: measured)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func nameStops(strong: Bool) -> [Gradient.Stop] {
        guard let measured else {
            return [
                .init(color: .black.opacity(0), location: 0.35),
                .init(color: .black.opacity(strong ? 0.6 : 0.3), location: 0.65),
                .init(color: .black.opacity(strong ? 0.92 : 0.78), location: 1),
            ]
        }
        let peak = min(max(measured, strong ? 0.5 : 0.24), 0.92)
        return [
            .init(color: .black.opacity(0), location: 0.35),
            .init(color: .black.opacity(peak * 0.5), location: 0.6),
            .init(color: .black.opacity(peak), location: 0.78),
            .init(color: .black.opacity(peak), location: 1),
        ]
    }
}

struct PersonHeroBackdrop: View {
    let content: PersonHeroContent
    var blursBanner = false
    var isActive = true

    @State private var art: CollectionBackdropArt?
    @State private var artURL: URL?
    @Environment(\.colorSchemeContrast) private var contrast

    private var drifts: Bool {
        content.bannerURL == nil ? content.avatarURL != nil : blursBanner
    }

    private var resolvedArt: CollectionBackdropArt? {
        if artURL == content.backdropURL, let art { return art }
        return CollectionBackdropStore.shared.cached(content.backdropURL)
    }

    private var measured: Double? {
        guard let art = resolvedArt else { return nil }
        let strong = contrast == .increased
        let needed = CollectionBackdropRenderer.nameScrim(for: art, strong: strong)
        guard drifts else { return needed }
        let applied = strong ? art.strongScrim : art.scrim
        return max(0, 1 - (1 - needed) / max(1 - applied, 0.01))
    }

    var body: some View {
        ZStack {
            PersonHeroImage(
                bannerURL: content.bannerURL,
                avatarURL: content.avatarURL,
                seed: content.seed,
                backdropIdentity: content.id,
                blursBanner: blursBanner,
                isActive: isActive
            )
            PersonHeroScrim(measured: measured)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.8),
                    .init(color: .black.opacity(0.55), location: 0.9),
                    .init(color: .black.opacity(0.15), location: 0.97),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: content.backdropURL) {
            guard let url = content.backdropURL else {
                art = nil
                artURL = nil
                return
            }
            let result = await CollectionBackdropStore.shared.art(for: url, variant: content.backdropVariant)
            guard !Task.isCancelled else { return }
            art = result
            artURL = url
        }
    }
}

struct PersonHeroBadge: View {
    let text: String
    var symbol: String?
    var font: Font

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .font(font)
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        #if os(tvOS)
        .background(.ultraThinMaterial, in: Capsule())
        #else
        .glassEffect(.regular, in: .capsule)
        #endif
        .environment(\.colorScheme, .dark)
    }
}

struct PersonHeroAvatar: View {
    let url: URL
    let identity: String
    let size: CGFloat

    var body: some View {
        SCArtworkResolver(url: url, variant: .standard) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: identity, subject: .person)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityHidden(true)
    }
}

struct PersonHeroTitle: View {
    let content: PersonHeroContent
    let metrics: PersonHeroMetrics

    @ScaledMetric private var nameSize: CGFloat

    init(content: PersonHeroContent, metrics: PersonHeroMetrics) {
        self.content = content
        self.metrics = metrics
        _nameSize = ScaledMetric(wrappedValue: metrics.nameSize, relativeTo: .largeTitle)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: metrics.spacing) {
            if metrics.avatarSize > 0, let avatarURL = content.avatarURL {
                PersonHeroAvatar(url: avatarURL, identity: content.id, size: metrics.avatarSize)
            }
            VStack(alignment: .leading, spacing: metrics.spacing / 2) {
                if let badge = content.badge {
                    PersonHeroBadge(text: badge, symbol: content.badgeSymbol, font: metrics.badgeFont)
                }
                Text(content.name)
                    .font(.system(size: nameSize, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .lineLimit(metrics.nameLines)
                    .minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct PersonHero<Trailing: View>: View {
    let content: PersonHeroContent
    let metrics: PersonHeroMetrics
    let height: CGFloat
    var stretches = true
    @ViewBuilder var trailing: () -> Trailing

    @State private var overscroll: CGFloat = 0
    @Environment(\.collectionScrollBackdrop) private var host

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if host == nil {
                PersonHeroBackdrop(content: content, blursBanner: metrics.blursBanner)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                    .scaleEffect(height > 0 ? 1 + overscroll / height : 1, anchor: .bottom)
            }

            HStack(alignment: .bottom, spacing: metrics.spacing) {
                PersonHeroTitle(content: content, metrics: metrics)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.bottom, metrics.bottomInset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .environment(\.colorScheme, .dark)
        .collectionScrollBackdropHero()
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(0, proxy.frame(in: .scrollView).minY)
        } action: { value in
            guard stretches, host == nil else { return }
            overscroll = value
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Platform metrics

extension CollectionHeroMetrics {
    static let phoneStacked = CollectionHeroMetrics(
        layout: .stacked,
        backdrop: .artwork,
        artworkSide: 250,
        artworkCorner: 12,
        backdropHeight: 0,
        backdropBlur: 0,
        backdropHeadroom: 280,
        backdropFade: 64,
        horizontalInset: 20,
        topInset: 12,
        heroSpacing: 24,
        textSpacing: 4,
        rowSpacing: 0,
        listTopSpacing: 0,
        bottomInset: 20,
        titleFont: .title2.bold(),
        artistFont: .title3,
        metadataFont: .footnote,
        descriptionFont: .footnote,
        titleLines: 3,
        descriptionLines: 3
    )

    static let padLeading = CollectionHeroMetrics(
        layout: .leading,
        backdrop: .artwork,
        artworkSide: 240,
        artworkCorner: 14,
        backdropHeight: 0,
        backdropBlur: 0,
        backdropHeadroom: 260,
        backdropFade: 72,
        horizontalInset: 24,
        topInset: 24,
        heroSpacing: 32,
        textSpacing: 4,
        rowSpacing: 0,
        listTopSpacing: 0,
        bottomInset: 28,
        titleFont: .largeTitle.bold(),
        artistFont: .title2,
        metadataFont: .subheadline,
        descriptionFont: .subheadline,
        titleLines: 2,
        descriptionLines: 3,
        textMaxWidth: 640
    )

    static let phoneFullBleed: CollectionHeroMetrics = {
        var metrics = CollectionHeroMetrics.phoneStacked
        metrics.layout = .overlayCentered
        metrics.backdrop = .fullBleed
        metrics.heroSpacing = 20
        metrics.topInset = 0
        metrics.bottomInset = 20
        metrics.fullBleedMaxHeight = 520
        return metrics
    }()

    static let padFullBleed: CollectionHeroMetrics = {
        var metrics = CollectionHeroMetrics.padLeading
        metrics.layout = .overlayLeading
        metrics.backdrop = .fullBleed
        metrics.topInset = 0
        metrics.bottomInset = 28
        metrics.fullBleedMaxHeight = 560
        return metrics
    }()

    static let padSlim = CollectionHeroMetrics(
        layout: .slim,
        backdrop: .none,
        artworkSide: 56,
        artworkCorner: 8,
        backdropHeight: 0,
        backdropBlur: 0,
        horizontalInset: 24,
        topInset: 8,
        heroSpacing: 16,
        textSpacing: 2,
        rowSpacing: 0,
        listTopSpacing: 0,
        bottomInset: 8,
        titleFont: .headline,
        artistFont: .subheadline,
        metadataFont: .subheadline,
        descriptionFont: .subheadline
    )

    static let mac = CollectionHeroMetrics(
        layout: .leading,
        backdrop: .artwork,
        artworkSide: 200,
        artworkCorner: 12,
        backdropHeight: 0,
        backdropBlur: 0,
        backdropHeadroom: 220,
        backdropFade: 64,
        horizontalInset: 0,
        topInset: 0,
        heroSpacing: 24,
        textSpacing: 4,
        rowSpacing: 0,
        listTopSpacing: 0,
        bottomInset: 0,
        titleFont: .largeTitle.weight(.bold),
        artistFont: .headline,
        metadataFont: .subheadline,
        descriptionFont: .subheadline,
        titleLines: 2,
        descriptionLines: 3,
        textMaxWidth: 640
    )
}

extension CollectionHeroMetrics {
    static let macFullBleed: CollectionHeroMetrics = {
        var metrics = CollectionHeroMetrics.mac
        metrics.layout = .overlayLeading
        metrics.backdrop = .fullBleed
        metrics.horizontalInset = SCContentStyle.mac.spaceGutter
        metrics.bottomInset = 24
        metrics.fullBleedMaxHeight = 460
        return metrics
    }()
}

extension PersonHeroMetrics {
    static let phone = PersonHeroMetrics(
        heightFraction: 0.45,
        minHeight: 320,
        maxHeight: 460,
        nameSize: 40,
        badgeFont: .footnote.weight(.semibold),
        horizontalInset: 20,
        bottomInset: 20,
        spacing: 12,
        avatarSize: 72,
        blursBanner: true
    )

    static let pad = PersonHeroMetrics(
        heightFraction: 0.45,
        minHeight: 380,
        maxHeight: 620,
        nameSize: 64,
        nameLines: 1,
        badgeFont: .subheadline.weight(.semibold),
        horizontalInset: 28,
        bottomInset: 28,
        spacing: 16,
        avatarSize: 104
    )

    static let mac = PersonHeroMetrics(
        heightFraction: 0.45,
        minHeight: 270,
        maxHeight: 420,
        nameSize: 44,
        nameLines: 1,
        badgeFont: .subheadline.weight(.semibold),
        horizontalInset: 24,
        bottomInset: 22,
        spacing: 14,
        avatarSize: 76
    )
}

#if !os(tvOS)
struct CollectionHeroPlayButtons: View {
    var isEnabled = true
    var fills = true
    var isCompact = false
    var collectionID: String? = nil
    var revealsNowPlaying = false
    var prewarm: ((_ immediate: Bool) -> Void)? = nil
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.collectionAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var playLabelColor: Color {
        accent?.onTint(for: colorScheme) ?? .white
    }

    private var glyph: CollectionPlayGlyph {
        CollectionPlaybackStatus.shared.glyph(for: collectionID)
    }

    private func start(_ action: () -> Void) {
        if let collectionID {
            NowPlayingReveal.shared.beginStarting(collectionID)
            if revealsNowPlaying {
                NowPlayingReveal.shared.reveal(from: NowPlayingReveal.collectionSourceID(collectionID))
            }
        }
        action()
    }

    private func playTapped() {
        switch glyph {
        case .starting:
            return
        case .pause:
            PlayerService.shared.pause()
        case .play:
            start(onPlay)
        }
    }

    @ViewBuilder
    private var playLabel: some View {
        switch glyph {
        case .starting:
            Label {
                Text("Play")
            } icon: {
                ProgressView()
                    .controlSize(.small)
                    .tint(playLabelColor)
            }
            .accessibilityLabel("Loading")
        case .pause:
            Label("Pause", systemImage: "pause.fill")
        case .play:
            Label("Play", systemImage: "play.fill")
        }
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize && !isCompact
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        GlassEffectContainer(spacing: 12) {
            layout {
                Button(action: playTapped) {
                    playLabel
                        .foregroundStyle(playLabelColor)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: fills ? .infinity : nil)
                        .frame(minWidth: isCompact ? nil : 110)
                }
                .modifier(CollectionHeroButtonStyle(isProminent: true))
                .prewarmsPlayback(prewarm)

                Button(action: { start(onShuffle) }) {
                    Label("Shuffle", systemImage: "shuffle")
                        .foregroundStyle(.tint)
                        .frame(maxWidth: fills ? .infinity : nil)
                        .frame(minWidth: isCompact ? nil : 110)
                }
                .modifier(CollectionHeroButtonStyle(isProminent: false))
            }
        }
        .controlSize(isCompact ? .regular : .large)
        .disabled(!isEnabled)
        .collectionAccentTint()
        .frame(maxWidth: fills ? 520 : nil)
    }
}

struct CollectionHeroButtonStyle: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

struct PersonHeroPlayButton: View {
    let name: String
    var diameter: CGFloat = 56
    var isEnabled = true
    let action: () -> Void

    @Environment(\.collectionAccent) private var accent

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .modifier(CollectionHeroButtonStyle(isProminent: true))
        .buttonBorderShape(.circle)
        .tint(accent?.tint(for: .light))
        .disabled(!isEnabled)
        .accessibilityLabel("Play \(name)")
    }
}
#endif
