import CryptoKit
import Foundation
import Observation

actor LyricsCache {
    struct Entry: Codable, Sendable {
        var lookup: LyricsLookup
        var storedAt: Date
    }

    static let shared = LyricsCache()

    static let foundLifetime: TimeInterval = 60 * 60 * 24 * 60
    static let missLifetime: TimeInterval = 60 * 60 * 24 * 3

    private let directory: URL?
    private let now: @Sendable () -> Date
    private var memory: [String: Entry] = [:]

    init(directory: URL? = LyricsCache.defaultDirectory(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.soundingDirectory(.cachesDirectory)?.appendingPathComponent("Lyrics", isDirectory: true)
    }

    func lookup(for key: String) -> LyricsLookup? {
        let entry = memory[key] ?? readDisk(key)
        guard let entry else { return nil }
        let lifetime = entry.lookup == .notFound ? Self.missLifetime : Self.foundLifetime
        guard now().timeIntervalSince(entry.storedAt) < lifetime else {
            memory[key] = nil
            if let url = fileURL(key) { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        memory[key] = entry
        return entry.lookup
    }

    func store(_ lookup: LyricsLookup, for key: String) {
        let entry = Entry(lookup: lookup, storedAt: now())
        memory[key] = entry
        if memory.count > 64 { memory.removeAll(keepingCapacity: true); memory[key] = entry }
        guard let url = fileURL(key), let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func readDisk(_ key: String) -> Entry? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func fileURL(_ key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest + ".json")
    }
}

enum LyricsState: Equatable, Sendable {
    case needsConsent
    case off
    case idle
    case loading
    case loaded(Lyrics)
    case notFound
    case mix
    case offline
    case unavailable
}

@MainActor
@Observable
final class LyricsStore {
    static let shared = LyricsStore()

    private(set) var states: [String: LyricsState] = [:]

    @ObservationIgnored private let client: LRCLIBClient
    @ObservationIgnored private let cache: LyricsCache
    @ObservationIgnored private let provider: @MainActor () -> LyricsProvider
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var wanted: [String] = []

    init(
        client: LRCLIBClient = .shared,
        cache: LyricsCache = .shared,
        provider: @escaping @MainActor () -> LyricsProvider = { SettingsStore.shared.lyricsSource }
    ) {
        self.client = client
        self.cache = cache
        self.provider = provider
    }

    var isEnabled: Bool { provider() == .lrclib }

    func state(for trackID: String?) -> LyricsState {
        #if DEBUG
        if let fixture = Self.fixtureState { return fixture }
        #endif
        switch provider() {
        case .unset: return .needsConsent
        case .off: return .off
        case .lrclib: break
        }
        guard let trackID else { return .idle }
        return states[trackID] ?? .idle
    }

    func focus(current: Track?, next: Track?) {
        #if DEBUG
        if Self.fixtureState != nil { return }
        #endif
        guard isEnabled else {
            cancelAll()
            return
        }
        let ids = [current?.id, next?.id].compactMap { $0 }
        wanted = ids
        for (id, task) in tasks where !ids.contains(id) {
            task.cancel()
            tasks[id] = nil
            if states[id] == .loading { states[id] = nil }
        }
        if states.count > 40 {
            states = states.filter { ids.contains($0.key) }
        }
        guard let current else { return }
        let next = next.flatMap { $0.id == current.id ? nil : $0 }
        start(current) { [weak self] in
            guard let self, let next, self.wanted.contains(next.id) else { return }
            self.start(next, then: nil)
        }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        wanted.removeAll()
        states = states.filter { $0.value != .loading }
    }

    func retry(_ track: Track) {
        guard isEnabled, states[track.id] == .offline || states[track.id] == .unavailable else { return }
        states[track.id] = nil
        start(track, then: nil)
    }

    private func start(_ track: Track, then: (@MainActor () -> Void)?) {
        guard isEnabled else { return }
        if let state = states[track.id], state != .idle, state != .offline, state != .unavailable {
            if state != .loading { then?() }
            return
        }
        guard tasks[track.id] == nil else { return }
        let source = LyricsTrackInfo(track: track)
        if source.isMix {
            states[track.id] = .mix
            then?()
            return
        }
        guard let plan = LyricsSignatureDeriver.plan(for: source) else {
            states[track.id] = .notFound
            then?()
            return
        }
        states[track.id] = .loading
        let client = self.client
        let cache = self.cache
        let id = track.id
        let key = plan.cacheKey
        tasks[id] = Task { [weak self] in
            let state: LyricsState
            if let cached = await cache.lookup(for: key) {
                state = Self.state(for: cached)
            } else {
                do {
                    let lookup = try await client.lookup(plan)
                    await cache.store(lookup, for: key)
                    state = Self.state(for: lookup)
                } catch LyricsError.offline {
                    state = .offline
                } catch is CancellationError {
                    return
                } catch {
                    state = Task.isCancelled ? .idle : .unavailable
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.tasks[id] = nil
            self.states[id] = state
            then?()
        }
    }

    nonisolated private static func state(for lookup: LyricsLookup) -> LyricsState {
        switch lookup {
        case .found(let lyrics): .loaded(lyrics)
        case .notFound: .notFound
        }
    }

    #if DEBUG
    static let fixtureState: LyricsState? = {
        guard let mode = ProcessInfo.processInfo.environment["SOUNDING_TV_LYRICS_FIXTURE"] else { return nil }
        let verses = [
            "Copper in the cable, light along the wire",
            "Every little signal running higher",
            "Turn the dial slowly, hear the room arrive",
            "Plug it in all the way",
            "We were only static till the music came",
            "Now the speakers know your name",
            "Hold the note a little longer",
            "Let the bass line pull us under",
        ]
        func lines(words: Bool) -> [LyricLine] {
            var result: [LyricLine] = []
            var time: TimeInterval = 2
            var index = 0
            while time < 1_200 {
                let text = verses[index % verses.count]
                var lineWords: [LyricWord] = []
                if words {
                    let parts = text.split(separator: " ")
                    let step = 3.4 / Double(parts.count)
                    for (offset, part) in parts.enumerated() {
                        let start = time + Double(offset) * step
                        lineWords.append(LyricWord(text: String(part) + (offset < parts.count - 1 ? " " : ""), start: start, end: start + step))
                    }
                }
                result.append(LyricLine(id: index, text: text, start: time, end: time + 3.6, words: lineWords))
                index += 1
                time += index % 9 == 0 ? 14 : 4
            }
            return result
        }
        switch mode {
        case "consent": return .needsConsent
        case "off": return .off
        case "loading": return .loading
        case "notFound": return .notFound
        case "instrumental": return .loaded(Lyrics(body: .instrumental))
        case "offline": return .offline
        case "mix": return .mix
        case "plain": return .loaded(Lyrics(body: .plain(verses + [""] + verses.reversed())))
        case "words": return .loaded(Lyrics(body: .synced(lines(words: true))))
        default: return .loaded(Lyrics(body: .synced(lines(words: false))))
        }
    }()
    #endif
}
