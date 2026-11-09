import Foundation
import Combine

@MainActor
final class CollectionPageModel: ObservableObject {
    let detail: PlaylistDetailViewModel
    @Published private(set) var analysis: [String: TrackAnalysisSummary] = [:]

    private var detailObservation: AnyCancellable?

    init(playlist: Playlist) {
        detail = PlaylistDetailViewModel(playlist: playlist)
        detailObservation = detail.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var playlist: Playlist { detail.playlist }
    var pager: Paginator<Track> { detail.pager }
    var kind: CollectionPageKind { CollectionPageKind(playlist: playlist) }
    var id: String { playlist.id }
    var title: String { playlist.title }
    var artist: User { playlist.user }
    var artworkURL: URL? { playlist.largeDisplayArtworkURL }
    var tracks: [Track] { detail.tracks }
    var isLoading: Bool { detail.isLoading && detail.tracks.isEmpty }
    var errorMessage: String? { detail.tracks.isEmpty ? detail.errorMessage : nil }
    var isEmpty: Bool { !detail.isLoading && detail.errorMessage == nil && detail.tracks.isEmpty }
    var canPlay: Bool { tracks.contains { $0.streamURL != nil } }

    var descriptionText: String? {
        guard let text = playlist.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    var metadataLine: String {
        playlist.collectionMetadataLine(loadedTrackCount: tracks.count)
    }

    var heroContent: CollectionHeroContent {
        CollectionHeroContent(playlist: playlist, loadedTrackCount: tracks.count)
    }

    var showsArtistPerRow: Bool {
        guard kind == .album else { return true }
        return tracks.contains { $0.user.id != playlist.user.id }
    }

    func row(_ track: Track, at index: Int) -> CollectionTrackRow {
        SCTrackListItem(track: track, number: index + 1, showsArtist: showsArtistPerRow, analysis: analysis[track.id])
    }

    static func analysisText(_ summary: TrackAnalysisSummary?) -> String? {
        SCTrackListItem.analysisText(summary)
    }

    func loadIfNeeded() async {
        await detail.loadIfNeeded()
    }

    func reload() async {
        await detail.load()
    }

    func noteAppeared(_ track: Track) {
        guard tracks.isNearEnd(track, lead: 10) else { return }
        detail.requestMore()
    }

    func refreshAnalysis() async {
        guard !tracks.isEmpty else { return }
        let fresh = await AnalysisLookup.summaries(for: tracks)
        guard !fresh.isEmpty, fresh != analysis else { return }
        analysis.merge(fresh) { _, new in new }
    }

    private var playable: [Track] { tracks.filter { $0.streamURL != nil } }

    private var source: PlaybackQueueSource { PlaybackQueueSource(playlist: playlist) }

    func play() async {
        guard let first = playable.first else { return }
        PlayerService.shared.isShuffleEnabled = false
        await PlayerService.shared.play(first, in: playable, collectionId: playlist.id, source: source)
    }

    func shuffle() async {
        guard let start = playable.randomElement() else { return }
        PlayerService.shared.isShuffleEnabled = true
        await PlayerService.shared.play(start, in: playable, collectionId: playlist.id, source: source)
    }

    func play(_ track: Track) async {
        guard track.streamURL != nil else { return }
        await PlayerService.shared.play(track, in: playable, collectionId: playlist.id, source: source)
    }
}
