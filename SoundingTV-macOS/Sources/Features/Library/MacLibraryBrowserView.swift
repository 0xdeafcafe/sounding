import SwiftUI
import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let soundingTrack = UTType(exportedAs: "red.forbes.sounding.track")
}

struct MacTrackDragPayload: Codable, Transferable {
    let track: Track

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .soundingTrack)
    }
}

enum MacBrowsableRoute {
    case search
    case home

    var section: MacRootView.Section {
        switch self {
        case .search: return .search
        case .home: return .home
        }
    }

    var label: String {
        switch self {
        case .search: return "Search SoundCloud"
        case .home: return "Browse Home"
        }
    }
}

struct MacSignedOutEmptyState: View {
    var icon: String = "person.crop.circle.badge.xmark"
    let title: String
    let message: String
    var browsableRoute: MacBrowsableRoute = .search

    private let style = SCContentStyle.mac

    var body: some View {
        VStack(spacing: style.spaceSnug) {
            Image(systemName: icon)
                .font(.system(size: style.iconStrokeWidth * 20, weight: .semibold))
                .foregroundStyle(style.textTertiary)

            Text(title)
                .font(style.fontHeadline)
                .foregroundStyle(style.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(style.fontBody)
                .foregroundStyle(style.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: style.spaceSnug) {
                Button(browsableRoute.label) {
                    MacRootSelection.shared.request(browsableRoute.section)
                }
                .buttonStyle(.bordered)

                Button("Open Account") {
                    MacRootSelection.shared.request(.account)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, style.spaceHair)
        }
        .frame(maxWidth: .infinity)
        .padding(style.spaceRoomy)
    }
}

@MainActor
final class MacDeckTrackRegistry: ObservableObject {
    static let shared = MacDeckTrackRegistry()

    @Published private(set) var tracks: [Int: Track] = [:]
    @Published private(set) var loadingDecks: Set<Int> = []
    @Published private(set) var loadErrors: [Int: String] = [:]

    private init() {}

    func track(for deck: MixEngine.Deck) -> Track? { tracks[deck.rawValue] }

    func set(_ track: Track, for deck: MixEngine.Deck) {
        tracks[deck.rawValue] = track
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = nil
    }

    func beginLoading(_ track: Track, for deck: MixEngine.Deck) {
        tracks[deck.rawValue] = track
        loadErrors[deck.rawValue] = nil
        loadingDecks.insert(deck.rawValue)
    }

    func finishLoading(_ deck: MixEngine.Deck) {
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = nil
    }

    func failLoading(_ deck: MixEngine.Deck, reason: String) {
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = reason
    }

    func isLoading(_ deck: MixEngine.Deck) -> Bool {
        loadingDecks.contains(deck.rawValue)
    }

    func loadError(for deck: MixEngine.Deck) -> String? {
        loadErrors[deck.rawValue]
    }

    func clear(_ deck: MixEngine.Deck) {
        tracks[deck.rawValue] = nil
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = nil
    }

    func nextAvailableDeck() -> MixEngine.Deck {
        track(for: .a) == nil ? .a : (track(for: .b) == nil ? .b : .a)
    }
}

enum MacMixLoader {
    @MainActor
    static func load(_ track: Track, into deck: MixEngine.Deck) async throws {
        let registry = MacDeckTrackRegistry.shared
        registry.beginLoading(track, for: deck)

        do {
            let url = try await resolveMixURL(for: track)
            try await MixEngine.shared.load(
                url: url,
                into: deck,
                trackId: track.id,
                cacheKey: "track-\(track.id)-\(track.mixSource?.preset ?? "default")"
            )
            registry.finishLoading(deck)
        } catch {
            registry.failLoading(deck, reason: "Couldn’t load track")
            throw error
        }

        if let localFileURL = MixEngine.shared.localFileURL(for: deck) {
            AnalysisOpportunity.schedule(
                track: track,
                transcoding: track.mixSource,
                localFileURL: localFileURL,
                registry: AnalysisProducerRegistry([MusicUnderstandingProducer()]),
                priority: .interactive,
                enforceDeviceEligibility: false
            )
            if DeckIdentityResolver.isLikelyMix(track) {
                SetlistBackgroundWorkCoordinator.shared.enqueue(
                    track: track,
                    localFileURL: localFileURL
                )
            }
        }
    }

    @MainActor
    private static func resolveMixURL(for track: Track) async throws -> URL {
        guard let source = track.mixSource else {
            throw MixEngineError.unsupportedFormat(
                "SoundCloud only offers Opus for this track, and AVFoundation has no Opus decoder"
            )
        }

        let url = SoundCloudAPI.strippingCredentials(from: source.url)
        let token = SoundCloudAPI.credentials?.accessToken

        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.addValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw MixEngineError.cancelled
        } catch {
            throw MixEngineError.networkFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MixEngineError.httpStatus(http.statusCode)
        }

        struct StreamResponse: Decodable { let url: String }
        guard let decoded = try? JSONDecoder().decode(StreamResponse.self, from: data),
              let resolved = URL(string: decoded.url) else {
            throw MixEngineError.networkFailure("SoundCloud returned no stream URL for the mix source.")
        }
        return resolved
    }
}

enum MacAnalysisEngineKind: Hashable, Sendable {
    case musicUnderstanding
    case fftAudioAnalyzer
    case genreTaxonomy
    case soundCloudWaveform
    case userCorrection
    case other(String)

    init(engineName: String) {
        switch engineName {
        case "apple.musicUnderstanding": self = .musicUnderstanding
        case "sounding.fftAudioAnalyzer": self = .fftAudioAnalyzer
        case "sounding.genreTaxonomy": self = .genreTaxonomy
        case "soundcloud.waveform": self = .soundCloudWaveform
        case "sounding.userCorrection": self = .userCorrection
        default: self = .other(engineName)
        }
    }

    var displayName: String {
        switch self {
        case .musicUnderstanding: return "On-device analysis"
        case .fftAudioAnalyzer: return "Live FFT fallback"
        case .genreTaxonomy: return "Genre taxonomy"
        case .soundCloudWaveform: return "SoundCloud waveform"
        case .userCorrection: return "Corrected by you"
        case .other(let name): return name
        }
    }

    var symbolName: String {
        switch self {
        case .musicUnderstanding: return "waveform.badge.magnifyingglass"
        case .fftAudioAnalyzer: return "chart.bar"
        case .genreTaxonomy: return "tag"
        case .soundCloudWaveform: return "waveform"
        case .userCorrection: return "pencil"
        case .other: return "questionmark.circle"
        }
    }

    var explanation: String {
        switch self {
        case .musicUnderstanding:
            return "Apple's MusicUnderstanding ran over the audio on this device. The strongest reading this app can produce (grid confidence 0.85)."
        case .fftAudioAnalyzer:
            return "A live FFT estimate taken during playback, standing in for real analysis. Confidence never rises above 0.7."
        case .genreTaxonomy:
            return "Matched from text, not audio. The taxonomy usually only sees the track title, so most tracks resolve to nothing and the ones that do average 0.06 confidence."
        case .soundCloudWaveform:
            return "SoundCloud's published amplitude envelope, cached. It measures no tempo, key or genre."
        case .userCorrection:
            return "You entered this value yourself. It overrides anything the analysers produced."
        case .other(let name):
            return "Produced by \(name)."
        }
    }

    var tempoAndKeyProvenance: SCAnalysisProvenance {
        switch self {
        case .userCorrection: return .stated
        case .musicUnderstanding: return .measured
        case .fftAudioAnalyzer, .genreTaxonomy, .soundCloudWaveform, .other: return .inferred
        }
    }

    var tempoAndKeyAreMeasured: Bool {
        tempoAndKeyProvenance == .measured || tempoAndKeyProvenance == .stated
    }
}

struct MacAnalysisRecord: Identifiable, Sendable, Equatable {
    let cacheKey: String
    let trackId: String
    let engine: MacAnalysisEngineKind
    let engineVersion: Int
    let schemaVersion: Int
    let byteSize: Int
    let producedAt: Date
    let lastUsedAt: Date
    let producerId: String
    let isFromThisDevice: Bool
    let bpm: Double?
    let key: CamelotKey?
    let genre: String?
    let preset: String
    let bitrate: Int
    let codec: String

    var id: String { cacheKey }

    var hasIndexedValue: Bool { bpm != nil || key != nil || genre != nil }
}

struct MacAnalysisResult: Sendable, Equatable {
    var bpm: Double?
    var bpmEngine: MacAnalysisEngineKind?
    var key: CamelotKey?
    var keyEngine: MacAnalysisEngineKind?
    var genre: String?
    var genreEngine: MacAnalysisEngineKind?

    var isEmpty: Bool { bpm == nil && key == nil && genre == nil }
    var summary: TrackAnalysisSummary { TrackAnalysisSummary(bpm: bpm, key: key, genre: genre) }

    var bpmProvenance: SCAnalysisProvenance {
        guard bpm != nil, let bpmEngine else { return .unavailable }
        return bpmEngine.tempoAndKeyProvenance
    }

    var keyProvenance: SCAnalysisProvenance {
        guard key != nil, let keyEngine else { return .unavailable }
        return keyEngine.tempoAndKeyProvenance
    }

    var genreProvenance: SCAnalysisProvenance {
        guard genre != nil else { return .unavailable }
        return genreEngine == .userCorrection ? .stated : .inferred
    }

    mutating func absorb(_ record: MacAnalysisRecord) {
        if bpm == nil, let value = record.bpm, value > 0 {
            bpm = value
            bpmEngine = record.engine
        }
        if key == nil, let value = record.key {
            key = value
            keyEngine = record.engine
        }
        if genre == nil, let value = record.genre, !value.isEmpty {
            genre = value
            genreEngine = record.engine
        }
    }
}

struct MacAnalysisCorrection: Codable, Sendable, Equatable {
    var bpm: Double?
    var keyLabel: String?
    var genre: String?
    var updatedAt: Date = Date()

    var isEmpty: Bool {
        bpm == nil && (keyLabel?.isEmpty != false) && (genre?.isEmpty != false)
    }

    var key: CamelotKey? { keyLabel.flatMap(CamelotKey.parse) }
}

@MainActor
final class MacAnalysisCorrectionStore: ObservableObject {
    static let shared = MacAnalysisCorrectionStore()

    private static let defaultsKey = "red.forbes.sounding.mac.analysisCorrections"

    @Published private(set) var corrections: [String: MacAnalysisCorrection] = [:]

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: MacAnalysisCorrection].self, from: data)
        else { return }
        corrections = decoded
    }

    func correction(for trackId: String) -> MacAnalysisCorrection? { corrections[trackId] }

    func set(_ correction: MacAnalysisCorrection?, for trackId: String) {
        if let correction, !correction.isEmpty {
            var stamped = correction
            stamped.updatedAt = Date()
            corrections[trackId] = stamped
        } else {
            corrections[trackId] = nil
        }
        persist()
    }

    func removeAll() {
        corrections = [:]
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class MacAnalysisIndex: ObservableObject {
    static let shared = MacAnalysisIndex()

    @Published private(set) var recordsByTrack: [String: [MacAnalysisRecord]] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var maxBytes: Int64 = AnalysisCache.defaultMaxBytes
    @Published private(set) var isTruncated = false

    private var refreshTask: Task<Void, Never>?

    private init() {}

    var rowCount: Int { recordsByTrack.values.reduce(0) { $0 + $1.count } }
    var analysedTrackCount: Int { recordsByTrack.count }

    var allRecords: [MacAnalysisRecord] {
        recordsByTrack.values.flatMap { $0 }.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func records(for trackId: String) -> [MacAnalysisRecord] { recordsByTrack[trackId] ?? [] }

    private static func authority(_ engine: MacAnalysisEngineKind) -> Int {
        switch engine {
        case .userCorrection: return 0
        case .musicUnderstanding: return 1
        case .fftAudioAnalyzer: return 2
        case .genreTaxonomy: return 3
        case .soundCloudWaveform: return 4
        case .other: return 5
        }
    }

    func result(forTrackId trackId: String) -> MacAnalysisResult? {
        var result = MacAnalysisResult()

        if let correction = MacAnalysisCorrectionStore.shared.correction(for: trackId) {
            if let bpm = correction.bpm {
                result.bpm = bpm
                result.bpmEngine = .userCorrection
            }
            if let key = correction.key {
                result.key = key
                result.keyEngine = .userCorrection
            }
            if let genre = correction.genre, !genre.isEmpty {
                result.genre = genre
                result.genreEngine = .userCorrection
            }
        }

        for record in records(for: trackId).sorted(by: { Self.authority($0.engine) < Self.authority($1.engine) }) {
            result.absorb(record)
        }
        return result.isEmpty ? nil : result
    }

    func refresh(limit: Int = 5_000) async {
        refreshTask?.cancel()
        let task = Task { @MainActor in
            isRefreshing = true
            defer { isRefreshing = false }

            let rows = await AnalysisCache.shared.allRecallRows(limit: limit)
            let used = await AnalysisCache.shared.usedBytes
            let max = await AnalysisCache.shared.maxBytes
            guard !Task.isCancelled else { return }

            let localProducerId = AnalysisSyncIdentity.producerId(defaults: .standard)
            var grouped: [String: [MacAnalysisRecord]] = [:]
            for row in rows {
                let producerId = row.producerId ?? localProducerId
                grouped[row.trackId, default: []].append(
                    MacAnalysisRecord(
                        cacheKey: row.cacheKey,
                        trackId: row.trackId,
                        engine: MacAnalysisEngineKind(engineName: row.generation.engine.name),
                        engineVersion: row.generation.engine.version,
                        schemaVersion: row.generation.schemaVersion,
                        byteSize: row.byteSize,
                        producedAt: row.producedAt,
                        lastUsedAt: row.lastAccessedAt,
                        producerId: producerId,
                        isFromThisDevice: producerId == localProducerId,
                        bpm: row.bpm,
                        key: row.key,
                        genre: row.genre,
                        preset: row.fingerprint.preset,
                        bitrate: row.fingerprint.bitrate,
                        codec: row.fingerprint.codec
                    )
                )
            }

            recordsByTrack = grouped
            usedBytes = used
            maxBytes = max
            isTruncated = rows.count >= limit
            lastRefreshedAt = Date()
        }
        refreshTask = task
        await task.value
    }

    func forgetAnalysis(forTrackId trackId: String) async {
        await AnalysisCache.shared.invalidate(trackId: trackId)
        await refresh()
    }

    func forgetEverything() async {
        await AnalysisCache.shared.removeAll()
        await refresh()
    }

    func setBudget(_ bytes: Int64) async {
        await AnalysisCache.shared.setMaxBytes(bytes)
        await refresh()
    }
}

@MainActor
enum MacAnalysisRunner {
    static func analyse(_ track: Track, force: Bool) async {
        AutomaticAnalysisStatus.shared.set(.analysing, for: track.id)
        if force {
            await AnalysisCache.shared.invalidate(trackId: track.id)
        }

        var tags: [String] = []
        if let genre = track.genre, !genre.isEmpty { tags.append(genre) }
        tags.append(contentsOf: track.tags)
        tags.append(track.title)

        var samples: [Float] = []
        if case .ready(let waveform) = WaveformService.shared.state(for: track.id) {
            samples = waveform.samples
        }

        let run = await AnalysisCoordinator.analyze(
            track: track,
            genreField: track.genre,
            tags: tags,
            waveformSamples: samples,
            cache: .shared
        )
        await MacAnalysisIndex.shared.refresh()
        let resolved = MacAnalysisIndex.shared.result(forTrackId: track.id)
        if !run.isEntitled {
            AutomaticAnalysisStatus.shared.set(.notEligible("Analysis isn’t available"), for: track.id)
        } else if resolved?.bpm == nil, resolved?.key == nil {
            let reason = run.outcomes.values.compactMap { outcome -> String? in
                if case .failed(let reason) = outcome { return reason }
                return nil
            }.first ?? "No tempo or musical key could be resolved from this track."
            AutomaticAnalysisStatus.shared.set(.failed(reason), for: track.id)
        } else {
            AutomaticAnalysisStatus.shared.set(.complete, for: track.id)
        }
    }
}

struct LibraryRow: Identifiable {
    let track: Track
    let analysis: MacAnalysisResult?
    let dateAdded: Date

    init(track: Track, analysis: MacAnalysisResult?, dateAdded: Date? = nil) {
        self.track = track
        self.analysis = analysis
        self.dateAdded = dateAdded ?? track.createdAt
    }

    var id: String { track.id }

    var titleKey: String { track.title }
    var artistKey: String { track.user.displayName }
    var genreKey: String { analysis?.genre ?? track.genre ?? "" }

    var isLoadable: Bool { track.mixSource != nil }

    var genreBadge: (value: String, provenance: SCAnalysisProvenance, source: String)? {
        if let resolved = analysis?.genre {
            return (resolved, analysis?.genreProvenance ?? .inferred, (analysis?.genreEngine ?? .genreTaxonomy).explanation)
        }
        if let tag = track.genre, !tag.isEmpty {
            return (tag, .inferred, "SoundCloud's own uploader-set tag. Nothing on this device has confirmed it.")
        }
        return nil
    }
}

struct LibraryRowComparator: SortComparator {
    var key: TrackSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: LibraryRow, _ rhs: LibraryRow) -> ComparisonResult {
        if key == .dateAdded {
            return TrackSort.rank(lhs.dateAdded, rhs.dateAdded, order: order, by: <)
        }
        return TrackSort.compare(
            lhs.track,
            rhs.track,
            key: key,
            order: order,
            lhsAnalysis: lhs.analysis?.summary,
            rhsAnalysis: rhs.analysis?.summary
        )
    }
}

@MainActor
final class MacLibraryModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case liked = "Liked"
        case mine = "My Uploads"
        case friends = "Private Shares"
        case search = "Search"
        var id: String { rawValue }
    }

    @Published private(set) var mode: Mode = .liked
    @Published var filterText = "" {
        didSet {
            guard mode == .search else { return }
            scheduleSearch(filterText)
        }
    }
    @Published var genreFilter: String?

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var likedAtByTrackID: [String: Date] = [:]
    @Published private(set) var analysis: [String: MacAnalysisResult] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private var loadProgress: ProgressManager?
    @Published private(set) var loadedTrackCount = 0

    private func beginLoadProgress() {
        let manager = ProgressManager(totalCount: nil)
        loadProgress = manager
        loadedTrackCount = manager.reporter.completedCount
    }

    private func advanceLoadProgress(by newItems: Int) {
        guard newItems > 0, let loadProgress else { return }
        loadProgress.complete(count: newItems)
        loadedTrackCount = loadProgress.reporter.completedCount
    }
    private var likedPage: Page<Like<Track>>?
    private var minePage: Page<Track>?
    private var friendsPage: Page<LibraryItem>?
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private let cache = LibraryCache.shared

    init(mode: Mode = .liked) {
        self.mode = mode
    }

    private static let cacheDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(cacheDateFormatter)
        return encoder
    }()
    private static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(cacheDateFormatter)
        return decoder
    }()

    private static func cacheSection(for mode: Mode) -> String? {
        switch mode {
        case .liked:  return "liked"
        case .mine:   return "mine"
        case .friends: return "friends-with-a-dj"
        case .search: return nil
        }
    }

    @discardableResult
    private func hydrateFromCache(_ mode: Mode) async -> Bool {
        guard let section = Self.cacheSection(for: mode) else { return false }
        let rows = await cache.loadSection(section)
        guard !rows.isEmpty else { return false }
        let decoded = await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            return rows.compactMap { try? decoder.decode(Track.self, from: $0.payload) }
        }.value
        guard !decoded.isEmpty, !Task.isCancelled, self.mode == mode else { return false }
        tracks = decoded
        if mode == .liked {
            likedAtByTrackID = Dictionary(uniqueKeysWithValues: zip(decoded, rows).compactMap { track, row in
                guard let millis = row.likedAtMillis else { return nil }
                return (track.id, Date(timeIntervalSince1970: Double(millis) / 1000))
            })
        }
        return true
    }

    private func persistCache(_ mode: Mode, tracks: [Track]) async {
        guard let section = Self.cacheSection(for: mode) else { return }
        let rows: [LibraryCache.WriteRow] = tracks.compactMap { track in
            guard let payload = try? Self.cacheEncoder.encode(track) else { return nil }
            let likedAtMillis = mode == .liked
                ? likedAtByTrackID[track.id].map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
                : nil
            return LibraryCache.WriteRow(id: track.id, payload: payload, likedAtMillis: likedAtMillis)
        }
        await cache.replaceSection(section, rows: rows)
    }

    func refreshLikedIndex() async {
        guard mode == .liked else { return }
        let indexed = await LikesSyncEngine.shared.indexedLikes()
        guard !indexed.tracks.isEmpty, !Task.isCancelled, mode == .liked else { return }
        tracks = indexed.tracks
        likedAtByTrackID = indexed.likedAt
        loadedTrackCount = tracks.count
        await refreshAnalysis()
    }

    var canLoadMore: Bool {
        switch mode {
        case .liked: return likedPage?.nextHref != nil
        case .mine: return minePage?.nextHref != nil
        case .friends: return friendsPage?.nextHref != nil
        case .search: return false
        }
    }

    var distinctGenres: [String] {
        let present = tracks.compactMap { analysis[$0.id]?.genre ?? $0.genre }
        return Array(Set(present)).sorted()
    }

    var filteredRows: [LibraryRow] {
        var rows = tracks.map {
            LibraryRow(
                track: $0,
                analysis: analysis[$0.id],
                dateAdded: mode == .liked ? (likedAtByTrackID[$0.id] ?? $0.createdAt) : $0.createdAt
            )
        }

        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty, mode != .search {
            rows = rows.filter {
                $0.titleKey.lowercased().contains(needle) || $0.artistKey.lowercased().contains(needle)
            }
        }
        if let genreFilter {
            rows = rows.filter { $0.genreKey == genreFilter }
        }
        return rows
    }

    func setMode(_ newMode: Mode, currentUserId: String?, isSignedOut: Bool) {
        guard newMode != mode else { return }
        mode = newMode
        tracks = []
        likedAtByTrackID = [:]
        errorMessage = nil
        likedPage = nil
        minePage = nil
        friendsPage = nil
        switch newMode {
        case .liked, .mine, .friends: load(currentUserId: currentUserId, isSignedOut: isSignedOut)
        case .search: break // waits for filterText via scheduleSearch
        }
    }

    func load(currentUserId: String?, isSignedOut: Bool = false) {
        loadTask?.cancel()
        guard !isSignedOut else {
            tracks = []
            errorMessage = nil
            Task { await cache.clearAll() }
            return
        }
        switch mode {
        case .liked:
            beginLoadProgress()
            loadTask = Task {
                await refreshLikedIndex()
                var hydrated = !tracks.isEmpty
                if !hydrated { hydrated = await hydrateFromCache(.liked) }
                guard !Task.isCancelled, self.mode == .liked else { return }
                if hydrated { await refreshAnalysis() }
                isLoading = tracks.isEmpty
                defer { isLoading = false }
                do {
                    let page = try await SoundCloudAPI.shared.getLikedTracks(limit: 100)
                    guard !Task.isCancelled, self.mode == .liked else { return }
                    await LikesSyncEngine.shared.integrate(firstPage: page.collection)
                    await refreshLikedIndex()
                    likedPage = page
                    if tracks.isEmpty { tracks = page.collection.map(\.item) }
                    advanceLoadProgress(by: tracks.count)
                    errorMessage = nil
                    await refreshAnalysis()
                    await persistCache(.liked, tracks: tracks)
                } catch {
                    guard !Task.isCancelled, self.mode == .liked else { return }
                    if tracks.isEmpty {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        case .mine:
            guard let currentUserId else {
                errorMessage = "Sign in on your iPhone and pair it with this Mac to see your uploads. The Mac has no sign-in of its own."
                return
            }
            beginLoadProgress()
            loadTask = Task {
                let hydrated = await hydrateFromCache(.mine)
                guard !Task.isCancelled, self.mode == .mine else { return }
                if hydrated { await refreshAnalysis() }
                isLoading = tracks.isEmpty
                defer { isLoading = false }
                do {
                    let page = try await SoundCloudAPI.shared.getUserTracks(userId: currentUserId, limit: 100)
                    guard !Task.isCancelled, self.mode == .mine else { return }
                    minePage = page
                    tracks = page.collection
                    advanceLoadProgress(by: tracks.count)
                    errorMessage = nil
                    await refreshAnalysis()
                    await persistCache(.mine, tracks: tracks)
                    var cursor = page
                    while cursor.nextHref != nil, !Task.isCancelled, self.mode == .mine {
                        try? await Task.sleep(for: .milliseconds(450))
                        cursor = try await SoundCloudAPI.shared.getNextPage(cursor)
                        minePage = cursor
                        let known = Set(tracks.map(\.id))
                        let additions = cursor.collection.filter { !known.contains($0.id) }
                        tracks.append(contentsOf: additions)
                        advanceLoadProgress(by: additions.count)
                        await persistCache(.mine, tracks: tracks)
                    }
                    await refreshAnalysis()
                } catch {
                    guard !Task.isCancelled, self.mode == .mine else { return }
                    if tracks.isEmpty {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        case .friends:
            guard let currentUserId else {
                errorMessage = "Sign in to see private tracks shared with this account."
                return
            }
            beginLoadProgress()
            loadTask = Task {
                let hydrated = await hydrateFromCache(.friends)
                guard !Task.isCancelled, self.mode == .friends else { return }
                if hydrated { await refreshAnalysis() }
                isLoading = tracks.isEmpty
                defer { isLoading = false }
                do {
                    let page = try await SoundCloudAPI.shared.getLibrary(limit: 100)
                    guard !Task.isCancelled, self.mode == .friends else { return }
                    friendsPage = page
                    let items = page.collection
                    tracks = await Task.detached(priority: .utility) {
                        Self.privateShares(in: items, excludingOwner: currentUserId)
                    }.value
                    advanceLoadProgress(by: tracks.count)
                    errorMessage = nil
                    await refreshAnalysis()
                    await persistCache(.friends, tracks: tracks)
                } catch {
                    guard !Task.isCancelled, self.mode == .friends else { return }
                    if tracks.isEmpty { errorMessage = error.localizedDescription }
                }
            }
        case .search:
            break
        }
    }

    func loadMore() {
        guard !isLoadingMore else { return }
        switch mode {
        case .liked:
            guard let page = likedPage, page.nextHref != nil else { return }
            isLoadingMore = true
            Task {
                defer { isLoadingMore = false }
                do {
                    let next = try await SoundCloudAPI.shared.getNextPage(page)
                    likedPage = next
                    let newItems = next.collection.map(\.item)
                    let known = Set(tracks.map(\.id))
                    let additions = newItems.filter { !known.contains($0.id) }
                    tracks.append(contentsOf: additions)
                    for like in next.collection { likedAtByTrackID[like.item.id] = like.createdAt }
                    await LikesSyncEngine.shared.integrate(firstPage: next.collection)
                    advanceLoadProgress(by: additions.count)
                    await refreshAnalysis()
                    await persistCache(.liked, tracks: tracks)
                } catch {
                }
            }
        case .mine:
            guard let page = minePage, page.nextHref != nil else { return }
            isLoadingMore = true
            Task {
                defer { isLoadingMore = false }
                do {
                    let next = try await SoundCloudAPI.shared.getNextPage(page)
                    minePage = next
                    tracks.append(contentsOf: next.collection)
                    advanceLoadProgress(by: next.collection.count)
                    await refreshAnalysis()
                } catch {}
            }
        case .friends:
            guard let page = friendsPage, page.nextHref != nil,
                  let currentUserId = SoundCloudCredentialSource.shared.currentUser?.id else { return }
            isLoadingMore = true
            Task {
                defer { isLoadingMore = false }
                do {
                    let next = try await SoundCloudAPI.shared.getNextPage(page)
                    friendsPage = next
                    let known = Set(tracks.map(\.id))
                    let items = next.collection
                    let additions = await Task.detached(priority: .utility) {
                        Self.privateShares(in: items, excludingOwner: currentUserId)
                            .filter { !known.contains($0.id) }
                    }.value
                    tracks.append(contentsOf: additions)
                    advanceLoadProgress(by: additions.count)
                    await persistCache(.friends, tracks: tracks)
                    await refreshAnalysis()
                } catch {}
            }
        case .search:
            break
        }
    }

    private nonisolated static func privateShares(in items: [LibraryItem], excludingOwner ownerID: String) -> [Track] {
        items.compactMap(\.track).filter { $0.isPrivate && $0.user.id != ownerID }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tracks = []
            errorMessage = nil
            return
        }
        beginLoadProgress()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let page = try await SoundCloudAPI.shared.searchTracks(query: trimmed)
                guard !Task.isCancelled else { return }
                tracks = page.collection
                advanceLoadProgress(by: tracks.count)
                errorMessage = nil
                await refreshAnalysis()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshAnalysis(rereadStore: Bool = true) async {
        if rereadStore { await MacAnalysisIndex.shared.refresh() }
        var results: [String: MacAnalysisResult] = [:]
        for track in tracks {
            results[track.id] = MacAnalysisIndex.shared.result(forTrackId: track.id)
        }
        analysis = results.compactMapValues { $0 }
    }

}

struct MacLibraryTable: View {
    let rows: [LibraryRow]
    var showsArtwork = true
    var usesCompactRows = false
    let onLoad: (Track, MixEngine.Deck) -> Void
    let onDoubleClick: (Track) -> Void
    var onAnalysisChanged: () -> Void = {}
    var onNearEnd: () -> Void = {}

    @ObservedObject private var analysisWork = AutomaticAnalysisStatus.shared

    @State private var sortOrder = [LibraryRowComparator(key: .dateAdded, order: .reverse)]
    @State private var selection = Set<String>()
    @State private var editingTrackId: String?
    @State private var hoveredTrackID: String?

    private var sortedRows: [LibraryRow] { rows.sorted(using: sortOrder) }

    private static let artworkWarmupCount = 18

    var body: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", sortUsing: LibraryRowComparator(key: .title)) { row in
                titleCell(for: row)
                .libraryRowInteraction(
                    trackID: row.track.id,
                    isHovered: hoveredTrackID == row.track.id,
                    hoveredTrackID: $hoveredTrackID,
                    isSelected: selection.contains(row.track.id),
                    contextTrack: row.track,
                    onEditAnalysis: { onEditAnalysis(row.track.id) },
                    onDoubleClick: { onDoubleClick(row.track) }
                )
                .draggable(MacTrackDragPayload(track: row.track))
                .onAppear {
                    guard sortedRows.suffix(15).contains(where: { $0.id == row.id }) else { return }
                    onNearEnd()
                }
            }
            // Title is the primary scanning column. A low maximum forced wide
            // windows to donate space to metadata while track names still
            // truncated, which looked especially broken in full-screen mode.
            .width(min: 260, ideal: 440, max: 1_000)

            TableColumn("Deck") { row in
                DeckLoadControls(
                    row: row,
                    isHovered: hoveredTrackID == row.track.id,
                    onLoad: onLoad
                )
                    .libraryRowInteraction(
                        trackID: row.track.id,
                        isHovered: hoveredTrackID == row.track.id,
                        hoveredTrackID: $hoveredTrackID,
                        isSelected: selection.contains(row.track.id),
                        contextTrack: row.track,
                        onEditAnalysis: { onEditAnalysis(row.track.id) }
                    )
                    .help("Load \(row.track.title): hover for Deck A or Deck B")
            }
            .width(min: 48, ideal: 52, max: 58)

            TableColumn("Artist", sortUsing: LibraryRowComparator(key: .artist)) { row in
                HStack(spacing: 7) {
                    if showsArtwork {
                        ArtworkThumbnail(
                            url: row.track.user.avatarURL,
                            identity: row.track.user.displayName,
                            size: 22,
                            cornerRadius: 11
                        )
                    }
                    Text(row.track.user.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .libraryRowInteraction(
                    trackID: row.track.id,
                    isHovered: hoveredTrackID == row.track.id,
                    hoveredTrackID: $hoveredTrackID,
                    isSelected: selection.contains(row.track.id),
                    contextTrack: row.track,
                    onEditAnalysis: { onEditAnalysis(row.track.id) }
                )
            }
            .width(min: 100, ideal: 150, max: 280)

            TableColumn("BPM", sortUsing: LibraryRowComparator(key: .bpm)) { row in
                analysisCell(for: row, kind: .bpm)
                .libraryRowInteraction(
                    trackID: row.track.id,
                    isHovered: hoveredTrackID == row.track.id,
                    hoveredTrackID: $hoveredTrackID,
                    isSelected: selection.contains(row.track.id),
                    contextTrack: row.track,
                    onEditAnalysis: { onEditAnalysis(row.track.id) }
                )
                .help(analysisCellHelp(for: row, kind: .bpm))
            }
            .width(min: 58, ideal: 68, max: 82)

            TableColumn("Key", sortUsing: LibraryRowComparator(key: .key)) { row in
                analysisCell(for: row, kind: .key)
                .libraryRowInteraction(
                    trackID: row.track.id,
                    isHovered: hoveredTrackID == row.track.id,
                    hoveredTrackID: $hoveredTrackID,
                    isSelected: selection.contains(row.track.id),
                    contextTrack: row.track,
                    onEditAnalysis: { onEditAnalysis(row.track.id) }
                )
                .help(analysisCellHelp(for: row, kind: .key))
            }
            .width(min: 58, ideal: 68, max: 82)

            TableColumn("Genre", sortUsing: LibraryRowComparator(key: .genre)) { row in
                analysisCell(for: row, kind: .genre)
                    .libraryRowInteraction(
                        trackID: row.track.id,
                        isHovered: hoveredTrackID == row.track.id,
                        hoveredTrackID: $hoveredTrackID,
                        isSelected: selection.contains(row.track.id),
                        contextTrack: row.track,
                        onEditAnalysis: { onEditAnalysis(row.track.id) }
                    )
                    .help(analysisCellHelp(for: row, kind: .genre))
            }
            .width(min: 82, ideal: 112, max: 180)

            TableColumn("Time", sortUsing: LibraryRowComparator(key: .duration)) { row in
                Text(row.track.formattedDuration)
                    .foregroundStyle(.white.opacity(0.82))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .libraryRowInteraction(
                        trackID: row.track.id,
                        isHovered: hoveredTrackID == row.track.id,
                        hoveredTrackID: $hoveredTrackID,
                        isSelected: selection.contains(row.track.id),
                        contextTrack: row.track,
                        onEditAnalysis: { onEditAnalysis(row.track.id) }
                    )
            }
            .width(min: 50, ideal: 56, max: 64)

            TableColumn("Added", sortUsing: LibraryRowComparator(key: .dateAdded)) { row in
                Text(row.dateAdded, style: .date)
                    .foregroundStyle(.white.opacity(0.82))
                    .libraryRowInteraction(
                        trackID: row.track.id,
                        isHovered: hoveredTrackID == row.track.id,
                        hoveredTrackID: $hoveredTrackID,
                        isSelected: selection.contains(row.track.id),
                        contextTrack: row.track,
                        onEditAnalysis: { onEditAnalysis(row.track.id) }
                    )
            }
            .width(min: 78, ideal: 88, max: 112)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .foregroundStyle(.white)
        .environment(\.defaultMinListRowHeight, usesCompactRows && !showsArtwork ? 24 : 36)
        .sheet(item: Binding(get: { editingTrackId.map(IdentifiedString.init) }, set: { editingTrackId = $0?.value })) { wrapped in
            MacAnalysisCorrectionSheet(
                trackId: wrapped.value,
                title: rows.first { $0.track.id == wrapped.value }?.track.title ?? wrapped.value,
                current: MacAnalysisCorrectionStore.shared.correction(for: wrapped.value)
            ) { updated in
                MacAnalysisCorrectionStore.shared.set(updated, for: wrapped.value)
                guard let track = rows.first(where: { $0.track.id == wrapped.value })?.track else {
                    onAnalysisChanged()
                    return
                }
                Task {
                    await AnalysisCache.shared.storeUserCorrection(
                        for: track,
                        bpm: updated?.bpm,
                        key: updated?.key,
                        genre: updated?.genre,
                        updatedAt: updated?.updatedAt ?? Date()
                    )
                    await MacAnalysisIndex.shared.refresh()
                    onAnalysisChanged()
                    await MacSyncCoordinator.shared.runOnce()
                }
            }
        }
        .prefetchArtwork(
            showsArtwork
                ? sortedRows.prefix(Self.artworkWarmupCount).compactMap(\.track.artworkURL)
                : []
        )
    }

    private func onEditAnalysis(_ trackId: String) { editingTrackId = trackId }

    private enum AnalysisColumnKind { case bpm, key, genre }

    @ViewBuilder
    private func analysisCell(for row: LibraryRow, kind: AnalysisColumnKind) -> some View {
        let value: String? = switch kind {
        case .bpm: row.analysis?.bpm.map { String(format: "%.0f", $0) }
        case .key: row.analysis?.key?.label
        case .genre: row.genreBadge?.value
        }
        if let value, !value.isEmpty {
            // Analysis values are ordinary table data, not status badges. Keep
            // them legible on both alternating and selected row backgrounds.
            Text(kind == .genre ? GenrePresentation.displayName(for: value) : value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(analysisValueHelp(for: row, kind: kind, value: value))
        } else {
            if let state = analysisWork.state(for: row.track.id), state == .analysing || state.isQueued {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(state.label)
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .accessibilityLabel(state.label)
            } else {
                Button {
                    if kind == .genre {
                        onEditAnalysis(row.track.id)
                    } else {
                        Task {
                            let state = analysisWork.state(for: row.track.id)
                            await MacAnalysisRunner.analyse(
                                row.track,
                                force: state == .complete || state?.isFailed == true
                            )
                            onAnalysisChanged()
                        }
                    }
                } label: {
                    let state = analysisWork.state(for: row.track.id)
                    let finishedWithoutValue = state == .complete
                    let failed = state?.isFailed == true
                    Label(
                        kind == .genre ? "Set" : (failed ? "Error" : (finishedWithoutValue ? "Retry" : "Analyse")),
                        systemImage: kind == .genre
                            ? "tag"
                            : (failed ? "exclamationmark.triangle" : (finishedWithoutValue ? "arrow.clockwise" : "waveform.badge.magnifyingglass"))
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(failed || finishedWithoutValue ? .orange : .white.opacity(0.76))
                }
                .buttonStyle(.plain)
                .help(analysisActionHelp(for: row, kind: kind))
            }
        }
    }

    private func analysisCellHelp(for row: LibraryRow, kind: AnalysisColumnKind) -> String {
        if let state = analysisWork.state(for: row.track.id) {
            switch state {
            case .notEligible(let reason): return reason
            case .queued, .analysing: return state.label
            case .failed(let reason): return "Analysis failed: \(reason). Click to retry."
            case .complete: break
            }
        }
        return analysisActionHelp(for: row, kind: kind)
    }

    private func analysisActionHelp(for row: LibraryRow, kind: AnalysisColumnKind) -> String {
        switch kind {
        case .bpm: return "Analyse the tempo of \(row.track.title)"
        case .key: return "Analyse the musical key of \(row.track.title)"
        case .genre: return "Set the genre of \(row.track.title)"
        }
    }

    private func analysisValueHelp(for row: LibraryRow, kind: AnalysisColumnKind, value: String) -> String {
        switch kind {
        case .bpm:
            let detail = row.analysis?.bpmEngine?.explanation ?? "Tempo analysis"
            return "\(value) BPM — \(detail)"
        case .key:
            let detail = row.analysis?.keyEngine?.explanation ?? "Musical-key analysis"
            return "Key \(value) — \(detail)"
        case .genre:
            return row.genreBadge?.source ?? "Genre: \(GenrePresentation.displayName(for: value))"
        }
    }

    @ViewBuilder
    private func titleCell(for row: LibraryRow) -> some View {
        HStack(spacing: 10) {
            if showsArtwork {
                ArtworkCell(
                    track: row.track,
                    isAvailable: row.isLoadable,
                    action: { onDoubleClick(row.track) }
                )
            } else {
                RowPlayAffordance(track: row.track, isAvailable: row.isLoadable) {
                    onDoubleClick(row.track)
                }
            }
            Text(row.track.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 8)
        }
    }

    private struct ArtworkCell: View {
        let track: Track
        let isAvailable: Bool
        let action: () -> Void
        @State private var artwork: NSImage?
        @State private var isHovering = false

        private var displayedArtwork: NSImage? {
            if let artwork { return artwork }
            guard let url = track.artworkURL else { return nil }
            return ArtworkCache.shared.cachedImage(for: url, variant: .standard)
        }

        var body: some View {
            Button(action: action) {
                ZStack {
                    SCArtwork(
                        image: displayedArtwork.map { Image(nsImage: $0) },
                        identity: track.title,
                        isAvailable: isAvailable,
                        style: .mac,
                        cornerRadius: 3,
                        usesGeneratedFallback: false
                    )

                    if isHovering, isAvailable {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.black.opacity(0.42))
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .onHover { isHovering = $0 }
            .help(isAvailable ? "Play \(track.title)" : "Not playable")
            .task(id: track.id) {
                guard let url = track.artworkURL else {
                    artwork = nil
                    return
                }
                if let cached = ArtworkCache.shared.cachedImage(for: url, variant: .standard) {
                    artwork = cached
                    return
                }
                artwork = await ArtworkCache.shared.image(for: url, variant: .standard)
            }
        }
    }

    /// Keeps compact rows aligned while preserving a familiar direct play
    /// affordance when artwork has been disabled.
    private struct RowPlayAffordance: View {
        let track: Track
        let isAvailable: Bool
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isHovering && isAvailable ? Color.primary : Color.secondary.opacity(0.58))
                    .frame(width: 22, height: 22)
                    .background(isHovering && isAvailable ? Color.primary.opacity(0.10) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .onHover { isHovering = $0 }
            .help(isAvailable ? "Play" : "Not playable on this account")
        }
    }

    private struct DeckLoadControls: View {
        let row: LibraryRow
        let isHovered: Bool
        let onLoad: (Track, MixEngine.Deck) -> Void

        private let deckAColor = Color(red: 1.00, green: 0.478, blue: 0.157)
        private let deckBColor = Color(red: 0.486, green: 0.455, blue: 1.00)

        var body: some View {
            if row.isLoadable {
                loadableBody
                    .frame(width: 46, height: 30)
            } else {
                Image(systemName: "lock.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.quaternary)
                    .frame(width: 46, height: 30)
                    .help("No playable mix source for this track on this account.")
            }
        }

        @ViewBuilder
        private var loadableBody: some View {
            if isHovered {
                HStack(spacing: 3) {
                    deckButton("A", tint: deckAColor) { onLoad(row.track, .a) }
                    deckButton("B", tint: deckBColor) { onLoad(row.track, .b) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                Button {
                    onLoad(row.track, MacDeckTrackRegistry.shared.nextAvailableDeck())
                } label: {
                    Label("Load", systemImage: "arrow.right.to.line.compact")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, height: 26)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Load \(row.track.title) into the first available deck")
                .help("Load \(row.track.title) into the first available deck (A first)")
            }
        }

        private func deckButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 24)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load \(row.track.title) into Deck \(label)")
            .help("Load \(row.track.title) into Deck \(label)")
        }
    }

    private struct GenreCell: View {
        let row: LibraryRow

        var body: some View {
            let badge = row.genreBadge
            SCAnalysisText(
                kind: .genre,
                value: badge?.value,
                provenance: badge?.provenance ?? .unavailable
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .help(badge?.source ?? "Not analysed, and SoundCloud has no uploader tag for this track.")
        }
    }

}

private extension View {
    /// `Table` supplies selection, but not a useful row-hover surface for
    /// custom SwiftUI cells. Apply the same surface to every column so a row
    /// reads as one normal macOS control, rather than a collection of labels.
    @ViewBuilder
    func libraryRowInteraction(
        trackID: String,
        isHovered: Bool,
        hoveredTrackID: Binding<String?>,
        isSelected: Bool,
        contextTrack: Track? = nil,
        onEditAnalysis: (() -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil
    ) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredTrackID.wrappedValue = trackID
                } else if hoveredTrackID.wrappedValue == trackID {
                    hoveredTrackID.wrappedValue = nil
                }
            }
            .onTapGesture(count: 2) { onDoubleClick?() }
            .contextMenu {
                if let contextTrack {
                    MacTrackContextMenu(track: contextTrack)
                    Divider()
                    Button("Correct Tempo, Key or Genre…") { onEditAnalysis?() }
                }
            }
    }
}

private struct PaneSearchField: View {
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

struct MacLibraryPaneView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacLibraryModel
    @FocusState private var searchFieldFocused: Bool
    @State private var isShowingLikesPolicy = false
    @AppStorage("mac.library.showsArtwork") private var showsArtwork = true
    @AppStorage("mac.library.compactRows") private var usesCompactRows = true

    private let pinnedMode: MacLibraryModel.Mode?

    init(model: MacLibraryModel, pinnedMode: MacLibraryModel.Mode? = nil) {
        self.model = model
        self.pinnedMode = pinnedMode
    }

    var body: some View {
        content
        .toolbar {
            ToolbarItem(id: "library-view", placement: .primaryAction) {
                libraryViewMenu
            }

            ToolbarItem(id: "library-filter", placement: .primaryAction) {
                libraryFilterMenu
            }

            ToolbarItem(id: "library-search", placement: .primaryAction) {
                PaneSearchField(text: $model.filterText, prompt: searchPrompt, isFocused: $searchFieldFocused)
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
            }

            if model.mode == .liked {
                ToolbarItem(id: "library-more", placement: .primaryAction) {
                    libraryMoreMenu
                }
            }
        }
        // The sidebar already names this destination. Giving the detail pane a
        // second navigation title leaves a large, detached "Likes" label
        // behind the toolbar on macOS.
        .navigationTitle("")
        .background(Color.black.opacity(0.001)) // keeps hit-testing full-bleed; near-black comes from the window
        .background(
            Group {
                Button("") { searchFieldFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { searchFieldFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        )
        .task {
            if model.filteredRows.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
        .task(id: model.tracks.map(\.id)) {
            guard model.mode == .liked else { return }
            DownloadManager.shared.applyCollectionPolicy(
                tracks: model.tracks,
                collectionId: CollectionPolicyID.likedTracks
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .likesIndexDidChange)) { _ in
            Task { await model.refreshLikedIndex() }
        }
        .sheet(isPresented: $isShowingLikesPolicy) {
            CollectionPolicyEditor(
                collectionId: CollectionPolicyID.likedTracks,
                collectionName: "Liked Tracks",
                collectionKind: .playlist,
                tracks: model.tracks,
                applier: DownloadManager.shared
            )
        }
    }

    private var searchPrompt: String {
        switch model.mode {
        case .search: return "Search SoundCloud"
        case .liked: return "Filter Liked Tracks"
        case .mine: return "Filter My Uploads"
        case .friends: return "Filter Private Shares"
        }
    }

    private var headerSubtitle: String {
        let count = model.filteredRows.count
        let countText = "\(count) track\(count == 1 ? "" : "s")"
        let query = model.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return countText }
        return "\(countText) · Showing results for \u{201c}\(query)\u{201d}"
    }

    private var libraryViewMenu: some View {
        Menu {
            Toggle(isOn: $showsArtwork) {
                Label("Show Artwork", systemImage: "photo")
            }
            Toggle(isOn: $usesCompactRows) {
                Label("Compact Rows", systemImage: "rectangle.compress.vertical")
            }
            .disabled(showsArtwork)
        } label: {
            Image(systemName: "rectangle.grid.1x2")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .frame(width: 34, height: 34)
        .help("View options")
    }

    private var libraryFilterMenu: some View {
        Menu {
            Button {
                model.genreFilter = nil
            } label: {
                Label("All Genres", systemImage: model.genreFilter == nil ? "checkmark" : "line.3.horizontal.decrease")
            }
            if model.distinctGenres.isEmpty {
                Divider()
                Text("No genres in this view")
            } else {
                Divider()
                ForEach(model.distinctGenres, id: \.self) { genre in
                    Button {
                        model.genreFilter = genre
                    } label: {
                        Label(
                            GenrePresentation.displayName(for: genre),
                            systemImage: model.genreFilter == genre ? "checkmark" : "music.note"
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .frame(width: 34, height: 34)
        .help("Filter by genre")
    }

    private var libraryMoreMenu: some View {
        Menu {
            Button {
                playLibrary(shuffled: false)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(playableTracks.isEmpty)

            Button {
                playLibrary(shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(playableTracks.isEmpty)

            Button {
                for track in playableTracks { PlayerService.shared.addToQueue(track) }
            } label: {
                Label("Add All to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .disabled(playableTracks.isEmpty)

            Divider()

            Button {
                model.load(
                    currentUserId: credentials.currentUser?.id,
                    isSignedOut: credentials.isSignedOut
                )
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                isShowingLikesPolicy = true
            } label: {
                Label("Download Settings…", systemImage: "arrow.down.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .frame(width: 34, height: 34)
        .help("More library actions")
    }

    private var playableTracks: [Track] {
        model.filteredRows.map(\.track).filter { $0.streamURL != nil }
    }

    private func playLibrary(shuffled: Bool) {
        var tracks = playableTracks
        if shuffled { tracks.shuffle() }
        guard let first = tracks.first else { return }
        play(first, in: tracks)
    }

    private func play(_ track: Track, in tracks: [Track]? = nil) {
        let queue = tracks ?? playableTracks
        guard queue.contains(where: { $0.id == track.id }) else { return }
        Task {
            await PlayerService.shared.play(
                track,
                in: queue,
                collectionId: model.mode == .liked ? CollectionPolicyID.likedTracks : nil
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if credentials.isSignedOut {
            MacSignedOutEmptyState(
                title: pinnedMode == .liked ? "Likes Need an Account" : "Library Needs an Account",
                message: pinnedMode == .liked
                    ? "Sign in to see the tracks you've liked. Search works without an account."
                    : "Sign in to see your library. Search works without an account.",
                browsableRoute: .search
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading, model.filteredRows.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage, model.filteredRows.isEmpty {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load Library",
                message: errorMessage,
                actionTitle: "Try Again",
                action: { model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut) },
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredRows.isEmpty {
            SCEmptyState(
                icon: "music.note.list",
                title: emptyTitle,
                message: emptyDescription,
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                MacLibraryTable(
                    rows: model.filteredRows,
                    showsArtwork: showsArtwork,
                    usesCompactRows: usesCompactRows,
                    onLoad: { track, deck in
                        Task { try? await MacMixLoader.load(track, into: deck) }
                    },
                    onDoubleClick: { track in
                        play(track)
                    },
                    onAnalysisChanged: {
                        Task { await model.refreshAnalysis(rereadStore: false) }
                    },
                    onNearEnd: { model.loadMore() }
                )
            }
        }
    }

    private var emptyTitle: String {
        switch model.mode {
        case .search: return model.filterText.isEmpty ? "Search SoundCloud" : "No Results"
        case .liked: return "No Liked Tracks"
        case .mine: return "No Uploads"
        case .friends: return "No Private Shares"
        }
    }

    private var emptyDescription: String {
        switch model.mode {
        case .search: return model.filterText.isEmpty ? "Type to search SoundCloud's full catalogue." : "Try a different search."
        case .liked: return "Tracks you like on SoundCloud show up here."
        case .mine: return "Tracks this account has uploaded show up here."
        case .friends: return "Private tracks shared with this SoundCloud account appear here when SoundCloud includes them in your library."
        }
    }
}

struct MacLibraryBrowserView: View {
    let onLoad: (Track, MixEngine.Deck) -> Void

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MacLibraryModel()
    @AppStorage("mac.library.showsArtwork") private var showsArtwork = true
    @AppStorage("mac.library.compactRows") private var usesCompactRows = true

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            if credentials.isSignedOut, model.mode != .search {
                model.setMode(.search, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
            if model.filteredRows.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
    }

    private var modeBinding: Binding<MacLibraryModel.Mode> {
        Binding(
            get: { model.mode },
            set: { model.setMode($0, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut) }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Load Track").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Picker("", selection: modeBinding) {
                ForEach(MacLibraryModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            SheetSearchField(
                text: $model.filterText,
                prompt: model.mode == .search ? "Search SoundCloud" : "Filter"
            )
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if credentials.isSignedOut, model.mode != .search {
            SCEmptyState(
                icon: "person.crop.circle.badge.xmark",
                title: model.mode == .liked ? "Likes Need an Account" : "Uploads Need an Account",
                message: "Switch to Search above to browse SoundCloud without an account.",
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading, model.filteredRows.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage, model.filteredRows.isEmpty {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load Tracks",
                message: errorMessage,
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredRows.isEmpty {
            SCEmptyState(
                icon: "music.note.list",
                title: model.mode == .search ? "No Results" : "No Liked Tracks",
                message: model.mode == .search ? "Try a different search." : "Tracks you like on SoundCloud show up here.",
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MacLibraryTable(
                rows: model.filteredRows,
                showsArtwork: showsArtwork,
                usesCompactRows: usesCompactRows,
                onLoad: { track, deck in onLoad(track, deck) },
                onDoubleClick: { track in onLoad(track, MacDeckTrackRegistry.shared.nextAvailableDeck()) }
            )
        }
    }
}

private struct SheetSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
