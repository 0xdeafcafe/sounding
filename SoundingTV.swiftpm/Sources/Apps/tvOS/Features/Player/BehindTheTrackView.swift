import SwiftUI

struct BehindTheTrackView: View {
    let track: Track
    let palette: ArtworkColors.Palette
    var onOpenTracklist: (() -> Void)?

    @EnvironmentObject private var navigationState: NavigationState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var playFocused: Bool
    @StateObject private var related = RelatedTracksStore()
    @StateObject private var model: BehindTheTrackModel
    @ObservedObject private var summaries = AnalysisSummaries.shared
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @ObservedObject private var recents = RecentlyPlayed.shared
    @ObservedObject private var player = PlayerService.shared
    @State private var link: BTLink?
    @State private var descriptionExpanded = false
    @State private var profile: User?

    init(track: Track, palette: ArtworkColors.Palette, onOpenTracklist: (() -> Void)? = nil) {
        self.track = track
        self.palette = palette
        self.onOpenTracklist = onOpenTracklist
        _model = StateObject(wrappedValue: BehindTheTrackModel(track: track))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            leftColumn
                .frame(width: 460, alignment: .leading)
                .padding(.top, 96)
                .focusSection()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 54) {
                    people
                    if track.supportsSoundCloudActions {
                        stats
                    }
                    if let description = model.descriptionText {
                        descriptionSection(description)
                    }
                    if model.genre != nil || !model.tags.isEmpty {
                        tagSection
                    }
                    detailsSection
                    if track.supportsSoundCloudActions {
                        linksSection
                        relatedSection
                    }
                }
                .padding(.top, 96)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .focusSection()
        }
        .padding(.leading, 110)
        .padding(.trailing, 100)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { backdrop }
        .collectionAccent(from: track.artworkURL)
        .environment(\.colorScheme, .dark)
        .defaultFocus($playFocused, true)
        .fullScreenCover(item: $link) { target in
            ShareTrackView(track: track, url: url(for: target), eyebrow: target.title)
        }
        .fullScreenCover(item: $profile) { user in
            NavigationStack {
                ArtistDetailView(user: user)
            }
        }
        .task(id: track.id) {
            guard track.supportsSoundCloudActions else { return }
            await related.load(for: track)
        }
        .task(id: track.id) { await model.load() }
        .task(id: track.id) { _ = summaries.summary(for: track) }
        .onChange(of: track) { _, next in model.show(next) }
    }

    // MARK: - Left column

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkImage(url: track.largeArtworkURL ?? track.artworkURL, variant: .hero, identity: track.id)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 440, height: 440)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 34, y: 22)
                .accessibilityHidden(true)
            Text(track.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 30)
                .accessibilityAddTraits(.isHeader)
            uploader
                .padding(.top, 6)
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.callout)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
            actions
                .padding(.top, 28)
        }
    }

    @ViewBuilder
    private var uploader: some View {
        if track.supportsSoundCloudActions {
            Button { profile = track.user } label: {
                HStack(spacing: 8) {
                    Text(track.user.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.forward")
                        .font(.callout.weight(.semibold))
                }
                .font(.headline.weight(.medium))
                .npInk(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .buttonStyle(NPRowStyle(corner: 30, scale: 1.04))
            .padding(.horizontal, -16)
            .accessibilityHint("Opens their profile")
        } else {
            Text(track.user.displayName)
                .font(.headline.weight(.medium))
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(1)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let genre = model.genre { parts.append(genre) }
        if !track.isAwaitingLocalMetadata { parts.append(track.formattedDuration) }
        parts.append(String(Calendar.current.component(.year, from: track.createdAt)))
        return parts.joined(separator: " \u{00B7} ")
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 18) {
                if !isCurrent {
                    Button {
                        Task {
                            await PlayerService.shared.play(track, in: [track])
                            dismiss()
                        }
                    } label: {
                        TVGlassPillLabel(title: "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(TVGlassPillStyle(isProminent: true))
                    .focused($playFocused)
                    .accessibilityIdentifier("behindTheTrack.play")
                    QueueActionButton(track: track)
                }
                AddToPlaylistActionButton(track: track)
                if track.supportsSoundCloudActions {
                    ShareActionButton(track: track)
                }
            }
        }
    }

    // MARK: - People

    @ViewBuilder
    private var people: some View {
        switch model.people {
        case .idle, .loading:
            HStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("People You Follow")
                    .font(.callout)
                    .foregroundStyle(Color.scTextSecondary)
            }
            .accessibilityElement(children: .combine)
        case .loaded(let found) where !found.isEmpty:
            VStack(alignment: .leading, spacing: 40) {
                if !found.likers.isEmpty {
                    BTPeopleGroup(verb: "Liked", users: found.likers) { profile = $0 }
                }
                if !found.reposters.isEmpty {
                    BTPeopleGroup(verb: "Reposted", users: found.reposters) { profile = $0 }
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(track.playbackCount.map(SCStatFormat.compactCount) ?? "\u{2014}", "Plays")
            stat(SCStatFormat.compactCount(track.likeCount), "Likes")
            stat(SCStatFormat.compactCount(track.repostCount), "Reposts")
            stat(model.commentCount(loaded: nil).map(SCStatFormat.compactCount) ?? "\u{2014}", "Comments")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.callout)
                .foregroundStyle(Color.scTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Description

    private func descriptionSection(_ text: String) -> some View {
        let stamps = timestamps(in: text)
        return VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Description")
            Button {
                descriptionExpanded.toggle()
            } label: {
                Text(text)
                    .font(.body)
                    .npInk(.primary)
                    .lineSpacing(4)
                    .lineLimit(descriptionExpanded ? nil : 5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            }
            .buttonStyle(NPRowStyle(corner: 20, scale: 1.02))
            .padding(.horizontal, -22)
            .accessibilityHint(descriptionExpanded ? "Shows less" : "Shows more")
            if !stamps.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(stamps, id: \.self) { seconds in
                            Button { seek(to: seconds) } label: {
                                Label(NPFormat.time(seconds), systemImage: "play.fill")
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .buttonStyle(BTChipStyle())
                            .accessibilityLabel("Play from \(NPFormat.time(seconds))")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
            }
        }
    }

    private func timestamps(in text: String) -> [TimeInterval] {
        var seen = Set<TimeInterval>()
        return TrackDescriptionLinks.timestamps(in: text, duration: track.duration)
            .map(\.seconds)
            .filter { seen.insert($0).inserted }
            .prefix(16)
            .map { $0 }
    }

    private func seek(to seconds: TimeInterval) {
        let service = PlayerService.shared
        let trackID = track.id
        if service.currentTrack?.id == trackID {
            service.seek(to: seconds, expectedTrackID: trackID)
            return
        }
        let target = track
        Task {
            await service.play(target, in: [target])
            service.seek(to: seconds, expectedTrackID: trackID)
        }
    }

    // MARK: - Tags

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Genre and Tags")
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    if let genre = model.genre {
                        chip(genre, query: genre)
                    }
                    ForEach(model.tags, id: \.self) { tag in
                        chip("#\(tag)", query: tag)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }

    private func chip(_ title: String, query: String) -> some View {
        Button {
            navigationState.pendingSearchQuery = query
            navigationState.selectedTab = .search
            dismiss()
        } label: {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(BTChipStyle())
        .accessibilityHint("Searches for \(query)")
    }

    // MARK: - Details

    private var facts: [BehindTheTrackFact] {
        model.facts(
            analysis: summaries.summary(for: track.id),
            pendingAnalysis: TrackTempoKey.pendingMessage(for: track),
            lastPlayed: recents.items.first { $0.track.id == track.id }?.playedAt,
            tracklistCount: setlists.tracklist(for: track.id)?.entries.count
        )
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Details")
            VStack(spacing: 0) {
                ForEach(facts) { fact in
                    if fact.opensTracklist, let onOpenTracklist {
                        MetadataRow(fact.label, value: fact.value, showsChevron: true) {
                            dismiss()
                            onOpenTracklist()
                        }
                    } else {
                        MetadataRow(fact.label, value: fact.value)
                    }
                }
            }
            .padding(.horizontal, -22)
        }
    }

    // MARK: - Links

    private var availableLinks: [BTLink] {
        var links: [BTLink] = []
        if model.about?.purchaseURL != nil { links.append(.buy) }
        if model.about?.isDownloadable == true { links.append(.download) }
        links.append(.open)
        return links
    }

    private var linksSection: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 18) {
                ForEach(availableLinks) { target in
                    Button { link = target } label: {
                        TVGlassPillLabel(title: target == .buy ? (model.about?.purchaseTitle ?? target.title) : target.title, systemImage: target.symbol)
                    }
                    .buttonStyle(TVGlassPillStyle())
                    .accessibilityHint("Shows a code to open it on your phone")
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func url(for target: BTLink) -> URL {
        switch target {
        case .buy: return model.about?.purchaseURL ?? track.permalinkURL
        case .download, .open: return track.permalinkURL
        }
    }

    // MARK: - Related

    @ViewBuilder
    private var relatedSection: some View {
        if related.state == .loaded, !related.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader(related.isFromArtist ? "More by \(track.user.displayName)" : "You Might Also Like")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 40) {
                        ForEach(related.tracks.prefix(12)) { relatedTrack in
                            RelatedTrackCard(track: relatedTrack) {
                                Task {
                                    await PlayerService.shared.play(relatedTrack, in: related.tracks)
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
    }

    private var backdrop: some View {
        ZStack(alignment: .top) {
            Color.scBackground
            CollectionPageMesh(url: track.artworkURL)
            CollectionArtworkBackdrop(url: track.artworkURL, identity: track.id, fade: 460)
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.3)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum BTLink: String, Identifiable {
    case buy
    case download
    case open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buy: return "Buy"
        case .download: return "Free Download"
        case .open: return "Open on SoundCloud"
        }
    }

    var symbol: String {
        switch self {
        case .buy: return "bag"
        case .download: return "arrow.down.circle"
        case .open: return "arrow.up.forward.app"
        }
    }
}

private struct BTChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background {
                    Capsule().fill(isFocused ? Color.scChromeFocus : Color.white.opacity(0.12))
                }
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 16, y: 8)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

private struct BTPeopleGroup: View {
    let verb: String
    let users: [User]
    let openUser: (User) -> Void

    @State private var showsAll = false

    static let previewCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                HStack(spacing: -16) {
                    ForEach(Array(users.prefix(5).enumerated()), id: \.element.id) { index, user in
                        BTAvatar(user: user, size: 52)
                            .overlay { Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 3) }
                            .zIndex(Double(5 - index))
                    }
                }
                .accessibilityHidden(true)
                Text("\(verb) by \(BehindTheTrackModel.peopleSummary(users)) you follow")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(showsAll ? users : Array(users.prefix(Self.previewCount)), id: \.id) { user in
                    Button { openUser(user) } label: {
                        HStack(spacing: 22) {
                            BTAvatar(user: user, size: 64)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName)
                                    .font(.body.weight(.semibold))
                                    .npInk(.primary)
                                    .lineLimit(1)
                                if user.followersCount > 0 {
                                    Text("\(SCStatFormat.compactCount(user.followersCount)) followers")
                                        .font(.caption)
                                        .npInk(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(NPRowStyle(corner: 20, scale: 1.02))
                    .accessibilityHint("Opens their profile")
                }
                if users.count > Self.previewCount {
                    Button { showsAll.toggle() } label: {
                        Text(showsAll ? "Show Less" : "Show All \(users.count)")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(BTChipStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, -22)
        }
    }
}

private struct BTAvatar: View {
    let user: User
    let size: CGFloat

    var body: some View {
        ArtworkImage(url: user.avatarURL, variant: .thumbnail, icon: "person.fill", identity: user.id)
            .aspectRatio(1, contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

private struct MetadataRow: View {
    let title: String
    let value: String
    var showsChevron = false
    var action: (() -> Void)?

    init(_ title: String, value: String, showsChevron: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.showsChevron = showsChevron
        self.action = action
    }

    var body: some View {
        Button { action?() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(title)
                    .font(.body)
                    .npInk(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 24)
                Text(value)
                    .font(.body.weight(.medium))
                    .npInk(.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.callout.weight(.semibold))
                        .npInk(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(.horizontal, 22)
        }
        .buttonStyle(NPRowStyle(corner: 18, scale: 1.02))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityHint(showsChevron ? "Shows the tracklist" : "")
    }
}

private struct RelatedTrackCard: View {
    let track: Track
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ArtworkImage(url: track.artworkURL, identity: track.id)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .scFocus(focused, cornerRadius: CornerRadius.md, reduceMotion: reduceMotion, sizeClass: .tile)
                .kyleCrowned(user: track.user, context: track.title)

            Text(track.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
                .offset(y: focused && !reduceMotion ? 16 : 0)
            Text(track.user.displayName)
                .font(.caption)
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(1)
                .offset(y: focused && !reduceMotion ? 16 : 0)
        }
        .frame(width: 220, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.focus, value: focused)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title) by \(track.user.displayName)")
        .accessibilityAddTraits(.isButton)
    }
}

@MainActor
final class RelatedTracksStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isFromArtist = false
    @Published private(set) var state: CommentsLoadState = .idle

    private var loadedTrackId: String?

    func load(for track: Track) async {
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        state = .loading
        tracks = []

        if let page = try? await SoundCloudAPI.shared.getRelatedTracks(trackId: track.id),
           !page.collection.isEmpty {
            tracks = page.collection.filter { $0.id != track.id }
            isFromArtist = false
            state = .loaded
            return
        }

        guard let page = try? await SoundCloudAPI.shared.getUserTracks(userId: track.user.id) else {
            state = .failed
            return
        }
        tracks = page.collection.filter { $0.id != track.id }
        isFromArtist = true
        state = .loaded
    }
}
