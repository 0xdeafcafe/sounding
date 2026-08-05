import Foundation

#if DEBUG
enum MacMixAudioSelfTest {
    @MainActor
    static func run() async {
        let base = ProcessInfo.processInfo.environment["SOUNDING_TV_STREAM_HOST"] ?? "http://127.0.0.1:8787"
        Log.dj.info("MIXAUDIOTEST fetching catalog from \(base, privacy: .public)")
        do {
            let ids = try await fetchCatalogIDs(base: base)
            guard ids.count >= 2 else {
                Log.dj.error("MIXAUDIOTEST FAIL: mock server returned \(ids.count, privacy: .public) track(s); need at least 2. Is it running?")
                return
            }
            let trackA = try await fetchTrack(base: base, id: ids[0])
            let trackB = try await fetchTrack(base: base, id: ids[1])
            Log.dj.info("MIXAUDIOTEST loaded catalog entries: \(trackA.title, privacy: .public) / \(trackB.title, privacy: .public)")

            try await MacMixLoader.load(trackA, into: .a)
            try await MacMixLoader.load(trackB, into: .b)

            let engine = MixEngine.shared
            guard engine[.a].duration > 0, engine[.b].duration > 0 else {
                Log.dj.error("MIXAUDIOTEST FAIL: a deck reports zero duration after load (A=\(engine[.a].duration, privacy: .public)s B=\(engine[.b].duration, privacy: .public)s) — decode did not complete.")
                return
            }

            engine.play(deck: .a)
            engine.play(deck: .b)
            engine.crossfade = 0.5
            engine.setEQ(.low, on: .a, toDecibels: -12)
            engine.setFilterCutoff(2000, on: .b)

            try? await Task.sleep(nanoseconds: 900_000_000)

            let a = engine[.a]
            let b = engine[.b]
            Log.dj.info("MIXAUDIOTEST deck A: playing=\(a.isPlaying, privacy: .public) position=\(String(format: "%.2f", a.position), privacy: .public)s level=\(a.level, privacy: .public)")
            Log.dj.info("MIXAUDIOTEST deck B: playing=\(b.isPlaying, privacy: .public) position=\(String(format: "%.2f", b.position), privacy: .public)s level=\(b.level, privacy: .public)")

            let advanced = a.position > 0.1 && b.position > 0.1
            if advanced {
                Log.dj.info("MIXAUDIOTEST PASS: both decks decoded real audio from MockSoundCloud and their playheads advanced while crossfaded/EQ'd.")
            } else {
                Log.dj.error("MIXAUDIOTEST FAIL: a playhead did not advance — audio is not actually rendering.")
            }

            engine.stop(deck: .a)
            engine.stop(deck: .b)
            engine.unload(deck: .a)
            engine.unload(deck: .b)
        } catch {
            Log.dj.error("MIXAUDIOTEST FAIL: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct CatalogEntry: Decodable { let id: Int }

    private static func fetchCatalogIDs(base: String) async throws -> [String] {
        guard let url = URL(string: "\(base)/catalog") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([CatalogEntry].self, from: data).map { String($0.id) }
    }

    private static func fetchTrack(base: String, id: String) async throws -> Track {
        guard let url = URL(string: "\(base)/tracks/\(id)") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return try decoder.decode(Track.self, from: data)
    }
}
#endif
