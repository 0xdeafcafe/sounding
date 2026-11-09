import CarPlay
import Combine
import Observation
import UIKit

typealias CarPlayTrackContext = @MainActor () async -> [Track]

enum CarPlayEntry {
    case track(Track, context: [Track], collectionId: String?)
    case playlist(Playlist)
    case station(SystemPlaylist)

    var id: String {
        switch self {
        case .track(let track, _, _): return "track:\(track.id)"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        case .station(let station): return "station:\(station.id)"
        }
    }

    var title: String {
        switch self {
        case .track(let track, _, _): return track.title
        case .playlist(let playlist): return playlist.title
        case .station(let station): return DiscoveryEntry.station(station).cardTitle
        }
    }

    var subtitle: String? {
        switch self {
        case .track(let track, _, _): return track.user.displayName
        case .playlist(let playlist): return playlist.user.displayName
        case .station: return "Station"
        }
    }

    var artworkURL: URL? {
        switch self {
        case .track(let track, _, _): return track.artworkURL
        case .playlist(let playlist): return playlist.displayArtworkURL
        case .station(let station): return station.artworkURL
        }
    }

    var symbol: String {
        switch self {
        case .track: return "music.note"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        }
    }
}

@MainActor
final class CarPlayController: NSObject {
    static let maximumDepth = 5
    static let imageRowLimit = 8

    let interfaceController: CPInterfaceController
    let coordinator: PhonePlaybackCoordinator
    let artwork = CarPlayArtwork()
    let likes = NowPlayingLikeModel.shared
    let nowPlayingTemplate = CPNowPlayingTemplate.shared

    var cancellables = Set<AnyCancellable>()
    let playableItems = NSHashTable<CPListItem>.weakObjects()
    var listenNowTemplate: CPListTemplate?
    var libraryTemplate: CPListTemplate?
    var stationsTemplate: CPListTemplate?
    var searchTemplate: CPListTemplate?
    weak var upNextTemplate: CPListTemplate?
    var upNextRevision: [String]?
    var listenNowRevision: [String]?
    var stationsRevision: [String]?
    var nowPlayingState: CarPlayNowPlayingState?
    var startStationItem: CPListItem?
    var isListenNowHydrated = false
    var isSignedIn = false
    var hasYourMusic = false
    var didShowSignInAlert = false
    var isRunning = false
    var isObservingLikes = false
    var playTask: Task<Void, Never>?

    init(interfaceController: CPInterfaceController, coordinator: PhonePlaybackCoordinator) {
        self.interfaceController = interfaceController
        self.coordinator = coordinator
        super.init()
    }

    func start() {
        isRunning = true
        artwork.displayScale = max(1, interfaceController.carTraitCollection.displayScale)
        isSignedIn = ListeningCatalog.isSignedIn
        hasYourMusic = ListeningCatalog.hasYourMusic
        configureNowPlaying()
        buildRoot()
        observe()
        observeLikes()
        NowPlayingFeedbackCommands.shared.enable(
            subject: { [weak self] in self?.feedbackSubject },
            skip: { [weak self] in self?.coordinator.next() }
        )
        Task { [weak self] in
            await HomeStore.shared.forYou.hydrateCachedContent()
            guard let self, self.isRunning else { return }
            self.isListenNowHydrated = true
            self.listenNowRevision = nil
            self.stationsRevision = nil
            self.refreshListenNow()
            self.refreshStations()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cancellables.removeAll()
        playTask?.cancel()
        playTask = nil
        nowPlayingTemplate.remove(self)
        NowPlayingFeedbackCommands.shared.disable()
    }

    private func observe() {
        coordinator.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.playbackChanged() }
            .store(in: &cancellables)

        Publishers.Merge3(
            HomeStore.shared.forYou.$shelves.map { _ in () },
            RecentlyPlayed.shared.$items.map { _ in () },
            ContinueFrom.shared.$offer.map { _ in () }
        )
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshListenNow()
            self?.refreshStations()
        }
        .store(in: &cancellables)

        SoundCloudCredentialSource.shared.objectWillChange
            .merge(with: LocalMusicLibrary.shared.objectWillChange)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.accountChanged() }
            .store(in: &cancellables)
    }

    private func observeLikes() {
        guard !isObservingLikes, isRunning else { return }
        isObservingLikes = true
        withObservationTracking {
            _ = likes.liked
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingLikes = false
                guard self.isRunning else { return }
                self.refreshNowPlaying()
                self.observeLikes()
            }
        }
    }

    private func playbackChanged() {
        guard isRunning else { return }
        refreshPlayingIndicators()
        refreshNowPlaying()
        refreshUpNext()
        refreshStartStation()
        refreshListenNow()
        NowPlayingFeedbackCommands.shared.refresh()
    }

    private func accountChanged() {
        guard isRunning else { return }
        let signedIn = ListeningCatalog.isSignedIn
        let yours = ListeningCatalog.hasYourMusic
        guard signedIn != isSignedIn || yours != hasYourMusic else { return }
        let rebuildsRoot = signedIn != isSignedIn || !signedIn
        isSignedIn = signedIn
        hasYourMusic = yours
        if rebuildsRoot {
            buildRoot()
        } else {
            refreshLibrary()
        }
        nowPlayingState = nil
        refreshNowPlaying()
        NowPlayingFeedbackCommands.shared.refresh()
    }

    private func buildRoot() {
        playableItems.removeAllObjects()
        listenNowTemplate = nil
        libraryTemplate = nil
        stationsTemplate = nil
        searchTemplate = nil
        startStationItem = nil
        listenNowRevision = nil
        stationsRevision = nil
        let root: CPTemplate
        if isSignedIn {
            let tabs: [CPTemplate] = [makeListenNow(), makeLibrary(), makeStations(), makeSearch()]
            root = CPTabBarTemplate(templates: Array(tabs.prefix(max(1, CPTabBarTemplate.maximumTabCount))))
        } else if hasYourMusic {
            root = CPTabBarTemplate(templates: [makeLibrary(), makeSearch()])
        } else {
            let list = CPListTemplate(title: "Sounding", sections: [])
            list.emptyViewTitleVariants = ["Sign In on Your iPhone"]
            list.emptyViewSubtitleVariants = ["Open Sounding on your iPhone and sign in to SoundCloud."]
            root = list
        }
        interfaceController.setRootTemplate(root, animated: false) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSignedIn, self.hasYourMusic else { return }
                self.showSignInAlert()
            }
        }
    }

    private func showSignInAlert() {
        guard !didShowSignInAlert else { return }
        didShowSignInAlert = true
        showAlert(["Sign in to SoundCloud on your iPhone", "Sign In on Your iPhone"])
    }

    func push(_ template: CPTemplate) {
        guard isRunning else { return }
        if interfaceController.templates.count >= Self.maximumDepth {
            interfaceController.popToRootTemplate(animated: false) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.interfaceController.pushTemplate(template, animated: true, completion: nil)
                }
            }
        } else {
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        }
    }

    func showNowPlaying() {
        guard isRunning else { return }
        let template = nowPlayingTemplate
        if interfaceController.topTemplate === template { return }
        if interfaceController.templates.contains(where: { $0 === template }) {
            interfaceController.pop(to: template, animated: true, completion: nil)
        } else {
            push(template)
        }
    }

    func showAlert(_ titles: [String]) {
        guard isRunning, interfaceController.presentedTemplate == nil, !titles.isEmpty else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: titles, actions: [ok]), animated: true, completion: nil)
    }

    func showFailure(_ message: String?) {
        showAlert([message, "Can’t Play That"].compactMap { $0 })
    }

    func play(_ track: Track, context: @escaping CarPlayTrackContext, collectionId: String? = nil) {
        showNowPlaying()
        playTask?.cancel()
        playTask = Task { [weak self] in
            let tracks = await context()
            guard let self, !Task.isCancelled else { return }
            let queue = tracks.contains { $0.id == track.id } ? tracks : [track]
            if let failure = await self.coordinator.play(track, in: queue, collectionId: collectionId) {
                self.showFailure(failure)
            }
        }
    }

    func playShuffled(_ context: @escaping CarPlayTrackContext, collectionId: String? = nil) {
        showNowPlaying()
        playTask?.cancel()
        playTask = Task { [weak self] in
            let tracks = await context()
            guard let self, !Task.isCancelled else { return }
            guard !tracks.isEmpty else {
                self.showFailure(nil)
                return
            }
            if let failure = await self.coordinator.play(shuffled: tracks, collectionId: collectionId) {
                self.showFailure(failure)
            }
        }
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        showNowPlaying()
        playTask?.cancel()
        playTask = Task { [weak self] in
            do {
                try await action()
            } catch {
                guard let self, !Task.isCancelled else { return }
                if let intentError = error as? PlaybackIntentError {
                    self.showFailure(String(localized: intentError.localizedStringResource))
                } else {
                    self.showFailure(nil)
                }
            }
        }
    }

    func select(_ entry: CarPlayEntry) {
        switch entry {
        case .track(let track, let context, let collectionId):
            play(track, context: { context }, collectionId: collectionId)
        case .playlist(let playlist):
            pushPlaylist(playlist)
        case .station(let station):
            openStation(station)
        }
    }

    var currentTrackID: String? { coordinator.nowPlaying?.trackId }

    func trackItem(
        _ track: Track,
        context: @escaping CarPlayTrackContext,
        collectionId: String? = nil,
        loadsArtwork: Bool = true
    ) -> CPListItem {
        let item = CPListItem(text: track.title, detailText: track.user.displayName)
        item.userInfo = track.id
        item.playingIndicatorLocation = .trailing
        item.isPlaying = track.id == currentTrackID
        playableItems.add(item)
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated {
                self?.play(track, context: context, collectionId: collectionId)
            }
            completion()
        }
        loadArtwork(into: item, url: loadsArtwork ? track.artworkURL : nil, symbol: "music.note", loads: loadsArtwork)
        return item
    }

    func trackItems(_ tracks: [Track], startingAt offset: Int = 0, context: @escaping CarPlayTrackContext, collectionId: String? = nil) -> [CPListItem] {
        tracks.enumerated().map { index, track in
            trackItem(track, context: context, collectionId: collectionId, loadsArtwork: offset + index < CarPlayArtwork.perListLimit)
        }
    }

    func entryItem(_ entry: CarPlayEntry, loadsArtwork: Bool = true) -> CPListItem {
        switch entry {
        case .track(let track, let context, let collectionId):
            return trackItem(track, context: { context }, collectionId: collectionId, loadsArtwork: loadsArtwork)
        case .playlist(let playlist):
            return playlistItem(playlist, loadsArtwork: loadsArtwork)
        case .station(let station):
            return stationItem(station, loadsArtwork: loadsArtwork)
        }
    }

    func playlistItem(_ playlist: Playlist, loadsArtwork: Bool = true) -> CPListItem {
        let item = CPListItem(text: playlist.title, detailText: playlist.user.displayName)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated { self?.pushPlaylist(playlist) }
            completion()
        }
        loadArtwork(into: item, url: playlist.displayArtworkURL, symbol: "music.note.list", loads: loadsArtwork)
        return item
    }

    func stationItem(_ station: SystemPlaylist, loadsArtwork: Bool = true) -> CPListItem {
        let item = CPListItem(text: DiscoveryEntry.station(station).cardTitle, detailText: "Station")
        if station.stationKind == .other { item.accessoryType = .disclosureIndicator }
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated { self?.openStation(station) }
            completion()
        }
        loadArtwork(into: item, url: station.artworkURL, symbol: "dot.radiowaves.left.and.right", loads: loadsArtwork)
        return item
    }

    func collectionItem(_ grid: LibraryGridItem, loadsArtwork: Bool = true) -> CPListItem {
        let item = CPListItem(text: grid.title, detailText: grid.subtitle.isEmpty ? nil : grid.subtitle)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated {
                switch grid.route {
                case .playlist(let playlist): self?.pushPlaylist(playlist)
                case .local(let collection): self?.pushLocalCollection(collection)
                }
            }
            completion()
        }
        let symbol = grid.isCircular ? "music.microphone" : "square.stack"
        loadArtwork(into: item, url: grid.artworkURL, round: grid.isCircular, symbol: symbol, loads: loadsArtwork)
        return item
    }

    func navigationItem(_ title: String, symbol: String, detail: String? = nil, action: @escaping @MainActor () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: CarPlaySymbol.image(symbol))
        item.accessoryType = .disclosureIndicator
        item.handler = { _, completion in
            MainActor.assumeIsolated { action() }
            completion()
        }
        return item
    }

    func actionItem(_ title: String, symbol: String, detail: String? = nil, action: @escaping @MainActor () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: CarPlaySymbol.image(symbol))
        item.handler = { _, completion in
            MainActor.assumeIsolated { action() }
            completion()
        }
        return item
    }

    func loadArtwork(into item: CPListItem, url: URL?, round: Bool = false, symbol: String, loads: Bool = true) {
        let size = CPListItem.maximumImageSize
        guard loads, let url else {
            item.setImage(artwork.placeholder(symbol: symbol, size: size))
            return
        }
        if let cached = artwork.cachedImage(for: url, size: size, round: round) {
            item.setImage(cached)
            return
        }
        Task { [weak self, weak item] in
            guard let image = await self?.artwork.image(for: url, size: size, round: round) else {
                guard let self, let item, item.image == nil else { return }
                item.setImage(self.artwork.placeholder(symbol: symbol, size: size))
                return
            }
            item?.setImage(image)
        }
    }

    func refreshPlayingIndicators() {
        let id = currentTrackID
        for item in playableItems.allObjects {
            let playing = id != nil && (item.userInfo as? String) == id
            if item.isPlaying != playing { item.isPlaying = playing }
        }
    }

    var feedbackSubject: NowPlayingFeedbackSubject? {
        guard let snapshot = coordinator.nowPlaying, let id = snapshot.trackId else { return nil }
        return NowPlayingFeedbackSubject(trackID: id, track: coordinator.currentTrack, canLike: canLike(snapshot))
    }

    func canLike(_ snapshot: NowPlayingSnapshot) -> Bool {
        isSignedIn && snapshot.trackId != nil && !snapshot.isDeviceTrack
    }
}
