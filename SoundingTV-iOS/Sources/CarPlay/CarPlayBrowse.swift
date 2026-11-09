import CarPlay
import UIKit

extension CarPlayController {
    func makeListenNow() -> CPListTemplate {
        let template = CPListTemplate(title: "Listen Now", sections: [])
        template.tabTitle = "Listen Now"
        template.tabImage = CarPlaySymbol.image("play.circle")
        template.showsSpinnerWhileEmpty = !isListenNowHydrated
        template.emptyViewTitleVariants = ["Nothing Here Yet"]
        template.emptyViewSubtitleVariants = ["Play something on your iPhone."]
        listenNowTemplate = template
        refreshListenNow()
        return template
    }

    func refreshListenNow() {
        guard let template = listenNowTemplate else { return }
        let offer = coordinator.continueOffer(from: ContinueFrom.shared)?.offer
        let recent = RecentlyPlayed.shared.tracks
        let shelves = HomeStore.shared.forYou.shelves.filter { $0.kind != .recent && $0.kind != .station }
        let shelfEntries = shelves.map { (shelf: $0, entries: entries(of: $0)) }.filter { !$0.entries.isEmpty }

        var revision = [offer?.id ?? "-", String(isListenNowHydrated)]
        revision += recent.prefix(Self.imageRowLimit).map(\.id)
        for (shelf, entries) in shelfEntries {
            revision.append(shelf.id)
            revision += entries.prefix(Self.imageRowLimit).map(\.id)
        }
        guard revision != listenNowRevision else { return }
        listenNowRevision = revision

        var budget = Int(CPListTemplate.maximumItemCount)
        var sections: [CPListSection] = []
        if let offer {
            sections.append(CPListSection(items: [continueItem(offer)]))
            budget -= 1
        }
        var rows: [CPListImageRowItem] = []
        if !recent.isEmpty {
            let context = recent
            let entries = recent.map { CarPlayEntry.track($0, context: context, collectionId: nil) }
            let title = HomeStore.shared.forYou.titles.recentlyPlayed
            rows.append(imageRow(title: title, entries: entries) { [weak self] in
                self?.pushEntries(title: title, entries: entries)
            })
        }
        for (shelf, entries) in shelfEntries {
            let title = shelf.title
            rows.append(imageRow(title: title, entries: entries) { [weak self] in
                self?.pushEntries(title: title, entries: entries)
            })
        }
        rows = Array(rows.prefix(max(0, budget)))
        if !rows.isEmpty { sections.append(CPListSection(items: rows)) }
        sections = Array(sections.prefix(Int(CPListTemplate.maximumSectionCount)))
        template.showsSpinnerWhileEmpty = !isListenNowHydrated
        template.updateSections(sections)
    }

    private func continueItem(_ offer: ContinueFrom.Offer) -> CPListItem {
        let session = offer.session
        let item = CPListItem(text: offer.title, detailText: session.title.isEmpty ? nil : session.title)
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated {
                ContinueFrom.shared.accept(offer, play: true)
                self?.showNowPlaying()
            }
            completion()
        }
        loadArtwork(into: item, url: session.artworkURL, symbol: "arrow.clockwise")
        return item
    }

    func entries(of shelf: DiscoveryShelf) -> [CarPlayEntry] {
        switch shelf.content {
        case .tracks(let tracks):
            return tracks.map { .track($0, context: tracks, collectionId: nil) }
        case .playlists(let playlists):
            return playlists.map(CarPlayEntry.playlist)
        case .stations(let stations):
            return stations.map(CarPlayEntry.station)
        case .users:
            return []
        case .mixed(let entries):
            return entries.compactMap { entry in
                switch entry {
                case .playlist(let playlist): return .playlist(playlist)
                case .station(let station): return .station(station)
                case .user: return nil
                }
            }
        }
    }

    func imageRow(title: String, entries: [CarPlayEntry], openAll: @escaping @MainActor () -> Void) -> CPListImageRowItem {
        let size = CPListImageRowItemRowElement.maximumImageSize
        let shown = Array(entries.prefix(Self.imageRowLimit))
        let elements = shown.map { entry in
            CPListImageRowItemRowElement(
                image: artwork.cachedImage(for: entry.artworkURL, size: size)
                    ?? artwork.placeholder(symbol: entry.symbol, size: size),
                title: entry.title,
                subtitle: entry.subtitle
            )
        }
        let row = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
        row.handler = { _, completion in
            MainActor.assumeIsolated { openAll() }
            completion()
        }
        row.listImageRowHandler = { [weak self] _, index, completion in
            MainActor.assumeIsolated {
                if shown.indices.contains(index) { self?.select(shown[index]) }
            }
            completion()
        }
        for (element, entry) in zip(elements, shown) {
            guard let url = entry.artworkURL, artwork.cachedImage(for: url, size: size) == nil else { continue }
            Task { [weak self, weak row] in
                guard let image = await self?.artwork.image(for: url, size: size) else { return }
                element.image = image
                if let row { row.elements = row.elements }
            }
        }
        return row
    }

    func pushEntries(title: String, entries: [CarPlayEntry]) {
        let template = CPListTemplate(title: title, sections: [])
        let limit = Int(CPListTemplate.maximumItemCount)
        let items = entries.prefix(limit).enumerated().map { index, entry in
            entryItem(entry, loadsArtwork: index < CarPlayArtwork.perListLimit)
        }
        template.emptyViewTitleVariants = ["Nothing Here Yet"]
        template.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
        push(template)
    }

    func makeLibrary() -> CPListTemplate {
        let template = CPListTemplate(title: "Library", sections: [])
        template.tabTitle = "Library"
        template.tabImage = CarPlaySymbol.image("square.stack")
        template.emptyViewTitleVariants = ["Sign In on Your iPhone"]
        libraryTemplate = template
        refreshLibrary()
        return template
    }

    func refreshLibrary() {
        guard let template = libraryTemplate else { return }
        var items: [CPListItem] = []
        if isSignedIn {
            items.append(navigationItem(LikesPlaylist.title, symbol: "heart") { [weak self] in self?.pushLikes() })
            items.append(navigationItem("Playlists", symbol: "music.note.list") { [weak self] in self?.pushPlaylists() })
        }
        items.append(navigationItem("Albums", symbol: "square.stack") { [weak self] in self?.pushAlbums() })
        items.append(navigationItem("Artists", symbol: "music.microphone") { [weak self] in self?.pushArtists() })
        if isSignedIn {
            items.append(navigationItem("Downloads", symbol: "arrow.down.circle") { [weak self] in self?.pushDownloads() })
        }
        if hasYourMusic {
            items.append(navigationItem("Your Music", symbol: "folder") { [weak self] in self?.pushYourMusic() })
        }
        template.updateSections([CPListSection(items: items)])
    }

    private func pushLikes() {
        let shuffle = actionItem("Shuffle", symbol: "shuffle") { [weak self] in
            self?.playShuffled({ await ListeningCatalog.likesContext() }, collectionId: CollectionPolicyID.likedTracks)
        }
        let list = CarPlayPagedList(
            title: LikesPlaylist.title,
            leading: [shuffle],
            emptyTitle: "No Likes Yet"
        ) { [weak self] offset, limit in
            let page = await ListeningCatalog.likes(offset: offset, limit: limit)
            guard let self else { return .init(items: [], consumed: 0) }
            let items = self.trackItems(page.tracks, startingAt: offset, context: {
                await ListeningCatalog.likesContext()
            }, collectionId: CollectionPolicyID.likedTracks)
            return .init(items: items, consumed: page.rowCount)
        }
        push(list.start())
    }

    private func pushPlaylists() {
        let list = CarPlayPagedList(title: "Playlists", emptyTitle: "No Playlists Yet") { [weak self] offset, limit in
            let page = await ListeningCatalog.playlists(offset: offset, limit: limit)
            guard let self else { return .init(items: [], consumed: 0) }
            let items = page.playlists.enumerated().map { index, playlist in
                self.playlistItem(playlist, loadsArtwork: offset + index < CarPlayArtwork.perListLimit)
            }
            return .init(items: items, consumed: page.rowCount)
        }
        push(list.start())
    }

    private func pushAlbums() {
        let signedIn = isSignedIn
        pushCollections(title: "Albums", emptyTitle: "No Albums Yet") {
            let albums = await ListeningCatalog.albums()
            return signedIn ? albums : albums.filter(\.isLocal)
        }
    }

    private func pushArtists() {
        pushCollections(title: "Artists", emptyTitle: "No Artists Yet") {
            ListeningCatalog.artists()
        }
    }

    private func pushCollections(title: String, emptyTitle: String, load: @escaping @MainActor () async -> [LibraryGridItem]) {
        let box = CarPlayLazy(load: load)
        let list = CarPlayPagedList(title: title, emptyTitle: emptyTitle) { [weak self] offset, limit in
            let all = await box.value()
            guard let self else { return .init(items: [], consumed: 0) }
            let slice = all.dropFirst(offset).prefix(limit)
            let items = slice.enumerated().map { index, grid in
                self.collectionItem(grid, loadsArtwork: offset + index < CarPlayArtwork.perListLimit)
            }
            return .init(items: items, consumed: slice.count)
        }
        push(list.start())
    }

    private func pushDownloads() {
        pushTracks(title: "Downloads", emptyTitle: "No Downloads", collectionId: nil) {
            ListeningCatalog.downloads()
        }
    }

    private func pushYourMusic() {
        pushTracks(title: "Your Music", emptyTitle: "No Music Files", collectionId: nil) {
            ListeningCatalog.yourMusic()
        }
    }

    func pushPlaylist(_ playlist: Playlist) {
        PlaybackQueueSourceDirectory.note(playlist)
        pushTracks(title: playlist.title, emptyTitle: "No Tracks", collectionId: playlist.id) {
            await ListeningCatalog.playlistTracks(playlist)
        }
    }

    func pushLocalCollection(_ collection: LocalCollection) {
        let tracks = collection.tracks
        pushTracks(title: collection.title, emptyTitle: "No Tracks", collectionId: nil) { tracks }
    }

    func pushTracks(
        title: String,
        emptyTitle: String,
        emptySubtitle: String? = nil,
        collectionId: String?,
        shuffles: Bool = true,
        leading extra: [CPListItem] = [],
        load: @escaping CarPlayTrackContext
    ) {
        let box = CarPlayLazy(load: load)
        let context: CarPlayTrackContext = { await box.value() }
        var leading = extra
        if shuffles {
            leading.append(actionItem("Shuffle", symbol: "shuffle") { [weak self] in
                self?.playShuffled(context, collectionId: collectionId)
            })
        }
        let list = CarPlayPagedList(
            title: title,
            leading: leading,
            emptyTitle: emptyTitle,
            emptySubtitle: emptySubtitle
        ) { [weak self] offset, limit in
            let all = await box.value()
            guard let self else { return .init(items: [], consumed: 0) }
            let slice = Array(all.dropFirst(offset).prefix(limit))
            let items = self.trackItems(slice, startingAt: offset, context: context, collectionId: collectionId)
            return .init(items: items, consumed: slice.count)
        }
        push(list.start())
    }

    func makeStations() -> CPListTemplate {
        let template = CPListTemplate(title: "Stations", sections: [])
        template.tabTitle = "Stations"
        template.tabImage = CarPlaySymbol.image("dot.radiowaves.left.and.right")
        template.emptyViewTitleVariants = ["No Stations Yet"]
        stationsTemplate = template
        refreshStations()
        return template
    }

    func refreshStations() {
        guard let template = stationsTemplate else { return }
        let shelves = HomeStore.shared.forYou.shelves
        let stations = ListeningCatalog.stations(in: shelves)
        let personal = ListeningCatalog.stationShelves(in: shelves)
        let revision = stations.map(\.id) + personal.map(\.id)
        guard revision != stationsRevision || startStationItem == nil else { return }
        stationsRevision = revision

        let start = actionItem("Start Station", symbol: "dot.radiowaves.left.and.right") { [weak self] in
            self?.startStationFromNowPlaying()
        }
        startStationItem = start
        refreshStartStation()

        var budget = Int(CPListTemplate.maximumItemCount) - 1
        var sections = [CPListSection(items: [start])]
        var mine: [CPListItem] = []
        for shelf in personal.prefix(max(0, budget)) {
            guard case .tracks(let tracks) = shelf.content else { continue }
            let title = shelf.title
            mine.append(navigationItem(title, symbol: "dot.radiowaves.left.and.right") { [weak self] in
                self?.pushTracks(title: title, emptyTitle: "No Tracks", collectionId: nil) { tracks }
            })
        }
        budget -= mine.count
        if !mine.isEmpty { sections.append(CPListSection(items: mine, header: "For You", sectionIndexTitle: nil)) }
        let featured = stations.prefix(max(0, budget)).enumerated().map { index, station in
            stationItem(station, loadsArtwork: index < CarPlayArtwork.perListLimit)
        }
        if !featured.isEmpty { sections.append(CPListSection(items: featured, header: "Stations", sectionIndexTitle: nil)) }
        template.updateSections(sections)
    }

    func refreshStartStation() {
        guard let item = startStationItem else { return }
        let snapshot = coordinator.nowPlaying
        let canStart = isSignedIn && snapshot?.trackId != nil && !(snapshot?.isDeviceTrack ?? true)
        let detail = canStart ? snapshot?.displayTitle : "Play a SoundCloud track first"
        if item.detailText != detail { item.setDetailText(detail) }
        if item.isEnabled != canStart { item.isEnabled = canStart }
    }

    private func startStationFromNowPlaying() {
        guard let snapshot = coordinator.nowPlaying, let seed = snapshot.trackId, !snapshot.isDeviceTrack else { return }
        perform { try await IntentPlayback.playStation(seedTrackID: seed) }
    }

    func openStation(_ station: SystemPlaylist) {
        let title = DiscoveryEntry.station(station).cardTitle
        if station.stationKind == .other {
            pushTracks(title: title, emptyTitle: "No Tracks", collectionId: station.id) {
                (try? await StationQueue.load(station)) ?? []
            }
            return
        }
        perform { [weak self] in
            let tracks = try await StationQueue.load(station)
            guard let self, let first = tracks.first else { throw PlaybackIntentError.notFound }
            if let failure = await self.coordinator.play(first, in: tracks, collectionId: station.id) {
                throw PlaybackIntentError.refused(failure)
            }
        }
    }

    func makeSearch() -> CPListTemplate {
        let assistant = CPAssistantCellConfiguration(position: .top, visibility: .always, assistantAction: .playMedia)
        let template = CPListTemplate(title: "Search", sections: [], assistantCellConfiguration: assistant)
        template.tabSystemItem = .search
        template.emptyViewTitleVariants = ["No Recent Searches"]
        template.emptyViewSubtitleVariants = ["Ask Siri to play something."]
        searchTemplate = template
        let recents = SettingsStore.shared.recentSearchQueries.prefix(Int(CPListTemplate.maximumItemCount))
        let items = recents.map { entry in
            navigationItem(entry.query, symbol: "magnifyingglass") { [weak self] in
                self?.pushSearchResults(entry.query)
            }
        }
        if !items.isEmpty {
            template.updateSections([CPListSection(items: Array(items), header: "Recent Searches", sectionIndexTitle: nil)])
        }
        return template
    }

    func pushSearchResults(_ query: String) {
        let list = CarPlayPagedList(
            title: query,
            pageSize: Int(CPListTemplate.maximumItemCount),
            emptyTitle: "No Results in Your Library"
        ) { [weak self] offset, limit in
            guard offset == 0 else { return .init(items: [], consumed: 0) }
            let hits = await ListeningCatalog.searchLibrary(query, limit: limit)
            guard let self else { return .init(items: [], consumed: 0) }
            let tracks = hits.compactMap(\.hit.track)
            let items = hits.enumerated().map { index, libraryHit in
                self.searchItem(libraryHit.hit, tracks: tracks, loadsArtwork: index < CarPlayArtwork.perListLimit)
            }
            return .init(items: items, consumed: 0)
        }
        push(list.start())
    }

    private func searchItem(_ hit: SearchHit, tracks: [Track], loadsArtwork: Bool) -> CPListItem {
        switch hit {
        case .track(let track):
            return trackItem(track, context: { tracks }, loadsArtwork: loadsArtwork)
        case .playlist(let playlist):
            return playlistItem(playlist, loadsArtwork: loadsArtwork)
        case .artist(let user):
            let item = CPListItem(text: user.displayName, detailText: "Artist")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated { self?.pushArtist(name: user.displayName, userID: user.id) }
                completion()
            }
            loadArtwork(into: item, url: user.avatarURL, round: true, symbol: "music.microphone", loads: loadsArtwork)
            return item
        }
    }
}

@MainActor
final class CarPlayLazy<Value: Sendable> {
    private let load: @MainActor () async -> Value
    private var cached: Value?
    private var inflight: Task<Value, Never>?

    init(load: @escaping @MainActor () async -> Value) {
        self.load = load
    }

    func value() async -> Value {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        let load = self.load
        let task = Task { await load() }
        inflight = task
        let value = await task.value
        cached = value
        inflight = nil
        return value
    }
}
