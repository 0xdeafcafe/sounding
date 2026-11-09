import SwiftUI
import AppKit

struct MacSecondaryStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        if let ink = environment.macRowSelectionInk { return ink.opacity(0.72) }
        return environment.colorScheme == .dark ? Color(white: 1, opacity: 0.76) : Color(white: 0.36)
    }
}

enum MacNowPlayingSurface {
    case inspector
    case fullWindow

    var inset: CGFloat { self == .fullWindow ? 26 : 16 }
}

struct MacNowPlayingInspector: View {
    @Binding var pane: MacNowPlayingPane

    private var model: MacNowPlayingModel { .shared }

    var body: some View {
        if model.track != nil {
            MacNowPlayingPanes(pane: $pane, surface: .inspector)
                .padding(.top, 10)
        } else {
            ContentUnavailableView(
                "Nothing Playing",
                systemImage: "music.note",
                description: Text("Up Next, comments and tracklists appear here while music plays.")
            )
            .macFillsPane()
        }
    }
}

struct MacGlassTabs<Option: Hashable>: View {
    let label: String
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    var compact = false

    init(_ label: String, selection: Binding<Option>, options: [Option], compact: Bool = false, title: @escaping (Option) -> String) {
        self.label = label
        self.compact = compact
        self._selection = selection
        self.options = options
        self.title = title
    }

    private enum Density: CaseIterable {
        case roomy
        case snug
        case tight

        var spacing: CGFloat { self == .roomy ? 6 : self == .snug ? 4 : 2 }
    }

    @Environment(\.controlSize) private var controlSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Density.allCases, id: \.self) { density in
                row(density)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func row(_ density: Density) -> some View {
        GlassEffectContainer(spacing: density.spacing) {
            HStack(spacing: density.spacing) {
                ForEach(options, id: \.self) { option in
                    tab(option, density: density)
                }
            }
        }
        .fixedSize()
    }

    private func tab(_ option: Option, density: Density) -> some View {
        let isSelected = selection == option
        let isSmall = compact || controlSize == .small || controlSize == .mini
        let horizontal: CGFloat = {
            switch density {
            case .roomy: return isSmall ? 12 : 16
            case .snug: return isSmall ? 9 : 12
            case .tight: return isSmall ? 6 : 9
            }
        }()
        return Button {
            withAnimation(.snappy) { selection = option }
        } label: {
            Text(title(option))
                .font(isSmall ? .callout : .body)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .padding(.horizontal, horizontal)
                .padding(.vertical, isSmall ? 4 : 6)
                .background {
                    if isSelected { Capsule().fill(Color.primary.opacity(0.86)) }
                }
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct MacNowPlayingPanes: View {
    @Binding var pane: MacNowPlayingPane
    let surface: MacNowPlayingSurface
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared

    private var model: MacNowPlayingModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGlassTabs(
                "Pane",
                selection: $pane,
                options: MacNowPlayingPane.allCases.filter { (model.track?.supportsSoundCloudActions != false || $0 != .comments) && !(hidesLyrics && $0 == .lyrics) },
                title: \.title
            )
            .controlSize(surface == .fullWindow ? .regular : .small)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, surface.inset)
            .padding(.bottom, surface == .fullWindow ? 16 : 12)

            if let track = model.track {
                Group {
                    switch pane {
                    case .queue: MacRoutedUpNextPane(surface: surface)
                    case .lyrics: MacLyricsPane(track: track)
                    case .comments where track.supportsSoundCloudActions: MacCommentsPane(track: track, surface: surface)
                    case .tracklist, .comments: MacTracklistPane(track: track, surface: surface)
                    case .about: MacAboutPane(track: track, surface: surface, pane: $pane)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }
        }
        .task(id: model.track?.id) { model.ensureComments() }
        .onChange(of: hidesLyrics, initial: true) { _, hides in
            if hides && pane == .lyrics { pane = .tracklist }
        }
    }

    private var hidesLyrics: Bool {
        model.track.map { setlists.isMix($0) } ?? false
    }
}

private struct MacLyricsPane: View {
    let track: Track

    var body: some View {
        let anchor = MacPlaybackTimeline.shared.anchor
        NowPlayingLyrics(
            track: track,
            nextTrack: PlayerService.shared.upcomingTrack,
            playhead: LyricsPlayhead(position: anchor.position, date: anchor.date, rate: anchor.rate),
            style: .mac,
            onSeek: { MacPlaybackTimeline.shared.seek(to: $0) }
        )
    }
}

private struct MacPaneHeading<Eyebrow: View, Actions: View>: View {
    let title: String
    let surface: MacNowPlayingSurface
    var detail: String? = nil
    @ViewBuilder var eyebrow: Eyebrow
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                eyebrow
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, surface.inset)
        .padding(.bottom, 8)
    }
}

private struct MacPaneList<Content: View>: View {
    let surface: MacNowPlayingSurface
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 3, leading: surface.inset - 8, bottom: 3, trailing: surface.inset - 8))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 12, for: .scrollContent)
    }
}

private struct MacRowHighlight: View {
    let isOn: Bool
    let surface: MacNowPlayingSurface

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOn ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
            .padding(.horizontal, surface.inset - 10)
    }
}


private func macPlayingFromLabel(_ source: PlaybackQueueSource) -> String {
    "Playing from \(source.title)"
}

private struct MacRoutedUpNextPane: View {
    let surface: MacNowPlayingSurface

    @Environment(\.outputRouter) private var outputRouter

    var body: some View {
        if let outputRouter {
            OutputModesReader(outputRouter) { router in
                if router.isRemote {
                    MacRemoteUpNextPane(client: router.client, surface: surface)
                } else {
                    MacUpNextPane(surface: surface)
                }
            }
        } else {
            MacUpNextPane(surface: surface)
        }
    }
}

@MainActor
private func macUpNextSectionHeader(_ title: String, systemImage: String? = nil, note: String? = nil) -> some View {
    HStack(spacing: 6) {
        if let systemImage {
            Image(systemName: systemImage)
                .foregroundStyle(MacSecondaryStyle())
        }
        Text(title)
        Spacer()
        if let note {
            Text(note)
                .fontWeight(.regular)
                .foregroundStyle(MacSecondaryStyle())
        }
    }
    .font(.subheadline.weight(.semibold))
    .padding(.horizontal, 8)
    .padding(.top, 8)
    .accessibilityAddTraits(.isHeader)
}

private struct MacRemoteUpNextPane: View {
    @ObservedObject var client: CompanionClient
    let surface: MacNowPlayingSurface

    var body: some View {
        let upcoming = client.upNext
        VStack(spacing: 0) {
            MacPaneHeading(title: summary(upcoming), surface: surface, detail: client.queueSource.map(macPlayingFromLabel)) {
                Text("Up Next")
            } actions: {
                MacShuffleToggle()
                MacRepeatToggle()
            }
            .controlSize(.large)

            if upcoming.isEmpty {
                ContentUnavailableView(
                    "Nothing Up Next",
                    systemImage: "list.bullet",
                    description: Text("Use Play Next or Play Last on any track to queue it on \(client.linkedName).")
                )
                .macFillsPane()
            } else {
                let layout = client.upNextLayout
                MacPaneList(surface: surface) {
                    if !layout.playingNext.isEmpty {
                        macUpNextSectionHeader("Playing Next", note: layout.autoMixPick == nil && isAutoMixOn ? "Plays before Auto Mix" : nil)
                        rows(upcoming, layout.playingNext)
                    }
                    if let pick = layout.autoMixPick {
                        macUpNextSectionHeader("Auto Mix", systemImage: "arrow.triangle.merge")
                        rows(upcoming, pick..<(pick + 1))
                    }
                    if !layout.continuePlaying.isEmpty {
                        macUpNextSectionHeader("Continue Playing")
                        rows(upcoming, layout.continuePlaying)
                    }
                }
            }
        }
        .upNextFillTarget { MacPlayback.insert($0) }
    }

    private var isAutoMixOn: Bool {
        client.telemetry.autoMixLive != nil || client.telemetry.djState?.isAutoMixEnabled == true
    }

    private func rows(_ upcoming: [(index: Int, track: QueueTrack)], _ range: Range<Int>) -> some View {
        ForEach(upcoming[range], id: \.index) { entry in
            MacRemoteQueueRow(client: client, track: entry.track, index: entry.index)
        }
    }

    private func summary(_ upcoming: [(index: Int, track: QueueTrack)]) -> String {
        guard !upcoming.isEmpty else { return "Queue empty on \(client.linkedName)" }
        let seconds = upcoming.reduce(0) { $0 + $1.track.duration }
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(upcoming.count) \(upcoming.count == 1 ? "track" : "tracks") · \(length) on \(client.linkedName)"
    }
}

private struct MacRemoteQueueRow: View {
    @ObservedObject var client: CompanionClient
    let track: QueueTrack
    let index: Int

    var body: some View {
        Button {
            client.jump(to: index)
        } label: {
            HStack(spacing: 12) {
                ArtworkThumbnail(url: track.artworkURL, identity: track.id, size: 38, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text(macFormatTime(track.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(MacSecondaryStyle())
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macHoverRowHighlight(cornerRadius: 10)
        .upNextInsertionTarget(edge: .top) { MacPlayback.insert($0, at: index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artist), \(track.formattedDuration)")
        .accessibilityHint("Plays from here")
        .accessibilityAction(named: "Play Next") { client.playNext(queueIndex: index) }
        .accessibilityAction(named: "Remove from Up Next") { client.remove(at: index) }
        .contextMenu {
            Button("Play Next") { client.playNext(queueIndex: index) }
            Button("Remove from Up Next") { client.remove(at: index) }
        }
    }
}

private struct MacUpNextPane: View {
    let surface: MacNowPlayingSurface

    @ObservedObject private var player = PlayerService.shared
    private let queueStore = PlaybackQueueStore.shared

    private var upcoming: [(index: Int, track: Track)] {
        let queue = queueStore.queue
        let start = queueStore.currentIndex + 1
        guard start < queue.count else { return [] }
        return (start..<queue.count).map { ($0, queue[$0]) }
    }

    private var isAutoMixOn: Bool {
        player.djDirector.snapshot?.isAutoMixEnabled ?? player.isAutoMixEnabled
    }

    var body: some View {
        let upcoming = upcoming
        VStack(spacing: 0) {
            MacPaneHeading(title: summary(upcoming), surface: surface, detail: player.queueSource.map(macPlayingFromLabel)) {
                Text("Up Next")
            } actions: {
                MacShuffleToggle()
                MacRepeatToggle()
            }
            .controlSize(.large)

            if upcoming.isEmpty {
                ContentUnavailableView(
                    "Nothing Up Next",
                    systemImage: "list.bullet",
                    description: Text("Use Play Next or Play Last on any track to queue it here.")
                )
                .macFillsPane()
            } else {
                let layout = UpNextLayout.make(upcomingCount: upcoming.count, playingNextCount: player.playingNextCount, autoMixOn: isAutoMixOn || AutoMixLive.shared.state != nil)
                let mix = AutoMixLive.shared.state.flatMap { $0.stage == .upcoming ? $0 : nil }
                MacPaneList(surface: surface) {
                    if !layout.playingNext.isEmpty {
                        header("Playing Next", note: layout.autoMixPick == nil && (isAutoMixOn || mix != nil) ? "Plays before Auto Mix" : nil)
                        rows(upcoming, layout.playingNext, section: .playingNext, mix: mix)
                    }
                    if let pick = layout.autoMixPick {
                        header("Auto Mix", systemImage: "arrow.triangle.merge")
                        rows(upcoming, pick..<(pick + 1), section: .autoMix, mix: mix)
                    }
                    if !layout.continuePlaying.isEmpty {
                        header("Continue Playing")
                        rows(upcoming, layout.continuePlaying, section: .continuePlaying, mix: mix)
                    }
                }
            }
        }
        .upNextFillTarget { MacPlayback.insert($0) }
    }

    private func header(_ title: String, systemImage: String? = nil, note: String? = nil) -> some View {
        macUpNextSectionHeader(title, systemImage: systemImage, note: note)
    }

    private func rows(_ upcoming: [(index: Int, track: Track)], _ range: Range<Int>, section: UpNextSection, mix: AutoMixLiveState?) -> some View {
        ForEach(range, id: \.self) { offset in
            let entry = upcoming[offset]
            MacQueueRow(
                track: entry.track,
                index: entry.index,
                section: section,
                reason: section == .autoMix ? (reason(for: entry.track) ?? "Picked to match this track") : nil,
                mix: offset == 0 ? mix : nil,
                canMoveUp: offset > range.lowerBound,
                canMoveDown: offset < range.upperBound - 1
            )
        }
    }

    private func reason(for track: Track) -> String? {
        let live = AutoMixLive.shared
        guard let state = live.state, state.incomingTrackId == track.id || live.isFixture else { return nil }
        return state.why
    }

    private func summary(_ upcoming: [(index: Int, track: Track)]) -> String {
        guard !upcoming.isEmpty else { return "Queue empty" }
        let seconds = upcoming.reduce(0) { $0 + $1.track.duration }
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(upcoming.count) \(upcoming.count == 1 ? "track" : "tracks") · \(length)"
    }
}

private struct MacQueueRow: View {
    let track: Track
    let index: Int
    var section: UpNextSection = .continuePlaying
    var reason: String?
    var mix: AutoMixLiveState?
    var canMoveUp = false
    var canMoveDown = false

    @State private var isHovering = false

    var body: some View {
        Button {
            Task { await PlayerService.shared.playTrackAt(index: index) }
        } label: {
            HStack(spacing: 12) {
                ArtworkThumbnail(
                    url: track.artworkURL,
                    identity: track.id,
                    size: 38,
                    cornerRadius: 6,
                    isAvailable: track.streamURL != nil,
                    crownUser: track.user,
                    crownContext: track.title
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                    Text(track.user.displayName)
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                    if let reason {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(MacSecondaryStyle())
                    }
                    if let mix {
                        MacUpNextMixCountdown(state: mix)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if isHovering {
                    Button {
                        Task { await PlayerService.shared.removeFromQueue(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from Up Next")
                    .accessibilityHidden(true)
                }
                Text(macFormatTime(track.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(MacSecondaryStyle())
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .macHoverRowHighlight(cornerRadius: 10)
        .upNextInsertionTarget(edge: .top) { MacPlayback.insert($0, at: index) }
        .trackDragSource(track)
        .macTrackAccessibility(track: track, includesPlay: false)
        .accessibilityHint("Plays from here")
        .accessibilityAction(named: "Remove from Up Next") {
            Task { await PlayerService.shared.removeFromQueue(at: index) }
        }
        .contextMenu {
            MacTrackContextMenu(track: track)
            Divider()
            if section != .playingNext {
                Button("Play Next") { PlayerService.shared.moveToPlayingNext(at: index) }
            }
            if canMoveUp {
                Button("Move Up") { PlayerService.shared.moveQueueItem(from: index, to: index - 1) }
            }
            if canMoveDown {
                Button("Move Down") { PlayerService.shared.moveQueueItem(from: index, to: index + 1) }
            }
            Button("Remove from Up Next") {
                Task { await PlayerService.shared.removeFromQueue(at: index) }
            }
        }
    }
}

private struct MacUpNextMixCountdown: View {
    let state: AutoMixLiveState

    var body: some View {
        TimelineView(.periodic(from: state.startsAt, by: state.isPlaying ? 1 : 3_600)) { context in
            HStack(spacing: 4) {
                Image(systemName: state.symbolName)
                    .imageScale(.small)
                Text("\(state.moveName) \(AutoMixLiveState.countdown(state.clock(at: context.date).secondsUntilStart))")
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(MacSecondaryStyle())
        }
    }
}


private struct MacCommentsPane: View {
    let track: Track
    let surface: MacNowPlayingSurface

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visibleCount = 0
    @State private var currentID: String?
    @State private var composeSecond = 0
    @State private var draft = ""
    @State private var isPosting = false
    @State private var userScrolledAt = Date.distantPast

    private var model: MacNowPlayingModel { .shared }
    private var timeline: MacPlaybackTimeline { .shared }

    var body: some View {
        VStack(spacing: 0) {
            MacPaneHeading(title: "\(model.commentCount) \(model.commentCount == 1 ? "comment" : "comments")", surface: surface) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(timeline.isPlaying ? Color.scAccent : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text("Following playback")
                }
            } actions: {
                EmptyView()
            }

            switch model.commentsState {
            case .loading:
                MacLoadingView()
            case .failed:
                ContentUnavailableView {
                    Label("Couldn’t Load Comments", systemImage: "quote.bubble")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") { model.ensureComments() }
                }
                .macFillsPane()
            case .loaded:
                list
            }

            compose
        }
        .macSamplePlayhead(every: .milliseconds(500)) { position in
            update(position)
        }
        .onChange(of: model.timedComments.count) {
            update(timeline.position())
        }
    }

    private var list: some View {
        let comments = model.timedComments
        let reached = min(visibleCount, comments.count)
        return ScrollViewReader { proxy in
            MacPaneList(surface: surface) {
                if comments.isEmpty {
                    Text("No comments yet at this point.\nBe the first.")
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                ForEach(comments.prefix(reached)) { comment in
                    MacCommentRow(comment: comment, isCurrent: comment.id == currentID)
                        .id(comment.id)
                        .listRowBackground(MacRowHighlight(isOn: comment.id == currentID, surface: surface))
                }
                if reached < comments.count {
                    Section {
                        ForEach(comments.dropFirst(reached)) { comment in
                            MacCommentRow(comment: comment, isCurrent: false, isLater: true)
                                .id(comment.id)
                        }
                    } header: {
                        Text(CommentTimeline.laterTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MacSecondaryStyle())
                            .id(Self.laterHeaderID)
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { userScrolledAt = .now }
            }
            .onChange(of: visibleCount) { old, new in
                guard Date().timeIntervalSince(userScrolledAt) > 4 else { return }
                withAnimation(reduceMotion || new < old ? nil : .easeOut(duration: 0.3)) {
                    followPlayhead(proxy, comments: comments)
                }
            }
            .onAppear { followPlayhead(proxy, comments: comments) }
        }
    }

    private static let laterHeaderID = "comments.later"

    private func followPlayhead(_ proxy: ScrollViewProxy, comments: [Comment]) {
        let reached = min(visibleCount, comments.count)
        if reached > 0 {
            proxy.scrollTo(comments[reached - 1].id, anchor: UnitPoint(x: 0.5, y: 0.3))
        } else if !comments.isEmpty {
            proxy.scrollTo(Self.laterHeaderID, anchor: .top)
        }
    }

    private var compose: some View {
        let signedIn = credentials.currentUser != nil
        return HStack(spacing: 8) {
            MacAvatar(
                url: credentials.currentUser?.avatarURL,
                name: credentials.currentUser?.displayName ?? "You",
                size: 24
            )
            TextField(
                signedIn ? "Comment at \(macFormatTime(TimeInterval(composeSecond)))" : "Sign in to comment",
                text: $draft
            )
            .textFieldStyle(.plain)
            .onSubmit(post)
            .disabled(!signedIn || isPosting)
            Button(action: post) {
                Label("Post", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isPosting || !signedIn)
            .help("Post Comment")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .padding(.horizontal, surface.inset)
        .padding(.top, 8)
        .padding(.bottom, surface == .fullWindow ? 18 : 14)
    }

    private func post() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !isPosting else { return }
        let position = timeline.position()
        isPosting = true
        Task {
            if await model.post(text, at: position) {
                draft = ""
                userScrolledAt = .distantPast
            }
            isPosting = false
        }
    }

    private func update(_ position: TimeInterval) {
        let comments = model.timedComments
        let split = CommentTimeline.split(comments, at: position)
        if visibleCount != split.reachedCount { visibleCount = split.reachedCount }
        let current = split.currentIndex.map { comments[$0].id }
        if currentID != current { currentID = current }
        let second = Int(position)
        if composeSecond != second { composeSecond = second }
    }
}

struct MacAvatar: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        SCArtworkResolver(url: url, variant: .thumbnail) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: name, subject: .person)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct MacCommentRow: View {
    let comment: Comment
    let isCurrent: Bool
    var isLater = false

    @Environment(\.openURL) private var openURL

    private var time: TimeInterval { comment.timeInTrack ?? 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MacAvatar(url: comment.user.avatarURL, name: comment.user.id, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.user.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if isLater {
                        Label("at \(macFormatTime(time))", systemImage: CommentTimeline.laterSymbol)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(MacSecondaryStyle())
                    } else {
                        Text(macFormatTime(time))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(MacSecondaryStyle())
                    }
                }
                Text(comment.body)
                    .font(.body)
                    .lineLimit(isCurrent ? 6 : 3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(isLater ? AnyShapeStyle(MacSecondaryStyle()) : AnyShapeStyle(.primary))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { MacPlaybackTimeline.shared.seek(to: time) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isLater
                ? CommentTimeline.laterAccessibilityLabel(name: comment.user.displayName, clock: macFormatTime(time), body: comment.body)
                : "\(comment.user.displayName), \(macFormatTime(time)), \(comment.body)"
        )
        .accessibilityValue(isCurrent ? "Current" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { MacPlaybackTimeline.shared.seek(to: time) }
        .contextMenu {
            Button("Jump to \(macFormatTime(time))") { MacPlaybackTimeline.shared.seek(to: time) }
            Button("View \(comment.user.displayName) on SoundCloud") { openURL(comment.user.permalinkURL) }
        }
    }
}


struct MacTracklistPane: View {
    let track: Track
    let surface: MacNowPlayingSurface

    @ObservedObject private var store = SetlistIntelligenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentIndex: Int?
    @State private var userScrolledAt = Date.distantPast
    @State private var identify: Identify = .idle

    private enum Identify: Equatable {
        case idle
        case listening(TimeInterval)
        case found(SetlistSegment, TimeInterval)
        case noMatch(TimeInterval)
        case failed(String)
    }

    private var timeline: MacPlaybackTimeline { .shared }

    private var tracklist: Tracklist? {
        let list = store.tracklist(for: track.id)
        return list?.isEmpty == false ? list : nil
    }

    private var isMix: Bool { DeckIdentityResolver.isLikelyMix(track) }
    private var isScanning: Bool { store.scanningTrackIds.contains(track.id) }

    static func isUnknown(_ segment: SetlistSegment) -> Bool {
        let title = segment.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.isEmpty || ["id", "unknown", "unidentified", "id - id", "id – id"].contains(title)
    }

    var body: some View {
        let tracklist = tracklist
        VStack(spacing: 0) {
            MacPaneHeading(title: heading(tracklist).title, surface: surface) {
                Text(heading(tracklist).eyebrow)
            } actions: {
                identifyButton
            }

            if identify != .idle {
                identifyResult
                    .padding(.horizontal, surface.inset)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let tracklist {
                list(tracklist)
            } else {
                emptyState
                    .macFillsPane()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: identify)
        .macSamplePlayhead(every: .seconds(1), isEnabled: tracklist != nil) { position in
            let index = self.tracklist?.currentIndex(at: position)
            if index != currentIndex { currentIndex = index }
        }
        .onChange(of: track.id) { identify = .idle }
    }

    private func heading(_ tracklist: Tracklist?) -> (eyebrow: String, title: String) {
        guard let tracklist else {
            if isMix { return (isScanning ? "Finding tracks" : "Mix", "No tracklist yet") }
            return ("Single track", "No tracklist")
        }
        let total = tracklist.entries.count
        let unknown = tracklist.entries.filter { Self.isUnknown($0.segment) }.count
        let eyebrow = isScanning ? "Still identifying…" : unknown > 0 ? "\(total - unknown) identified · \(unknown) unknown" : "All identified"
        return (eyebrow, "\(total) \(total == 1 ? "track" : "tracks")")
    }

    private var identifyButton: some View {
        let listening: Bool = { if case .listening = identify { return true } else { return false } }()
        return Button(action: runIdentify) {
            Label(listening ? "Listening…" : "Identify This Track", systemImage: "shazam.logo")
                .symbolEffect(.pulse, options: .repeating, isActive: listening && !reduceMotion)
        }
        .modifier(MacPaneButtonStyle(surface: surface))
        .disabled(listening)
        .help("Identify the track playing in this mix now")
    }

    @ViewBuilder
    private var identifyResult: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 10) {
                switch identify {
                case .idle:
                    EmptyView()
                case .listening(let at):
                    ProgressView().controlSize(.small)
                    resultText(title: "Listening…", detail: "Matching \(macFormatTime(at))")
                case .found(let segment, let at):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    resultText(
                        title: segment.title,
                        detail: [segment.artist, "Found at \(macFormatTime(at))"].compactMap { $0 }.joined(separator: " · ")
                    )
                    if let song = store.identifiedSongs[track.id] {
                        Button("Details…") { IdentifySongPresenter.shared.show(song) }
                            .help("Find it on SoundCloud, open it in Apple Music or share it")
                    }
                    Button("Done") { identify = .idle }
                case .noMatch(let at):
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(MacSecondaryStyle())
                    resultText(title: "No match", detail: "Nothing recognised at \(macFormatTime(at))")
                    Button("Done") { identify = .idle }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(MacSecondaryStyle())
                    resultText(title: "Couldn’t identify", detail: message)
                    Button("Done") { identify = .idle }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ tracklist: Tracklist) -> some View {
        ScrollViewReader { proxy in
            MacPaneList(surface: surface) {
                ForEach(tracklist.entries) { entry in
                    let isCurrent = entry.index == currentIndex
                    MacTracklistRow(entry: entry, isCurrent: isCurrent) {
                        userScrolledAt = .distantPast
                        timeline.seek(to: entry.startSeconds + 0.05)
                    }
                    .id(entry.id)
                    .listRowBackground(MacRowHighlight(isOn: isCurrent, surface: surface))
                    .contextMenu {
                        Button("Open Setlist Editor") { MacRootSelection.shared.request(setlist: track) }
                    }
                    .accessibilityAction(named: "Open Setlist Editor") {
                        MacRootSelection.shared.request(setlist: track)
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { userScrolledAt = .now }
            }
            .onChange(of: currentIndex) { _, index in
                guard let index, tracklist.entries.indices.contains(index),
                      Date().timeIntervalSince(userScrolledAt) > 5 else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                    proxy.scrollTo(tracklist.entries[index].id, anchor: UnitPoint(x: 0.5, y: 0.28))
                }
            }
            .onAppear {
                guard let index = currentIndex, tracklist.entries.indices.contains(index) else { return }
                proxy.scrollTo(tracklist.entries[index].id, anchor: UnitPoint(x: 0.5, y: 0.28))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isMix {
            ContentUnavailableView {
                Label("No Tracklist", systemImage: "music.note.list")
            } description: {
                Text("Tracklists appear for DJ mixes and long sets. Identify still works on anything playing.")
            }
        } else if isScanning {
            MacLoadingView("Listening for track changes…")
        } else if let error = store.scanErrors[track.id] {
            ContentUnavailableView {
                Label("Track Recognition Paused", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text(Self.friendly(error))
            } actions: {
                Button("Open Setlist Editor") { MacRootSelection.shared.request(setlist: track) }
            }
        } else {
            ContentUnavailableView {
                Label("No Tracks Identified Yet", systemImage: "music.note.list")
            } description: {
                Text("Find the tracks in this mix, or add them yourself in the editor.")
            } actions: {
                Button("Find Tracks") {
                    Task { await store.requestTracklist(for: track) }
                }
                Button("Open Setlist Editor") { MacRootSelection.shared.request(setlist: track) }
            }
        }
    }

    private static func friendly(_ error: String) -> String {
        let normalized = error.lowercased()
        if normalized.contains("shazamcore") || normalized.contains("error 102") {
            return "Shazam couldn’t identify this mix. Retry from the editor, or add the tracks yourself."
        }
        return "Track recognition didn’t finish. Retry from the editor, or add the tracks yourself."
    }

    private func runIdentify() {
        let position = timeline.position()
        identify = .listening(position)
        let track = track
        Task {
            let result = await store.identify(track, at: position)
            guard self.track.id == track.id else { return }
            switch result {
            case .matched(let segment): identify = .found(segment, position)
            case .noMatch: identify = .noMatch(position)
            case .unavailable(let message), .failed(let message): identify = .failed(message)
            }
        }
    }
}

private struct MacTracklistRow: View {
    let entry: TracklistEntry
    let isCurrent: Bool
    let onSeek: () -> Void

    var body: some View {
        let unknown = MacTracklistPane.isUnknown(entry.segment)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(macFormatTime(entry.startSeconds))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(MacSecondaryStyle())
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(unknown ? "ID" : entry.segment.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(unknown ? .secondary : .primary)
                Text(unknown ? "Unidentified" : (entry.segment.artist ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(MacSecondaryStyle())
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 7)
        .padding(.bottom, isCurrent ? 11 : 7)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottomLeading) {
            if isCurrent {
                MacSegmentProgress(start: entry.startSeconds, end: entry.endSeconds)
                    .padding(.leading, 8)
                    .padding(.trailing, 72)
                    .padding(.bottom, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSeek)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(macFormatTime(entry.startSeconds)), \(unknown ? "Unidentified" : MacNowPlayingView.entryLabel(entry.segment))")
        .accessibilityValue(isCurrent ? "Now playing" : "")
        .accessibilityHint("Jumps to this track")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSeek() }
    }
}

private struct MacSegmentProgress: View {
    let start: TimeInterval
    let end: TimeInterval

    var body: some View {
        MacLayerProgress(
            style: .line,
            base: Color(nsColor: .quaternaryLabelColor),
            fill: Color(nsColor: .secondaryLabelColor),
            start: start,
            end: end,
            override: nil,
            anchor: MacPlaybackTimeline.shared.anchor
        )
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

private struct MacPaneButtonStyle: ViewModifier {
    let surface: MacNowPlayingSurface

    func body(content: Content) -> some View {
        if surface == .fullWindow {
            content.buttonStyle(.glass).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).controlSize(.regular)
        }
    }
}


private struct MacAboutPane: View {
    let track: Track
    let surface: MacNowPlayingSurface
    @Binding var pane: MacNowPlayingPane

    var body: some View {
        MacBehindTheTrackPane(track: track, surface: surface, onTracklist: { pane = .tracklist }) {
            MacPaneHeading(title: "Behind the Track", surface: surface) {
                Text(track.title)
            } actions: {
                EmptyView()
            }
        }
    }
}
