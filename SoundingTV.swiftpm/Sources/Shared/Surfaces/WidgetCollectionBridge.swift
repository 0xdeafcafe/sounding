import Foundation

enum WidgetCollectionBridge {
    @MainActor
    static func play(kind: String, id: String, shuffle: Bool) async throws {
        switch WidgetCollection.Kind(rawValue: kind) {
        case .playlist:
            try await IntentPlayback.playPlaylist(id: id, shuffle: shuffle)
        case .setlist:
            try await IntentPlayback.playTrack(id: id)
        case .station:
            try await playStation(id: id)
        case nil:
            throw PlaybackIntentError.notFound
        }
        SoundingSnapshotPublisher.shared.flush()
    }

    @MainActor
    private static func playStation(id: String) async throws {
        let model = StationsModel.shared
        var seed = model.widgetSeeds.first { $0.id == id }
        if seed == nil {
            await model.reload()
            seed = model.widgetSeeds.first { $0.id == id }
        }
        guard let seed else { throw PlaybackIntentError.notFound }
        if let message = await StationPlayer.start(seed, restart: true) {
            throw PlaybackIntentError.refused(message)
        }
    }
}

extension StationsModel {
    var widgetSeeds: [StationSeed] {
        var seen = Set<String>()
        return ([yourStation].compactMap { $0 } + recents + liked + forYou + artists)
            .filter { seen.insert($0.id).inserted }
    }
}
