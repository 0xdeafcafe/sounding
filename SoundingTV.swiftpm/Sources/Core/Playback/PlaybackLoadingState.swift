import AVFoundation
import Foundation

enum PlaybackLoadingState: Equatable {
    case idle
    case resolvingStream
    case buffering
    case playing
}

/// Where the active item's bytes come from. This is deliberately independent
/// from resolving/buffering/playing so future live streams can use the same
/// transport state machine without pretending to be a fully cached file.
enum PlaybackMediaOrigin: Equatable {
    case localCache
    case networkStream
    case peerStream
}

struct PlaybackResolvedSource: Equatable {
    let url: URL
    let origin: PlaybackMediaOrigin
    var asset: AVURLAsset? = nil

    func makeAsset() -> AVURLAsset {
        asset ?? FairPlayStreaming.makeAsset(url: url)
    }
}

enum PlaybackSourcePurpose: Sendable {
    case streaming
    case decodedAudio
}

/// The transport owns timeline validity. UI gestures, companion commands and
/// delayed AVFoundation callbacks may all arrive after a track has changed;
/// none of them are allowed to publish a position outside the active item.
enum PlaybackTimelinePolicy {
    static func clampedPosition(_ position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard position.isFinite else { return 0 }
        let nonnegative = max(0, position)
        guard duration.isFinite, duration > 0 else { return nonnegative }
        return min(nonnegative, duration)
    }

    static func accepts(expectedTrackID: String?, activeTrackID: String?) -> Bool {
        guard let expectedTrackID else { return true }
        return expectedTrackID == activeTrackID
    }

    /// A transition may intentionally enter a little way into the incoming
    /// item, but a cue at or beyond its tail is never meaningful. Treat it as
    /// stale cross-track state and start the new item from zero.
    static func transitionStartPosition(
        _ position: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let bounded = clampedPosition(position, duration: duration)
        guard duration.isFinite, duration > 0.25 else { return bounded }
        return bounded >= duration - 0.25 ? 0 : bounded
    }

    static func transitionStartPosition(
        _ position: TimeInterval,
        duration: TimeInterval,
        transitionSeconds: TimeInterval
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0 else {
            return max(0, position.isFinite ? position : 0)
        }
        let upperBound = max(0, duration - max(0, transitionSeconds) - 5)
        let bounded = position.isFinite ? position : 0
        return min(max(0, bounded), upperBound)
    }
}

/// A stalled player gets one cheap recovery on the existing item before the
/// transport spends another network request resolving and rebuilding it.
/// Keeping these decisions outside PlayerService makes the startup budget
/// explicit and independently testable on every platform.
enum PlaybackBufferingPolicy {
    static let initialKickDelay: Duration = .seconds(3)
    static let recoveryDelayAfterKick: Duration = .seconds(7)
    static let minimumMeaningfulAdvance: TimeInterval = 0.5

    static func hasNotAdvanced(
        currentTime: TimeInterval,
        from startingTime: TimeInterval
    ) -> Bool {
        guard currentTime.isFinite, startingTime.isFinite else { return true }
        return currentTime < startingTime + minimumMeaningfulAdvance
    }
}

/// Shared limits for speculative playback preparation. Every client may
/// express intent (focus, hover, or queue lookahead), but the transport keeps
/// only one short-lived player warm so navigation cannot grow network or
/// decoder usage without bound.
enum PlaybackPrewarmingPolicy {
    static let maximumPreparedItems = 1
    static let expirationInterval: TimeInterval = 25
    static let preferredForwardBufferDuration: TimeInterval = 5
    static let nextTrackRefreshLead: TimeInterval = 18
    static let speculativeSpacing: TimeInterval = 2

    static func isFresh(
        preparedTrackID: String,
        expectedTrackID: String,
        preparedAt: Date,
        now: Date = Date()
    ) -> Bool {
        preparedTrackID == expectedTrackID
            && now.timeIntervalSince(preparedAt) >= 0
            && now.timeIntervalSince(preparedAt) < expirationInterval
    }
}

enum PlaybackSourceResolutionError: Error, LocalizedError {
    case unsupportedFormat
    case protectedAudio
    case protectedOnSonos

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "SoundCloud only offers a format this audio pipeline cannot decode."
        case .protectedAudio:
            return Self.protectedAudioStatus
        case .protectedOnSonos:
            return "Protected Go+ track. It can\u{2019}t play on Sonos."
        }
    }

    static let protectedAudioStatus = "Protected Go+ track. It plays, but can\u{2019}t be mixed or analysed."
}

/// The single source-selection and short-lived resolution-cache owner used by
/// ordinary playback, manual decks, analysis, and future playback consumers.
/// It decides local versus network and applies one quality/codec policy; media
/// consumers only decide how to render the returned bytes.
@MainActor
final class PlaybackSourceResolver {
    static let shared = PlaybackSourceResolver(
        downloads: .shared,
        qualityOverrides: .shared,
        settings: .shared,
        api: .shared
    )

    private let downloads: DownloadManager
    private let qualityOverrides: CollectionQualityOverrideStore
    private let settings: SettingsStore
    private let api: SoundCloudAPI

    init(
        downloads: DownloadManager,
        qualityOverrides: CollectionQualityOverrideStore,
        settings: SettingsStore,
        api: SoundCloudAPI
    ) {
        self.downloads = downloads
        self.qualityOverrides = qualityOverrides
        self.settings = settings
        self.api = api
    }

    func playbackSource(
        for track: Track,
        collectionID: String?,
        skipLocalFile: Bool = false,
        prefetchedNetworkURL: URL? = nil,
        useResolutionCache: Bool = true,
        allowsPreview: Bool = true
    ) async throws -> PlaybackResolvedSource {
        if track.isLocal {
            return PlaybackResolvedSource(url: try await LocalMusicLibrary.shared.playableURL(for: track), origin: .localCache)
        }
        #if DEBUG
        if let url = await FixtureAudio.url() {
            return PlaybackResolvedSource(url: url, origin: .networkStream)
        }
        #endif
        let grant = try await SubscriptionService.shared.requirePlaybackGrant(for: track, allowsPreview: allowsPreview)
        if grant == .full, !skipLocalFile, let asset = await downloads.playbackAsset(for: track) {
            return PlaybackResolvedSource(url: asset.url, origin: .localCache, asset: asset)
        }
        if grant == .full, !skipLocalFile, let asset = await PlayedAudioCache.shared.playbackAsset(for: track) {
            return PlaybackResolvedSource(url: asset.url, origin: .localCache, asset: asset)
        }
        if let prefetchedNetworkURL {
            return PlaybackResolvedSource(url: prefetchedNetworkURL, origin: .networkStream)
        }
        return PlaybackResolvedSource(
            url: try await networkURL(
                for: track,
                collectionID: collectionID,
                purpose: .streaming,
                useResolutionCache: useResolutionCache
            ),
            origin: .networkStream
        )
    }

    func decodedAudioURL(for track: Track, collectionID: String?) async throws -> URL {
        if track.isLocal { return try await LocalMusicLibrary.shared.playableURL(for: track) }
        _ = try await SubscriptionService.shared.requirePlaybackGrant(for: track, allowsPreview: false)
        if let lease = await downloads.temporaryPlaintextFile(for: track) { return lease.url }
        if track.needsFairPlay { throw PlaybackSourceResolutionError.protectedAudio }
        return try await networkURL(
            for: track,
            collectionID: collectionID,
            purpose: .decodedAudio,
            useResolutionCache: true
        )
    }

    func networkURL(
        for track: Track,
        collectionID: String?,
        purpose: PlaybackSourcePurpose,
        useResolutionCache: Bool
    ) async throws -> URL {
        if track.isLocal { return try await LocalMusicLibrary.shared.playableURL(for: track) }
        let grant = try await SubscriptionService.shared.requirePlaybackGrant(
            for: track,
            allowsPreview: purpose == .streaming
        )
        let source = grant == .preview
            ? track.bestPreview
            : transcoding(for: track, collectionID: collectionID, purpose: purpose)
        if purpose == .decodedAudio, source == nil {
            throw track.needsFairPlay ? PlaybackSourceResolutionError.protectedAudio : .unsupportedFormat
        }
        let key = resolutionCacheKey(track: track, transcoding: source, purpose: purpose)
        if let source, source.isFairPlay {
            if useResolutionCache, let cached = StreamResolutionDiskCache.url(for: key),
               FairPlayLicenceRegistry.licence(for: cached) != nil {
                return cached
            }
            let resolved = try await fairPlayURL(for: track, transcoding: source)
            StreamResolutionDiskCache.store(resolved, for: key)
            return resolved
        }
        if useResolutionCache, let cached = StreamResolutionDiskCache.url(for: key) { return cached }
        if useResolutionCache, purpose == .decodedAudio, grant == .full,
           source == transcoding(for: track, collectionID: collectionID, purpose: .streaming),
           let streaming = StreamResolutionDiskCache.url(
               for: resolutionCacheKey(track: track, transcoding: source, purpose: .streaming)
           ) {
            return streaming
        }
        if !useResolutionCache { StreamResolutionDiskCache.removeValue(for: key) }

        let resolved = try await SoundCloudRequestEnvironment.playback {
            try await api.getStreamURL(for: track, transcoding: source)
        }
        StreamResolutionDiskCache.store(resolved, for: key)
        return resolved
    }

    private func fairPlayURL(for track: Track, transcoding: Transcoding) async throws -> URL {
        let resolution = try await SoundCloudRequestEnvironment.playback {
            try await api.getStreamResolution(for: track, transcoding: transcoding)
        }
        guard let token = resolution.licenseAuthToken else {
            FairPlayDebugLog.note("resolve track=\(track.id) returned no licence token")
            throw FairPlayLicenceError.missingLicenceToken
        }
        FairPlayDebugLog.note("resolve track=\(track.id) preset=\(transcoding.preset ?? "?") licence token \(token.utf8.count) bytes")
        guard FairPlayStreaming.isSupported else {
            #if DEBUG
            if let certificate = try? await FairPlayLicenceServer.applicationCertificate() {
                FairPlayDebugLog.note("certificate ready bytes=\(certificate.count); key sessions are unavailable here")
            }
            #endif
            throw FairPlayLicenceError.unsupportedOnThisDevice
        }
        FairPlayLicenceRegistry.register(token: token, trackID: track.id, for: resolution.url)
        return resolution.url
    }

    func transcoding(
        for track: Track,
        collectionID: String?,
        purpose: PlaybackSourcePurpose
    ) -> Transcoding? {
        let candidates: [Transcoding]
        switch purpose {
        case .streaming: candidates = track.transcodings
        case .decodedAudio: candidates = track.decodableTranscodings.filter { $0.codec != .opus }
        }
        let ceiling = qualityOverrides.effectiveCeiling(
            for: collectionID ?? track.id,
            default: settings.streamingQualityCeiling
        )
        return ceiling.bestTranscoding(among: candidates)
    }

    func clearResolutionCache() {
        StreamResolutionDiskCache.clear()
    }

    private func resolutionCacheKey(
        track: Track,
        transcoding: Transcoding?,
        purpose: PlaybackSourcePurpose
    ) -> String {
        let purposeKey = purpose == .streaming ? "stream" : "decoded"
        return "\(purposeKey)|\(track.id)|\(transcoding?.url.absoluteString ?? track.streamURL?.absoluteString ?? "default")"
    }
}

private enum StreamResolutionDiskCache {
    private static let defaultsKey = "red.forbes.sounding.streaming.resolvedURLs.v2"
    private static let legacyDefaultsKey = "red.forbes.sounding.streaming.resolvedURLs.v1"

    private nonisolated(unsafe) static var memory: ResolvedStreamURLCache?
    private static let lock = NSLock()

    static func url(for key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        var cache = current()
        let url = cache.url(for: key, now: Date())
        memory = cache
        return url
    }

    static func store(_ url: URL, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var cache = current()
        cache.store(url, signedExpiry: SoundCloudSignedURLExpiry.expiry(of: url), for: key, now: Date())
        memory = cache
        persist(cache)
    }

    static func removeValue(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var cache = current()
        cache.remove(key)
        memory = cache
        persist(cache)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        memory = ResolvedStreamURLCache()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    private static func current() -> ResolvedStreamURLCache {
        if let memory { return memory }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let loaded = try? JSONDecoder().decode(ResolvedStreamURLCache.self, from: data) else {
            return ResolvedStreamURLCache()
        }
        return loaded
    }

    private static func persist(_ cache: ResolvedStreamURLCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// The one authoritative lifecycle for ordinary playback. AVPlayer callbacks,
/// async URL resolution, system transport commands, and cache recovery all
/// carry a generation issued here. An older operation can never mutate a newer
/// track, and transport intent is independent from whether audio is currently
/// advancing.
struct PlaybackPipeline: Equatable {
    enum Intent: Equatable {
        case play
        case pause
    }

    enum Phase: Equatable {
        case idle
        case resolving(trackID: String)
        case buffering(trackID: String)
        case playing(trackID: String)
        case paused(trackID: String)
        case failed(trackID: String, message: String)

        var trackID: String? {
            switch self {
            case .idle: return nil
            case .resolving(let id), .buffering(let id), .playing(let id), .paused(let id), .failed(let id, _):
                return id
            }
        }
    }

    struct Token: Equatable, Sendable {
        let generation: UInt64
        let trackID: String
    }

    private(set) var intent: Intent = .pause
    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0

    var wantsPlayback: Bool { intent == .play }
    var isPlaying: Bool {
        if case .playing = phase { return true }
        return false
    }
    var isLoading: Bool {
        guard wantsPlayback else { return false }
        switch phase {
        case .resolving, .buffering: return true
        default: return false
        }
    }
    var loadingState: PlaybackLoadingState {
        switch phase {
        case .resolving: return wantsPlayback ? .resolvingStream : .idle
        case .buffering: return wantsPlayback ? .buffering : .idle
        case .playing: return .playing
        case .idle, .paused, .failed: return .idle
        }
    }

    @discardableResult
    mutating func begin(trackID: String, intent: Intent) -> Token {
        generation &+= 1
        self.intent = intent
        phase = intent == .play ? .resolving(trackID: trackID) : .paused(trackID: trackID)
        return Token(generation: generation, trackID: trackID)
    }

    mutating func requestPlay(trackID: String?) {
        intent = .play
        guard let trackID else {
            phase = .idle
            return
        }
        switch phase {
        case .playing, .buffering, .resolving:
            break
        case .idle, .paused, .failed:
            phase = .buffering(trackID: trackID)
        }
    }

    mutating func requestPause(trackID: String?) {
        intent = .pause
        // Resolution may safely finish while paused. Intent, not phase,
        // decides whether the resulting item is allowed to start.
        if case .resolving(let resolvingTrackID) = phase,
           resolvingTrackID == trackID {
            return
        }
        phase = trackID.map { .paused(trackID: $0) } ?? .idle
    }

    @discardableResult
    mutating func transition(_ phase: Phase, for token: Token) -> Bool {
        guard accepts(token) else { return false }
        self.phase = phase
        return true
    }

    mutating func transitionCurrent(to phase: Phase) {
        self.phase = phase
    }

    func accepts(_ token: Token) -> Bool {
        generation == token.generation && token.trackID == phase.trackID
    }

    mutating func invalidate(keeping trackID: String? = nil) {
        generation &+= 1
        intent = .pause
        phase = trackID.map { .paused(trackID: $0) } ?? .idle
    }
}

#if DEBUG
enum FixtureAudio {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_FIXTURE_AUDIO"] == "1"
    }

    static func url() async -> URL? {
        guard isEnabled else { return nil }
        return await Task.detached(priority: .userInitiated) { render() }.value
    }

    private static let sampleRate = 22_050
    private static let tempo = 124.0
    private static let barCount = 48

    private static func render() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sounding-fixture-audio-v1.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let rate = Float(sampleRate)
        let beat = Int((Double(sampleRate) * 60 / tempo).rounded())
        let eighth = beat / 2
        let bar = beat * 4

        func kick() -> [Float] {
            var phase: Float = 0
            return (0..<beat).map { i in
                let t = Float(i) / rate
                phase += 2 * .pi * (45 + 90 * exp(-t * 28)) / rate
                return sin(phase) * exp(-t * 7) * min(1, Float(i) / 40)
            }
        }

        func bass(_ frequency: Float) -> [Float] {
            (0..<eighth).map { i in
                let t = Float(i) / rate
                let phase = 2 * .pi * frequency * t
                return (sin(phase) + 0.35 * sin(2 * phase)) * exp(-t * 6) * min(1, Float(i) / 60) * 0.7
            }
        }

        func hat() -> [Float] {
            var state: UInt32 = 0x1234_5678
            var previous: Float = 0
            return (0..<eighth).map { i in
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Float(state >> 8) / Float(1 << 24) * 2 - 1
                let high = noise - previous
                previous = noise
                return high * exp(-Float(i) / rate * 55) * 0.22
            }
        }

        func pad(_ chord: [Float]) -> [Float] {
            (0..<bar).map { i in
                let t = Float(i) / rate
                let x = Float(i) / Float(bar)
                let envelope = min(1, x * 6) * min(1, (1 - x) * 6)
                var sum: Float = 0
                for f in chord { sum += sin(2 * .pi * f * t) }
                return sum / Float(chord.count) * envelope * 0.22
            }
        }

        let bassNotes: [Float] = [55, 43.65, 65.41, 49]
        let chords: [[Float]] = [[220, 261.6, 329.6], [174.6, 220, 261.6], [261.6, 329.6, 392], [196, 246.9, 293.7]]
        let kickLoop = kick()
        let hatLoop = hat()
        let bassLoops = bassNotes.map(bass)
        let padLoops = chords.map(pad)

        var mix = [Float](repeating: 0, count: bar * barCount)
        for b in 0..<barCount {
            let origin = b * bar
            let breakdown = (24..<28).contains(b)
            let chord = b % 4
            for i in 0..<bar { mix[origin + i] += padLoops[chord][i] * (breakdown ? 1.6 : 1) }
            if !breakdown, b >= 2 {
                for q in 0..<4 { add(kickLoop, into: &mix, at: origin + q * beat) }
            }
            if !breakdown, b >= 4 {
                for q in 0..<8 where q % 2 == 1 { add(hatLoop, into: &mix, at: origin + q * eighth) }
            }
            if !breakdown, b >= 8 {
                for q in 0..<4 { add(bassLoops[chord], into: &mix, at: origin + q * beat + eighth) }
            }
        }

        let peak = max(mix.map { abs($0) }.max() ?? 1, 0.001)
        let gain = 0.8 / peak
        let fade = sampleRate * 2
        var pcm = Data(capacity: mix.count * 2 + 44)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let dataBytes = UInt32(mix.count * 2)
        pcm.append(contentsOf: Array("RIFF".utf8)); put(36 + dataBytes)
        pcm.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        pcm.append(contentsOf: Array("data".utf8)); put(dataBytes)
        for (i, sample) in mix.enumerated() {
            let edge = min(1, Float(min(i, mix.count - 1 - i)) / Float(fade))
            put(Int16(max(-1, min(1, sample * gain * edge)) * 32_000))
        }
        do {
            try pcm.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func add(_ clip: [Float], into mix: inout [Float], at start: Int) {
        let end = min(mix.count, start + clip.count)
        guard start < end else { return }
        for i in start..<end { mix[i] += clip[i - start] }
    }
}
#endif
