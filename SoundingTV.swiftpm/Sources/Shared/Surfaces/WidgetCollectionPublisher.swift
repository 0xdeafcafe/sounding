import Combine
import Foundation
import WidgetKit

@MainActor
final class WidgetCollectionPublisher {
    static let shared = WidgetCollectionPublisher()

    private static let debounce: Duration = .seconds(3)
    private static let playlistLimit = 12
    private static let setlistLimit = 6
    private static let stationLimit = 6

    private var cancellables = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?
    private var published: [WidgetCollection]

    private init() {
        published = WidgetCollectionStore.load()
    }

    func start() {
        guard cancellables.isEmpty else { return }
        let stations = StationsModel.shared
        let engine = LibrarySyncEngine.shared
        let triggers: [AnyPublisher<Void, Never>] = [
            stations.$yourStation.map { _ in }.eraseToAnyPublisher(),
            stations.$recents.map { _ in }.eraseToAnyPublisher(),
            stations.$liked.map { _ in }.eraseToAnyPublisher(),
            SetlistIntelligenceStore.shared.$setlists.map { _ in }.eraseToAnyPublisher(),
            engine.$revision
                .filter { _ in !engine.lastChanged.isDisjoint(with: Set(LibraryCollection.playlistLists)) }
                .map { _ in }
                .eraseToAnyPublisher(),
            SoundCloudCredentialSource.shared.$state.map { _ in }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] in self?.schedule() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .sink { [weak self] _ in self?.clear() }
            .store(in: &cancellables)
    }

    func clear() {
        pending?.cancel()
        pending = nil
        published = []
        WidgetCollectionStore.remove()
        WidgetArtworkWriter.shared.sync(SoundingSnapshotPublisher.shared.current) { [weak self] in
            self?.reloadWidgets()
        }
        reloadWidgets()
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            await self.refresh()
        }
    }

    private func refresh() async {
        let local = DeviceLocalCatalog()
        var collections: [WidgetCollection] = []

        if await local.likesCount() > 0 {
            collections.append(WidgetCollection(
                kind: .playlist,
                itemID: MediaTarget.likesID,
                title: "Likes",
                subtitle: "",
                symbol: "heart.fill"
            ))
        }
        for playlist in await local.cachedPlaylists().prefix(Self.playlistLimit) {
            let count = playlist.totalTrackCount
            collections.append(WidgetCollection(
                kind: .playlist,
                itemID: playlist.id,
                title: playlist.title,
                subtitle: count > 0 ? "\(playlist.user.displayName) · \(count) tracks" : playlist.user.displayName,
                artworkURL: playlist.largeDisplayArtworkURL ?? playlist.displayArtworkURL
            ))
        }
        for setlist in await local.savedSetlists().prefix(Self.setlistLimit) {
            collections.append(WidgetCollection(
                kind: .setlist,
                itemID: setlist.trackId,
                title: SetlistText.normalized(setlist.trackTitle),
                subtitle: ""
            ))
        }
        if !StationsModel.shared.hasLoaded {
            await StationsModel.shared.reload()
        }
        for seed in StationsModel.shared.widgetSeeds.prefix(Self.stationLimit) {
            collections.append(WidgetCollection(
                kind: .station,
                itemID: seed.id,
                title: seed.title,
                subtitle: seed.subtitle ?? "",
                artworkURL: seed.artworkURL
            ))
        }

        let next = Array(collections.prefix(WidgetCollectionStore.limit))
        guard next != published else { return }
        published = next
        WidgetCollectionStore.save(next)
        WidgetArtworkWriter.shared.sync(SoundingSnapshotPublisher.shared.current) { [weak self] in
            self?.reloadWidgets()
        }
        reloadWidgets()
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: SoundingSurfaceKind.collectionWidget)
    }
}
