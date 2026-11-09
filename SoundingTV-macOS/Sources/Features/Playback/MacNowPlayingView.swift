import SwiftUI
import AppKit
import Combine
import Observation

enum MacNowPlayingPane: String, CaseIterable, Identifiable {
    case queue
    case lyrics
    case comments
    case tracklist
    case about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: return "Up Next"
        case .lyrics: return "Lyrics"
        case .comments: return "Comments"
        case .tracklist: return "Tracklist"
        case .about: return "Behind the Track"
        }
    }

    var systemImage: String {
        switch self {
        case .queue: return "list.bullet"
        case .lyrics: return "text.quote"
        case .comments: return "quote.bubble"
        case .tracklist: return "music.note.list"
        case .about: return "info.circle"
        }
    }
}

enum MacCommentsLoadState: Equatable {
    case loading
    case loaded
    case failed
}

@MainActor
final class MacNowPlayingPresentation: ObservableObject {
    static let shared = MacNowPlayingPresentation()
    @Published var pane: MacNowPlayingPane = .tracklist
    @Published private(set) var presentationRequest = 0
    @Published var showsAutoMixSetup = false
    @Published private(set) var isFullWindow = false
    weak var capsuleArtworkView: NSView?
    private(set) var morphSource: CGRect?
    private(set) var morphImage: NSImage?
    private weak var pendingCoverView: NSView?
    private var pendingCoverImage: NSImage?

    private init() {}

    func prepareCoverMorph(from view: NSView?, image: NSImage?) {
        pendingCoverView = view
        pendingCoverImage = image
    }

    func presentFromCover() {
        guard !isFullWindow else { return }
        let rect = MacViewAnchor.windowRect(of: pendingCoverView)
        let image = pendingCoverImage
        pendingCoverView = nil
        pendingCoverImage = nil
        present()
        if let rect {
            morphSource = rect
            morphImage = image
        }
    }

    func present(_ pane: MacNowPlayingPane? = nil) {
        morphImage = nil
        if let pane {
            self.pane = pane
        } else if self.pane == .tracklist, let track = MacNowPlayingModel.shared.track,
                  !DeckIdentityResolver.isLikelyMix(track),
                  SetlistIntelligenceStore.shared.tracklist(for: track.id)?.isEmpty != false {
            self.pane = .queue
        }
        morphSource = MacViewAnchor.windowRect(of: capsuleArtworkView)
        presentationRequest &+= 1
    }

    func consumePresentationRequest() {
        presentationRequest = 0
    }

    @Published private(set) var closeRequest = 0

    func requestClose() {
        closeRequest &+= 1
    }

    func toggle() {
        if isFullWindow { requestClose() } else { present() }
    }

    func noteFullWindow(_ visible: Bool) {
        if isFullWindow != visible { isFullWindow = visible }
    }
}

@MainActor
@Observable
final class MacNowPlayingModel {
    static let shared = MacNowPlayingModel()

    private(set) var track: Track?
    private(set) var commentsState: MacCommentsLoadState = .loading
    private(set) var timedComments: [Comment] = []
    private(set) var commentCount = 0
    private(set) var palette: ArtworkPalette = .fallback
    private(set) var artwork: NSImage?

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var commentsTrackID: String?
    @ObservationIgnored private var commentsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var output: OutputRouter?
    @ObservationIgnored private var outputCancellables = Set<AnyCancellable>()
    @ObservationIgnored private var remoteTrackTask: Task<Void, Never>?

    private init() {
        PlayerService.shared.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] _ in
                Task { @MainActor in self?.resolveSource() }
            }
            .store(in: &cancellables)
    }

    func attach(output: OutputRouter) {
        guard self.output !== output else { return }
        self.output = output
        outputCancellables.removeAll()
        output.$current
            .sink { [weak self] _ in
                Task { @MainActor in self?.resolveSource() }
            }
            .store(in: &outputCancellables)
        output.client.telemetry.$playback
            .map { $0?.trackId }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.resolveSource() }
            }
            .store(in: &outputCancellables)
        resolveSource()
    }

    private func resolveSource() {
        let player = PlayerService.shared
        guard let output, output.isRemote else {
            remoteTrackTask?.cancel()
            remoteTrackTask = nil
            if track?.id != player.currentTrack?.id { trackDidChange(player.currentTrack) }
            return
        }
        guard let id = output.client.telemetry.playback?.trackId else { return }
        guard track?.id != id else { return }
        if let known = ([player.currentTrack].compactMap { $0 } + player.queue).first(where: { $0.id == id }) {
            remoteTrackTask?.cancel()
            remoteTrackTask = nil
            trackDidChange(known)
            return
        }
        #if DEBUG
        if VisualFixtures.isEnabled {
            let fixture = ([VisualFixtures.nowPlayingMix] + VisualFixtures.tracks).first { $0.id == id }
            trackDidChange(fixture)
            return
        }
        #endif
        remoteTrackTask?.cancel()
        remoteTrackTask = Task { @MainActor [weak self] in
            let fetched = try? await SoundCloudAPI.shared.getTrack(id: id)
            guard !Task.isCancelled, let self,
                  self.output?.client.telemetry.playback?.trackId == id else { return }
            self.remoteTrackTask = nil
            self.trackDidChange(fetched)
        }
    }

    private func trackDidChange(_ track: Track?) {
        self.track = track
        commentsTask?.cancel()
        commentsTrackID = nil
        commentsState = .loading
        timedComments = []
        commentCount = 0
        artworkTask?.cancel()
        guard let track else {
            palette = .fallback
            artwork = nil
            return
        }
        Task { await MacTrackEngagement.shared.refreshLikeState(track) }
        SetlistIntelligenceStore.shared.seed(track: track, comments: [])
        let url = track.artworkURL ?? track.user.largeAvatarURL ?? track.user.avatarURL
        if let url, let cached = ArtworkCache.shared.bestCachedImage(for: url, variant: .hero) {
            artwork = cached
        }
        artworkTask = Task { @MainActor [weak self] in
            guard let url else {
                self?.palette = .fallback
                self?.artwork = nil
                return
            }
            async let paletteResult = ArtworkCache.shared.palette(for: url)
            async let imageResult = ArtworkCache.shared.image(for: url, variant: .hero)
            let (palette, image) = await (paletteResult, imageResult)
            guard !Task.isCancelled, let self else { return }
            self.palette = palette
            self.artwork = image
        }
    }

    func ensureComments() {
        guard let track, track.supportsSoundCloudActions, commentsTrackID != track.id else { return }
        commentsTrackID = track.id
        commentsState = .loading
        commentsTask = Task { @MainActor [weak self] in
            let comments: [Comment]?
            var next: URL?
            #if DEBUG
            if VisualFixtures.isEnabled {
                comments = VisualFixtures.longSetEnabled && track.id == VisualFixtures.longSet.id ? VisualFixtures.longSetCommentList() : MacNowPlayingFixtures.comments(for: track)
            } else {
                let page = try? await SoundCloudAPI.shared.getComments(trackId: track.id)
                comments = page?.collection
                next = page?.nextHref
            }
            #else
            let page = try? await SoundCloudAPI.shared.getComments(trackId: track.id)
            comments = page?.collection
            next = page?.nextHref
            #endif
            guard !Task.isCancelled, let self, self.track?.id == track.id else { return }
            guard let comments else {
                self.commentsState = .failed
                self.commentsTrackID = nil
                return
            }
            self.absorb(comments)
            self.commentsState = .loaded
            SetlistIntelligenceStore.shared.seed(track: track, comments: comments)
            guard let next else { return }
            await self.loadRemainingComments(from: next, track: track, loaded: comments)
        }
    }

    private static let maxCommentPages = 10

    private func loadRemainingComments(from start: URL, track: Track, loaded: [Comment]) async {
        var all = loaded
        var known = Set(loaded.map(\.id))
        var next: URL? = start
        var pages = 1
        while let url = next, pages < Self.maxCommentPages {
            guard !Task.isCancelled, self.track?.id == track.id else { return }
            if case .waiting(_, let until) = SoundCloudGateway.shared.trafficSafetyState() {
                try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow + 1)))
                continue
            }
            do {
                let page = try await SoundCloudAPI.shared.getPage(Comment.self, from: url)
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                let fresh = page.collection.filter { known.insert($0.id).inserted }
                all += fresh
                absorb(all)
                next = page.nextHref
                pages += 1
            } catch APIError.temporarilyBlocked(let until, _) {
                try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow + 1)))
            } catch {
                break
            }
        }
        guard !Task.isCancelled, self.track?.id == track.id else { return }
        SetlistIntelligenceStore.shared.seed(track: track, comments: all)
    }

    func post(_ body: String, at position: TimeInterval) async -> Bool {
        guard let track else { return false }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        do {
            let comment = try await SoundCloudAPI.shared.postComment(
                trackId: track.id,
                body: text,
                timestampMillis: Int((position * 1000).rounded())
            )
            guard self.track?.id == track.id else { return true }
            absorb(timedComments + [comment])
            return true
        } catch {
            return false
        }
    }

    private func absorb(_ comments: [Comment]) {
        commentCount = comments.count
        timedComments = CommentTimeline.ordered(comments)
    }
}

struct MacNowPlayingView: View {
    var onClose: () -> Void
    var onWillClose: () -> Void = {}

    @ObservedObject private var presentation = MacNowPlayingPresentation.shared
    @ObservedObject private var engagement = MacTrackEngagement.shared
    @ObservedObject private var waveforms = WaveformService.shared
    @ObservedObject private var setlistStore = SetlistIntelligenceStore.shared
    @Environment(\.outputRouter) private var outputRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.macPlaybackAnimationsActive) private var animationsActive

    @State private var scrubTime: TimeInterval?
    @State private var artworkFrame: CGRect = .zero
    @State private var flight: Flight?
    @State private var pendingFlight = false
    @State private var contentVisible = false
    @State private var isClosing = false
    @State private var rootAnchor = WeakViewBox()

    private var model: MacNowPlayingModel { .shared }
    private var timeline: MacPlaybackTimeline { .shared }
    private var track: Track? { model.track }

    private struct Flight: Equatable {
        var from: CGRect
        var to: CGRect
        var atTarget: Bool
        var image: NSImage?
    }

    final class WeakViewBox {
        weak var view: NSView?
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                MacNowPlayingBackdrop(
                    artworkURL: track?.artworkURL ?? track?.user.largeAvatarURL,
                    palette: model.palette,
                    isAnimating: animationsActive && !isClosing,
                    reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency
                )
                .opacity(contentVisible ? 1 : 0)

                Color.black.opacity(0.32)
                    .opacity(contentVisible ? 1 : 0)
                    .allowsHitTesting(false)

                if let track, track.artworkURL == nil {
                    SoundingLineArt(seed: GeneratedArtworkIdentity.seed(track.id), style: .ambient, loop: .once, isActive: animationsActive && !isClosing)
                        .environment(\.colorScheme, .dark)
                        .id(track.id)
                        .opacity(contentVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }

                if let track {
                    MacNowPlayingLineArt(
                        trackID: track.id,
                        samples: waveformSamples(track),
                        scrubTime: scrubTime,
                        tint: model.palette.accent,
                        isActive: animationsActive && !isClosing
                    )
                    .opacity(contentVisible ? 1 : 0)
                }

                if let track {
                    layout(track, size: proxy.size)
                        .opacity(contentVisible ? 1 : 0)
                        .offset(y: contentVisible || reduceMotion ? 0 : 22)
                } else {
                    emptyState
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(contentVisible ? 1 : 0)
                }

                closeButton
                    .position(x: proxy.size.width - 34, y: 30)
                    .opacity(contentVisible ? 1 : 0)

                flyer
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .coordinateSpace(.named(macNowPlayingSpace))
        .background(MacViewAnchor { rootAnchor.view = $0 })
        .environment(\.colorScheme, .dark)
        .onExitCommand(perform: close)
        .onAppear(perform: open)
        .onDisappear { presentation.noteFullWindow(false) }
        .onChange(of: presentation.closeRequest) { close() }
        .task(id: track?.id) {
            guard let track else { return }
            waveforms.load(track)
            model.ensureComments()
        }
    }




    private func layout(_ track: Track, size: CGSize) -> some View {
        let leading = max(40, size.width * 0.076)
        let trailing = max(28, size.width * 0.042)
        let gap = max(36, size.width * 0.0625)
        let vertical = max(36, size.height * 0.056)
        let autoMix = MacNowPlayingAutoMixMetrics.reserved(for: AutoMixLive.shared.state, ratingPending: AutoMixFeedbackStore.shared.pending != nil)
        let deck = Self.tapeStyle.height + 64 + 14 + 46 + autoMix
        let art = max(200, min(size.width * 0.26, size.height - vertical - deck - 150, 520))
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: gap) {
                playerColumn(track, art: art)
                    .frame(width: art)
                MacNowPlayingPanes(pane: $presentation.pane, surface: .fullWindow)
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(MacNowPlayingPanelSurface(reduceTransparency: reduceTransparency))
            }
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.top, vertical)
            .frame(maxHeight: .infinity, alignment: .top)

            bottomDeck(track, leading: leading, trailing: trailing)
                .padding(.top, 22)
                .padding(.bottom, 24)
        }
        .frame(width: size.width, height: size.height)
    }

    static let tapeStyle = TapeScrubberStyle(
        waveHeight: 44, labelHeight: 20, labelGap: 8, avatarSize: 20, avatarGap: 6, timesGap: 10, timesHeight: 18,
        labelFont: .subheadline, timeFont: .callout.weight(.medium), pitch: 4, timeMinWidth: 56, markerSize: 11
    )

    private var stationSource: PlaybackQueueSource? {
        if let outputRouter, outputRouter.isRemote { return outputRouter.client.queueSource }
        return PlayerService.shared.queueSource
    }

    private func playerColumn(_ track: Track, art: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork(track, size: art)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    MacFadingText(track.title, font: .title.weight(.semibold))
                    MacFadingText(track.artistLine(), font: .title)
                        .foregroundStyle(model.palette.accent)
                    SoundCloudPreviewNowPlayingLine(trackID: track.id)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    StationNowPlayingLine(source: stationSource)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { presentation.pane = .about }
                .pointerStyle(.link)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows Behind the Track")
                .accessibilityAction { presentation.pane = .about }
                HStack(spacing: 8) {
                    ListenTogetherIndicator()
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                    MacSleepTimerBadge()
                        .padding(.trailing, 4)
                    if track.supportsSoundCloudActions {
                        MacLikeButton(track: track, style: .circle)
                    }
                    MacMoreMenu(track: track, style: .circle) { pane in
                        presentation.pane = pane
                    }
                }
                .padding(.top, 2)
            }
            .padding(.top, 26)
        }
    }

    private func bottomDeck(_ track: Track, leading: CGFloat, trailing: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let autoMix = AutoMixLive.shared.state, MacNowPlayingAutoMixMetrics.showsDecks(autoMix) {
                MacNowPlayingAutoMixDecks(state: autoMix, tint: model.palette.accent)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else {
                MacTapeScrubber(
                    track: track,
                    samples: waveformSamples(track),
                    duration: duration,
                    entries: tapeEntries,
                    comments: model.timedComments,
                    style: Self.tapeStyle,
                    bleed: TapeBleed(leading: leading, trailing: trailing),
                    tint: model.palette.accent,
                    isActive: animationsActive && !isClosing,
                    scrubTime: $scrubTime
                )
                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .transition(.opacity)
            }

            ZStack {
                transport
                    .frame(width: 300, height: 64)
                HStack(spacing: 18) {
                    Spacer(minLength: 0)
                    MacVolumeSlider(showsEndCaps: true)
                        .tint(.white.opacity(0.9))
                        .frame(width: 200)
                    if let outputRouter {
                        MacPlayOnMenu(router: outputRouter, style: .pill)
                    }
                }
                .padding(.trailing, trailing)
            }
            .padding(.top, 14)

            if let autoMix = AutoMixLive.shared.state {
                MacNowPlayingAutoMixLine(state: autoMix, tint: model.palette.accent)
                    .frame(height: MacNowPlayingAutoMixMetrics.lineHeight(for: autoMix))
                    .frame(maxWidth: MacNowPlayingAutoMixMetrics.lineWidth)
                    .padding(.top, 14)
                    .transition(.opacity)
            } else if AutoMixFeedbackStore.shared.pending != nil {
                AutoMixRatingView()
                    .controlSize(.large)
                    .frame(height: 74)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45), value: AutoMixLive.shared.state.map(MacNowPlayingAutoMixMetrics.showsDecks))
    }

    private var tapeEntries: [TapeEntry] {
        (tracklist?.entries ?? []).map { entry in
            TapeEntry.parse(
                id: entry.id,
                start: entry.startSeconds,
                title: entry.segment.title,
                artist: entry.segment.artist,
                isUnknown: MacTracklistPane.isUnknown(entry.segment)
            )
        }
    }

    private func artwork(_ track: Track, size: CGFloat) -> some View {
        let scale: CGFloat = timeline.isPlaying ? 1 : 0.86
        return ArtworkThumbnail(
            url: track.artworkURL,
            identity: track.id,
            size: size,
            cornerRadius: 14,
            crownUser: track.user,
            crownContext: track.title
        )
        .trackDragSource(track)
        .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
        .scaleEffect(scale)
        .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.25), value: scale)
        .opacity(flight == nil ? 1 : 0)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(macNowPlayingSpace)) } action: { frame in
            artworkFrame = frame
            if pendingFlight { launchFlight() }
        }
        .overlay(alignment: .bottomLeading) { routeBadge }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var routeBadge: some View {
        if let outputRouter {
            MacRouteBadge(router: outputRouter)
                .padding(14)
        }
    }

    static func entryLabel(_ segment: SetlistSegment) -> String {
        if MacTracklistPane.isUnknown(segment) { return "ID — Unidentified" }
        guard let artist = segment.artist, !artist.isEmpty else { return segment.title }
        return "\(artist) — \(segment.title)"
    }

    private var transport: some View {
        HStack {
            Button {
                MacPlayback.previous()
            } label: {
                Label("Previous", systemImage: "backward.fill")
                    .font(.system(.title, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button {
                timeline.togglePlayPause()
            } label: {
                Label(timeline.isPlaying ? "Pause" : "Play", systemImage: timeline.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(.largeTitle, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button {
                MacPlayback.next()
            } label: {
                Label("Next", systemImage: "forward.fill")
                    .font(.system(.title, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MacPressableButtonStyle(reduceMotion: reduceMotion))
        .foregroundStyle(.primary)
    }

    private var closeButton: some View {
        Button(action: close) {
            Label("Exit Full Window", systemImage: "arrow.down.right.and.arrow.up.left")
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(MacSecondaryStyle())
        .keyboardShortcut(.cancelAction)
        .help("Exit Full Window (Esc)")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing Playing", systemImage: "music.note")
        } description: {
            Text("Choose a track to start listening.")
        } actions: {
            Button("Done", action: close)
        }
    }


    private var duration: TimeInterval {
        let anchorDuration = timeline.anchor.duration
        return anchorDuration > 0 ? anchorDuration : (track?.duration ?? 0)
    }

    private var tracklist: Tracklist? {
        guard let id = track?.id else { return nil }
        let list = setlistStore.tracklist(for: id)
        return list?.isEmpty == false ? list : nil
    }

    private func waveformSamples(_ track: Track) -> [Float] {
        if case .ready(let waveform) = waveforms.state(for: track.id), !waveform.isEmpty {
            return SCWaveformSampler.visuallyNormalized(waveform.samples, floor: 0.12)
        }
        #if DEBUG
        if VisualFixtures.isEnabled { return MacNowPlayingFixtures.waveform(for: track) }
        #endif
        return []
    }

    private var waveformMarks: [Double] {
        guard duration > 0 else { return [] }
        switch presentation.pane {
        case .tracklist:
            return (tracklist?.entries ?? []).dropFirst().map { $0.startSeconds / duration }
        case .comments:
            return model.timedComments.compactMap { $0.timeInTrack.map { $0 / duration } }
        default:
            return []
        }
    }


    @ViewBuilder
    private var flyer: some View {
        if let flight, let image = flightImage {
            let rect = flight.atTarget ? flight.to : flight.from
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: flight.atTarget ? 14 : 6, style: .continuous))
                .shadow(color: .black.opacity(flight.atTarget ? 0.45 : 0), radius: 30, y: 18)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    private var playingArtworkRect: CGRect {
        let scale: CGFloat = timeline.isPlaying ? 1 : 0.86
        return artworkFrame.insetBy(
            dx: artworkFrame.width * (1 - scale) / 2,
            dy: artworkFrame.height * (1 - scale) / 2
        )
    }

    private func localSource() -> CGRect? {
        guard let source = presentation.morphSource else { return nil }
        let origin = MacViewAnchor.windowRect(of: rootAnchor.view)?.origin ?? .zero
        return source.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private var flightImage: NSImage? {
        flight?.image ?? model.artwork
    }

    private func open() {
        presentation.noteFullWindow(true)
        if !reduceMotion, presentation.morphSource != nil, presentation.morphImage ?? model.artwork != nil {
            pendingFlight = true
            if artworkFrame != .zero { launchFlight() }
        }
        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.35)) { contentVisible = true }
    }

    private func launchFlight() {
        pendingFlight = false
        guard let source = localSource(), artworkFrame.width > 1 else { return }
        flight = Flight(from: source, to: playingArtworkRect, atTarget: false, image: presentation.morphImage)
        Task { @MainActor in
            await Task.yield()
            withAnimation(.spring(duration: 0.6, bounce: 0.12)) { flight?.atTarget = true }
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.16)) { flight = nil }
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        presentation.noteFullWindow(false)
        guard !reduceMotion, model.artwork != nil, artworkFrame.width > 1, let source = localSource() else {
            onClose()
            return
        }
        flight = Flight(from: source, to: playingArtworkRect, atTarget: true, image: nil)
        onWillClose()
        Task { @MainActor in
            await Task.yield()
            withAnimation(.spring(duration: 0.5, bounce: 0.08)) { flight?.atTarget = false }
            withAnimation(.easeOut(duration: 0.32)) { contentVisible = false }
            try? await Task.sleep(for: .milliseconds(520))
            onClose()
        }
    }
}

private struct MacNowPlayingPanelSurface: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        if reduceTransparency {
            content.background(Color(white: 0.12), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

struct MacPressableButtonStyle: ButtonStyle {
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
    }
}

struct MacFadingText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
            .mask {
                if textWidth > boxWidth + 0.5 {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Rectangle()
                }
            }
            .help(textWidth > boxWidth + 0.5 ? text : "")
    }
}

private struct MacRouteBadge: View {
    @ObservedObject var router: OutputRouter

    var body: some View {
        if router.isRemote {
            Label(router.current.name, systemImage: router.current.symbolName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .glassEffect(.regular, in: Capsule())
                .transition(.opacity)
        }
    }
}

func macFormatTime(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    guard hours > 0 else { return String(format: "%d:%02d", minutes, secs) }
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
}

func macFormatRemaining(current: TimeInterval, duration: TimeInterval) -> String {
    "−" + macFormatTime(max(0, duration.rounded(.down) - current.rounded(.down)))
}

@MainActor
final class MacTrackEngagement: ObservableObject {
    static let shared = MacTrackEngagement()

    @Published private(set) var likedOverrides: [String: Bool] = [:]
    @Published private(set) var pendingTrackIds: Set<String> = []

    private var locallyMutatedTrackIds: Set<String> = []
    private var knownTrackFavorites: [String: Bool] = [:]
    private var revisionCancellable: AnyCancellable?

    private init() {
        revisionCancellable = LikesSyncEngine.shared.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshKnownTracks()
                }
            }
    }

    func isLiked(_ track: Track) -> Bool {
        ensureTracked(track)
        return likedOverrides[track.id] ?? track.userFavorite
    }

    func isPending(_ track: Track) -> Bool {
        pendingTrackIds.contains(track.id)
    }

    func refreshLikeState(_ track: Track) async {
        knownTrackFavorites[track.id] = track.userFavorite
        guard !locallyMutatedTrackIds.contains(track.id) else { return }
        let indexed = await LibraryCache.shared.containsLike(id: track.id)
        guard !locallyMutatedTrackIds.contains(track.id) else { return }
        likedOverrides[track.id] = track.userFavorite || indexed
    }

    private func ensureTracked(_ track: Track) {
        guard knownTrackFavorites[track.id] == nil else { return }
        knownTrackFavorites[track.id] = track.userFavorite
        Task { await refreshLikeState(track) }
    }

    private func refreshKnownTracks() async {
        for (trackId, userFavorite) in knownTrackFavorites where !locallyMutatedTrackIds.contains(trackId) {
            let indexed = await LibraryCache.shared.containsLike(id: trackId)
            guard !locallyMutatedTrackIds.contains(trackId) else { continue }
            likedOverrides[trackId] = userFavorite || indexed
        }
    }

    func toggleLike(_ track: Track) async {
        guard !pendingTrackIds.contains(track.id) else { return }
        let previous = isLiked(track)
        let next = !previous
        locallyMutatedTrackIds.insert(track.id)
        likedOverrides[track.id] = next
        pendingTrackIds.insert(track.id)
        defer { pendingTrackIds.remove(track.id) }

        do {
            try await LikeRequest.send(next, track: track)
        } catch {
            likedOverrides[track.id] = previous
            locallyMutatedTrackIds.remove(track.id)
        }
    }
}

#if DEBUG
enum MacNowPlayingFixtures {
    static func comments(for track: Track) -> [Comment] {
        let lines = [
            "that first synth note", "chorus hits so hard", "the glockenspiel!!", "this was playing when I met my partner",
            "bridge is pure sunlight", "been hunting this edit for months", "that filter sweep is so clean",
            "was front left for this one, unreal", "a lesson in patience", "the strings here", "never misses on the long build",
            "ID anyone?", "sounds like unreleased material", "this is my whole Sunday sorted", "the breakdown here… goosebumps",
            "perfect blend", "turned it up in the car", "the bassline 🔥", "goosebumps every time", "best transition of the set",
        ]
        let users = VisualFixtures.artists
        let span = max(60, track.duration)
        let count = min(lines.count, max(8, Int(span / 150)))
        let encoder = JSONEncoder()
        return (0..<count).compactMap { index -> Comment? in
            let user = users[index % users.count]
            guard let userData = try? encoder.encode(user),
                  let userJSON = String(data: userData, encoding: .utf8) else { return nil }
            let millis = Int((Double(index) + 0.4) / Double(count) * span * 1000)
            let body = lines[index % lines.count]
            let json = "{\"id\": \(9000 + index), \"body\": \"\(body)\", \"timestamp\": \(millis), \"user\": \(userJSON)}"
            return try? JSONDecoder().decode(Comment.self, from: Data(json.utf8))
        }
    }

    static func waveform(for track: Track) -> [Float] {
        if VisualFixtures.longSetEnabled, track.id == VisualFixtures.longSet.id { return VisualFixtures.longSetWaveform() }
        var seed = UInt64(abs(track.id.hashValue) % 10_000 + 7)
        var out = [Float]()
        out.reserveCapacity(600)
        var level: Float = 0.5
        for index in 0..<600 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(seed >> 40) / Float(1 << 24)
            level = level * 0.7 + noise * 0.3
            let phrase = 0.75 + 0.25 * sin(Float(index) / 600 * .pi * 9)
            out.append(max(0.12, min(1, level * phrase * 1.25)))
        }
        return out
    }
}
#endif

private let macNowPlayingSpace = "macNowPlaying"

private struct MacNowPlayingLineArt: View {
    let trackID: String
    let samples: [Float]
    let scrubTime: TimeInterval?
    let tint: Color
    let isActive: Bool

    var body: some View {
        let anchor = MacPlaybackTimeline.shared.anchor
        SoundingReactiveLineArt(
            trackID: trackID,
            samples: samples,
            duration: anchor.duration,
            playhead: SoundingLineArtPlayhead(position: anchor.position, date: anchor.date, rate: anchor.rate, duration: anchor.duration),
            scrub: scrubTime,
            tint: tint,
            intensity: 0.38,
            bandPosition: 0.035,
            tipAnchor: UnitPoint(x: 0.2, y: 0.72),
            wideTipAnchor: UnitPoint(x: 0.36, y: 0.96),
            isActive: isActive
        )
    }
}

struct MacTapeScrubber: View {
    let track: Track
    let samples: [Float]
    let duration: TimeInterval
    let entries: [TapeEntry]
    let comments: [Comment]
    let style: TapeScrubberStyle
    let bleed: TapeBleed
    let tint: Color
    let isActive: Bool
    @Binding var scrubTime: TimeInterval?

    @State private var peaks: TapeWaveformPeaks?
    @State private var tapeComments: [TapeComment] = []

    private var timeline: MacPlaybackTimeline { .shared }

    private struct PeaksKey: Equatable {
        let trackID: String
        let count: Int
        let duration: TimeInterval
    }

    var body: some View {
        let anchor = timeline.anchor
        let shot = Self.debugShot
        TapeScrubber(
            clock: TapeClock(position: anchor.position, date: anchor.date, rate: anchor.rate, duration: anchor.duration > 0 ? anchor.duration : duration),
            isActive: isActive,
            peaks: peaks,
            trim: TrackTrimTimeline(trackID: track.id, duration: duration),
            entries: entries,
            comments: tapeComments,
            style: style,
            bleed: bleed,
            initialSpan: duration < 360 ? duration : 240,
            bubbleTint: tint,
            startsScrubbing: shot == "scrub",
            showsBubbleOnAppear: shot == "bubble",
            onSeek: { timeline.seek(to: $0) },
            onScrubChange: { scrubTime = $0 }
        ) { comment, size in
            MacAvatar(url: comment.avatarURL, name: comment.name, size: size)
        }
        .id(track.id)
        .task(id: PeaksKey(trackID: track.id, count: samples.count, duration: duration)) {
            let samples = samples
            let duration = duration
            let built = await Task.detached(priority: .userInitiated) {
                TapeWaveformPeaks.build(samples: samples, duration: duration)
            }.value
            guard !Task.isCancelled else { return }
            peaks = built
        }
        .task(id: comments.count) {
            tapeComments = comments
                .compactMap { comment in
                    comment.timeInTrack.map {
                        TapeComment(id: comment.id, time: $0, body: comment.body, avatarURL: comment.user.avatarURL, name: comment.user.id)
                    }
                }
                .sorted { $0.time < $1.time }
        }
    }

    private static var debugShot: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_TAPE_SHOT"]
        #else
        nil
        #endif
    }
}
