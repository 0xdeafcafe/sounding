#if DEBUG
import SwiftUI

@MainActor
enum DJPrepFixtures {
    static func model(store: CueStore, tier: SubscriptionService.Tier) async -> MacPrepModel {
        let tracks = MacPrepFixtures.tracks
        let analysingId = tracks[11].id
        await store.savePrep(TrackPrep(trackId: analysingId))
        for (index, track) in tracks.enumerated() {
            guard var prep = await store.prep(forTrack: track.id) else { continue }
            if index == 11 { continue }
            prep.energy = PrepField([7, 6, 8, 9, 5, 8, 8, 6, 7, 9, 4, 6][index], source: .sounding, updatedAtMillis: 1, writerId: "fixture")
            if let bpm = prep.grid?.value.bpm {
                let bar = 240 / bpm
                let kinds: [(Double, SectionKind, String?)] = [(0, .intro, nil), (16, .buildup, nil), (32, .drop, nil), (48, .breakdown, "vocal"), (64, .drop, "vocal"), (80, .outro, nil)]
                prep.phrases = PrepField(kinds.map { PrepPhrase(startMillis: CueTime.millis(fromSeconds: 0.12 + $0.0 * bar), kind: $0.1, mood: $0.2) }, source: .sounding, updatedAtMillis: 1, writerId: "fixture")
            }
            if index == 9 || index == 10 {
                prep.grid = prep.grid.map { PrepField($0.value, source: .sounding, updatedAtMillis: 1, writerId: "fixture") }
            }
            await store.savePrep(prep)
        }
        await store.saveLinkFile(TrackLinkFile(trackId: tracks[9].id, bookmark: Data([1]), path: "/Users/dj/Music/Moved/\(tracks[9].title).mp3"))
        for (index, track) in tracks.enumerated() where index % 3 == 0 {
            await store.saveLinkFile(TrackLinkFile(trackId: track.id, bookmark: Data([1]), path: "/Users/dj/Music/Promos/\(track.title).flac"))
        }
        let defaults = UserDefaults(suiteName: "DJPrepFixtures-\(UUID().uuidString)") ?? .standard
        let ledger = DJPrepExportLedger(defaults: defaults)
        ledger.record(trackIds: tracks.prefix(4).map(\.id), at: CueTime.nowMillis())
        try? await Task.sleep(for: .milliseconds(20))
        for index in [0, 3, 4] {
            _ = await store.setUserComment(trackId: tracks[index].id, "Checked")
        }
        let likes = Array(VisualFixtures.tracks.prefix(16))
        let source = MacPrepTrackSource(
            track: { id in VisualFixtures.tracks.first { $0.id == id } },
            envelope: { id, duration in MacPrepFixtures.envelope(seed: id, duration: duration) },
            likes: { likes },
            analysis: { $0 == analysingId ? .analysing : nil },
            fileExists: { !$0.path.contains("/Moved/") },
            volumes: { [MacUSBFixtures.volume("CLUB USB", in: URL(fileURLWithPath: "/Volumes"), total: 64_000_000_000, free: 58_000_000_000)] },
            confidence: { _ in 0.98 }
        )
        return MacPrepModel(store: store, tracks: source, ledger: ledger) { feature, isSoundCloud in
            SoundCloudEntitlements.djGearDenial(
                feature,
                isSoundCloudTrack: isSoundCloud,
                signedIn: true,
                tier: tier,
                verification: .verified,
                personalUnlocked: false
            )
        }
    }

    static func context() -> DJDeckContext {
        let tracks = MacPrepFixtures.tracks
        return DJDeckContext(
            decks: [
                DJDeckSlot(deck: .a, trackId: tracks[7].id, title: tracks[7].title, bpm: 127, key: "10A", isOnAir: true),
                DJDeckSlot(deck: .b, trackId: tracks[2].id, title: tracks[2].title, bpm: 126, key: "4A", isOnAir: false),
            ],
            playedTonight: [
                DJPlayedTrack(id: tracks[7].id, title: tracks[7].title, artworkURL: tracks[7].artworkURL, detail: "On A · now"),
                DJPlayedTrack(id: tracks[4].id, title: tracks[4].title, artworkURL: tracks[4].artworkURL, detail: "9:41 PM"),
                DJPlayedTrack(id: tracks[1].id, title: tracks[1].title, artworkURL: tracks[1].artworkURL, detail: "9:36 PM"),
            ],
            incoming: .b
        )
    }
}
#endif
