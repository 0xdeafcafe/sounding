import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Starting a collection

@MainActor
enum CollectionPlayback {
    typealias Sink = @MainActor (_ start: Track, _ queue: [Track]) async -> Void

    private static var hydration: Task<Void, Never>?
    private static let hydrationSpacing: Duration = .milliseconds(400)
    private static let maximumHydrationBatches = 10

    static func isPlayable(_ track: Track) -> Bool {
        track.isLocal || track.streamURL != nil || DownloadManager.shared.isLocallyAvailable(track)
    }

    static func start(
        playlist: Playlist,
        loaded supplied: [Track]? = nil,
        alsoKnownIDs: [String] = [],
        shuffle: Bool = false,
        sink: Sink
    ) async {
        hydration?.cancel()
        hydration = nil
        var playlist = playlist
        var loaded = supplied ?? playlist.loadedTracks
        if supplied == nil, loaded.count < playlist.totalTrackCount,
           let stored = await LibraryDB.playlistTracks(id: playlist.id), stored.count > loaded.count {
            loaded = stored
        }
        if loaded.isEmpty {
            loaded = DownloadManager.shared.cachedTracks(forCollectionId: playlist.id)
        }
        var plan = makePlan(playlist: playlist, loaded: loaded, shuffle: shuffle)
        if case .afterCollectionLookup = plan.start {
            guard let full = try? await SoundCloudAPI.shared.getPlaylist(id: playlist.id) else { return }
            playlist = full
            loaded = full.loadedTracks
            plan = makePlan(playlist: playlist, loaded: loaded, shuffle: shuffle)
        }
        if case .afterFirstPage(let ids) = plan.start {
            let page = (try? await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: ids)) ?? []
            loaded = merge(loaded, page)
            plan = makePlan(playlist: playlist, loaded: loaded, shuffle: shuffle)
            if case .afterFirstPage = plan.start { return }
        }
        guard case .now(let startID) = plan.start else { return }
        let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let queue = plan.initialQueueIDs.compactMap { byID[$0] }
        guard let first = byID[startID] else { return }
        if shuffle { PlayerService.shared.isShuffleEnabled = true }
        await sink(first, queue)
        let known = Set(alsoKnownIDs).union(loaded.map(\.id))
        hydrate(
            playlist: playlist,
            ids: plan.hydrateAfterStartIDs.filter { !known.contains($0) },
            known: known,
            needsLookup: playlist.trackIDs == nil && loaded.count < playlist.trackCount
        )
    }

    static func makePlan(playlist: Playlist, loaded: [Track], shuffle: Bool) -> CollectionStartPlan {
        let playable = Set(loaded.filter(isPlayable).map(\.id))
        let preferred = shuffle ? playable.randomElement() : nil
        return CollectionStartPlanner.plan(
            orderedIDs: playlist.trackIDs ?? [],
            loadedIDs: loaded.map(\.id),
            playableIDs: playable,
            preferredStartID: preferred
        )
    }

    private static func merge(_ loaded: [Track], _ page: [Track]) -> [Track] {
        var seen = Set(loaded.map(\.id))
        return loaded + page.filter { seen.insert($0.id).inserted }
    }

    private static func hydrate(playlist: Playlist, ids: [String], known: Set<String>, needsLookup: Bool) {
        guard !ids.isEmpty || needsLookup else { return }
        let player = PlayerService.shared
        let request = player.currentPlayRequest
        hydration = Task { @MainActor in
            for _ in 0..<30 where !player.isPlaying {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            var playlist = playlist
            var ids = ids
            if needsLookup {
                guard player.currentPlayRequest == request,
                      player.activeCollectionId == playlist.id,
                      let full = try? await SoundCloudAPI.shared.getPlaylist(id: playlist.id) else { return }
                playlist = full
                let fetched = full.loadedTracks.filter { !known.contains($0.id) }
                player.appendCollectionTracks(fetched.filter(isPlayable), collectionId: full.id, playRequest: request)
                let seen = known.union(fetched.map(\.id))
                ids = (full.trackIDs ?? []).filter { !seen.contains($0) }
            }
            let batches = Array(CollectionStartPlanner.batches(ids).prefix(maximumHydrationBatches))
            for batch in batches {
                guard !Task.isCancelled,
                      player.currentPlayRequest == request,
                      player.activeCollectionId == playlist.id else { return }
                guard let tracks = try? await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: batch) else { return }
                player.appendCollectionTracks(tracks.filter(isPlayable), collectionId: playlist.id, playRequest: request)
                do { try await Task.sleep(for: hydrationSpacing) } catch { return }
            }
        }
    }

    static func prewarm(playlist: Playlist, immediate: Bool = false) {
        guard let first = playlist.loadedTracks.first(where: { $0.streamURL != nil }) else { return }
        PlayerService.shared.preparePlayback(for: first, immediate: immediate)
    }

    static func prewarm(_ tracks: [Track], immediate: Bool = false) {
        guard let first = tracks.first(where: { $0.streamURL != nil }) else { return }
        PlayerService.shared.preparePlayback(for: first, immediate: immediate)
    }
}

// MARK: - Revealing Now Playing

@MainActor
final class NowPlayingReveal: ObservableObject {
    static let shared = NowPlayingReveal()

    @Published private(set) var request: UInt64 = 0
    @Published private(set) var startingID: String?
    private(set) var sourceID: String?
    private var startingTimeout: Task<Void, Never>?
    private var revealWait: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let player = PlayerService.shared
        player.$isPlaying
            .combineLatest(player.$playbackErrorMessage)
            .sink { [weak self] isPlaying, error in
                guard isPlaying || error != nil else { return }
                self?.finishStarting()
            }
            .store(in: &cancellables)
    }

    static func collectionSourceID(_ id: String) -> String { "nowPlaying.cover.\(id)" }

    func reveal(from sourceID: String?) {
        self.sourceID = sourceID
        Task { @MainActor in
            await Task.yield()
            self.request &+= 1
        }
    }

    func revealWhenStarted(from sourceID: String?) {
        let before = PlayerService.shared.currentPlayRequest
        revealWait?.cancel()
        revealWait = Task { @MainActor [weak self] in
            for _ in 0..<80 {
                if PlayerService.shared.currentPlayRequest != before {
                    self?.reveal(from: sourceID)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    func beginStarting(_ id: String) {
        startingID = id
        feedback()
        startingTimeout?.cancel()
        startingTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finishStarting()
        }
    }

    func finishStarting() {
        startingTimeout?.cancel()
        startingTimeout = nil
        if startingID != nil { startingID = nil }
    }

    func consumeSource() -> String? {
        defer { sourceID = nil }
        return sourceID
    }

    private func feedback() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

// MARK: - Collection play state

enum CollectionPlayGlyph: Equatable {
    case play
    case starting
    case pause
}

@MainActor
@Observable
final class CollectionPlaybackStatus {
    static let shared = CollectionPlaybackStatus()

    private(set) var activeCollectionID: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var startingID: String?

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private init(player: PlayerService = .shared, reveal: NowPlayingReveal = .shared) {
        player.$activeCollectionId.removeDuplicates().sink { [weak self] in self?.activeCollectionID = $0 }.store(in: &cancellables)
        player.$isPlaying.removeDuplicates().sink { [weak self] in self?.isPlaying = $0 }.store(in: &cancellables)
        player.$isLoading.removeDuplicates().sink { [weak self] in self?.isLoading = $0 }.store(in: &cancellables)
        reveal.$startingID.removeDuplicates().sink { [weak self] in self?.startingID = $0 }.store(in: &cancellables)
    }

    func glyph(for collectionID: String?) -> CollectionPlayGlyph {
        guard let collectionID else { return .play }
        if startingID == collectionID { return .starting }
        guard activeCollectionID == collectionID, PlayerService.shared.currentTrack != nil else { return .play }
        if isLoading { return .starting }
        return isPlaying ? .pause : .play
    }
}

// MARK: - Intent prewarming

extension View {
    func prewarmsPlayback(_ prewarm: ((_ immediate: Bool) -> Void)?) -> some View {
        modifier(PlaybackPrewarmOnIntent(prewarm: prewarm))
    }
}

private struct PlaybackPrewarmOnIntent: ViewModifier {
    let prewarm: ((_ immediate: Bool) -> Void)?

    func body(content: Content) -> some View {
        if let prewarm {
            #if os(iOS)
            content
                .onHover { if $0 { prewarm(false) } }
                .gesture(TouchDownRecognizer { prewarm(true) })
            #elseif os(macOS)
            content.onHover { if $0 { prewarm(false) } }
            #else
            content
            #endif
        } else {
            content
        }
    }
}

#if os(iOS)
private struct TouchDownRecognizer: UIGestureRecognizerRepresentable {
    let action: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began { action() }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

// MARK: - Zoom source

extension EnvironmentValues {
    @Entry var nowPlayingZoomNamespace: Namespace.ID? = nil
}

extension View {
    func nowPlayingZoomSource(id: String) -> some View {
        modifier(NowPlayingZoomSource(id: id))
    }
}

private struct NowPlayingZoomSource: ViewModifier {
    let id: String
    @Environment(\.nowPlayingZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
