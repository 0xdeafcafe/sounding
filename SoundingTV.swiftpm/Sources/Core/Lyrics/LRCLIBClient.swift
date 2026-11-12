import Foundation

protocol LyricsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionLyricsTransport: LyricsTransport {
    let session: URLSession

    init(session: URLSession = URLSessionLyricsTransport.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum LyricsError: Error, Equatable, Sendable {
    case offline
    case rateLimited(until: Date)
    case unavailable
}

// MARK: - Request gate

actor LyricsRequestGate {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let spacing: ClosedRange<TimeInterval>
    private let jitter: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private let sleeper: Sleeper
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastFinished: Date?
    private(set) var blockedUntil: Date?

    init(
        spacing: ClosedRange<TimeInterval> = 0.2...0.5,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    ) {
        self.spacing = spacing
        self.jitter = jitter
        self.now = now
        self.sleeper = sleeper
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if let blockedUntil, blockedUntil > now() { throw LyricsError.rateLimited(until: blockedUntil) }
        await acquire()
        defer { release() }
        if let blockedUntil, blockedUntil > now() { throw LyricsError.rateLimited(until: blockedUntil) }
        if let lastFinished {
            let gap = spacing.lowerBound + (spacing.upperBound - spacing.lowerBound) * jitter()
            let wait = gap - now().timeIntervalSince(lastFinished)
            if wait > 0 { try await sleeper(wait) }
        }
        try Task.checkCancellation()
        return try await operation()
    }

    func noteRetryAfter(_ seconds: TimeInterval) -> Date {
        let base = max(1, seconds)
        let until = now().addingTimeInterval(base * (1 + 0.3 * jitter()))
        blockedUntil = max(blockedUntil ?? .distantPast, until)
        return blockedUntil ?? until
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        lastFinished = now()
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Records

struct LRCLIBRecord: Decodable, Equatable, Sendable {
    var id: Int
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var hasWordSync: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
    var lyricsfile: String?

    var lyrics: Lyrics? {
        var body: LyricsBody?
        if instrumental == true {
            body = .instrumental
        } else {
            let document = (hasWordSync == true || syncedLyrics?.isEmpty != false) ? lyricsfile.flatMap(LyricsfileParser.parse) : nil
            if let document, document.lines.contains(where: \.hasWordTiming) {
                body = .synced(document.lines)
            } else if let synced = syncedLyrics.map(LRCParser.parse), synced.contains(where: { !$0.isBlank }) {
                body = .synced(synced)
            } else if let document, !document.lines.isEmpty {
                body = .synced(document.lines)
            } else if let plain = LRCLIBRecord.plainLines(plainLyrics ?? document?.plain) {
                body = .plain(plain)
            } else if document?.instrumental == true {
                body = .instrumental
            }
        }
        guard let body else { return nil }
        return Lyrics(body: body, recordID: id, trackName: trackName, artistName: artistName)
    }

    func lyrics(allowingSync: Bool) -> Lyrics? {
        guard let lyrics else { return nil }
        guard !allowingSync, case .synced(let lines) = lyrics.body else { return lyrics }
        let text = plainLyrics ?? lines.map(\.text).joined(separator: "\n")
        guard let plain = LRCLIBRecord.plainLines(text) else { return nil }
        return Lyrics(body: .plain(plain), recordID: id, trackName: trackName, artistName: artistName)
    }

    static func plainLines(_ text: String?) -> [String]? {
        guard let text else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var trimmed = Array(lines.drop(while: \.isEmpty))
        while trimmed.last?.isEmpty == true { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct LRCLIBSummary: Decodable, Equatable, Sendable {
    var id: Int
    var trackName: String
    var artistName: String
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var hasWordSync: Bool?
    var hasPlainLyrics: Bool?
    var hasSyncedLyrics: Bool?

    init(id: Int, trackName: String, artistName: String, albumName: String? = nil, duration: Double?,
         instrumental: Bool? = false, hasWordSync: Bool? = false, hasPlainLyrics: Bool? = true, hasSyncedLyrics: Bool? = true) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.hasWordSync = hasWordSync
        self.hasPlainLyrics = hasPlainLyrics
        self.hasSyncedLyrics = hasSyncedLyrics
    }

    init(record: LRCLIBRecord) {
        self.init(
            id: record.id,
            trackName: record.trackName ?? "",
            artistName: record.artistName ?? "",
            albumName: record.albumName,
            duration: record.duration,
            instrumental: record.instrumental,
            hasWordSync: record.hasWordSync,
            hasPlainLyrics: record.plainLyrics?.isEmpty == false,
            hasSyncedLyrics: record.syncedLyrics?.isEmpty == false
        )
    }
}

enum LyricsFit: Equatable, Sendable {
    case synced
    case plainOnly
}

struct LyricsCandidateScore: Equatable, Sendable {
    var value: Double
    var fit: LyricsFit
}

enum LyricsCandidateRanker {
    static let durationTolerance: Double = 3
    static let editWindow: Double = 90
    static let editRatio = 0.8
    static let minimumTitle = 0.6
    static let minimumArtist = 0.5

    static func durationFit(_ candidate: Double?, wanted: Int?) -> (fit: LyricsFit, score: Double)? {
        guard let wanted, let candidate, candidate > 0 else { return (.synced, 0.5) }
        let difference = abs(candidate - Double(wanted))
        if difference <= durationTolerance { return (.synced, 1 - difference / durationTolerance) }
        guard difference <= max(editWindow, min(candidate, Double(wanted)) * editRatio) else { return nil }
        return (.plainOnly, -min(1, difference / 300))
    }

    static func nameScore(track: String, artist: String, pairs: [LyricsNamePair]) -> Double? {
        let candidateBase = LyricsText.baseTitle(track)
        let candidatePrimary = LyricsText.primaryArtist(artist)
        var best: Double?
        for pair in pairs {
            let title = max(
                LyricsText.similarity(track, pair.track),
                LyricsText.similarity(LyricsText.removeFeaturing(track), LyricsText.removeFeaturing(pair.track)),
                LyricsText.similarity(candidateBase, LyricsText.baseTitle(pair.track)) * 0.95
            )
            let artistScore = max(
                LyricsText.similarity(artist, pair.artist),
                LyricsText.similarity(candidatePrimary, LyricsText.primaryArtist(pair.artist))
            )
            guard title >= minimumTitle, artistScore >= minimumArtist else { continue }
            best = max(best ?? 0, title * 3 + artistScore * 2)
        }
        return best
    }

    static func score(_ summary: LRCLIBSummary, for plan: LyricsQueryPlan) -> LyricsCandidateScore? {
        guard let duration = durationFit(summary.duration, wanted: plan.duration),
              let names = nameScore(track: summary.trackName, artist: summary.artistName, pairs: plan.pairs) else { return nil }
        let otherVersion = plan.isVersion && LyricsText.removeVersion(summary.trackName) == summary.trackName
        let fit: LyricsFit = otherVersion ? .plainOnly : duration.fit
        var score = names + duration.score
        if fit == .synced {
            if summary.hasSyncedLyrics == true { score += 1 }
            if summary.hasWordSync == true { score += 0.5 }
        }
        if summary.hasPlainLyrics == true || summary.hasSyncedLyrics == true { score += 0.2 }
        if summary.instrumental == true { score -= 0.5 }
        if let album = plan.primary.album, let candidate = summary.albumName, LyricsText.similarity(album, candidate) >= 0.8 {
            score += 0.3
        }
        return LyricsCandidateScore(value: score, fit: fit)
    }

    static func score(_ summary: LRCLIBSummary, for signature: LyricsSignature) -> Double? {
        score(summary, for: LyricsQueryPlan(signature: signature))?.value
    }

    static func best(_ summaries: [LRCLIBSummary], for plan: LyricsQueryPlan) -> (summary: LRCLIBSummary, fit: LyricsFit)? {
        summaries
            .compactMap { summary in score(summary, for: plan).map { (summary, $0) } }
            .max { $0.1.value < $1.1.value }
            .map { ($0.0, $0.1.fit) }
    }

    static func best(_ summaries: [LRCLIBSummary], for signature: LyricsSignature) -> LRCLIBSummary? {
        best(summaries, for: LyricsQueryPlan(signature: signature))?.summary
    }
}

// MARK: - Client

enum LyricsLookup: Codable, Equatable, Sendable {
    case found(Lyrics)
    case notFound
}

actor LRCLIBClient {
    static let shared = LRCLIBClient()

    static let host = URL(string: "https://lrclib.net")!

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Sounding/\(version) (https://sounding.forbes.red)"
    }()

    private let transport: LyricsTransport
    let gate: LyricsRequestGate
    private let decoder = JSONDecoder()
    private(set) var requestLog: [String] = []

    init(transport: LyricsTransport = URLSessionLyricsTransport(), gate: LyricsRequestGate = LyricsRequestGate()) {
        self.transport = transport
        self.gate = gate
    }

    func lookup(_ source: LyricsTrackInfo) async throws -> LyricsLookup {
        guard let plan = LyricsSignatureDeriver.plan(for: source) else { return .notFound }
        return try await lookup(plan)
    }

    func lookup(_ plan: LyricsQueryPlan) async throws -> LyricsLookup {
        var sent = Set<String>()
        let steps: [(path: String, query: [URLQueryItem])] = [
            ("/api/get", Self.getQuery(plan.primary, includeDuration: true)),
            ("/api/get", Self.getQuery(plan.base, includeDuration: false)),
            ("/api/search", [URLQueryItem(name: "track_name", value: plan.base.track), URLQueryItem(name: "artist_name", value: plan.base.artist)]),
            ("/api/search", [URLQueryItem(name: "q", value: plan.freeText)]),
        ]
        for step in steps where sent.insert(step.path + "?" + step.query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")).inserted {
            let lyrics = step.path == "/api/get"
                ? try await get(query: step.query, plan: plan)
                : try await search(query: step.query, plan: plan)
            if let lyrics { return .found(lyrics) }
        }
        return .notFound
    }

    static func getQuery(_ signature: LyricsSignature, includeDuration: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "track_name", value: signature.track),
            URLQueryItem(name: "artist_name", value: signature.artist),
        ]
        if includeDuration, let duration = signature.duration, (1...3600).contains(duration) {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        return items
    }

    private func get(query: [URLQueryItem], plan: LyricsQueryPlan) async throws -> Lyrics? {
        guard let data = try await fetch(path: "/api/get", query: query),
              let record = try? decoder.decode(LRCLIBRecord.self, from: data),
              let score = LyricsCandidateRanker.score(LRCLIBSummary(record: record), for: plan) else { return nil }
        return record.lyrics(allowingSync: score.fit == .synced)
    }

    private func search(query: [URLQueryItem], plan: LyricsQueryPlan) async throws -> Lyrics? {
        guard let data = try await fetch(path: "/api/search", query: query),
              let records = try? decoder.decode([LRCLIBRecord].self, from: data) else { return nil }
        let usable = records.filter { $0.lyrics != nil }
        guard let best = LyricsCandidateRanker.best(usable.map(LRCLIBSummary.init(record:)), for: plan),
              let record = usable.first(where: { $0.id == best.summary.id }) else { return nil }
        return record.lyrics(allowingSync: best.fit == .synced)
    }

    private func fetch(path: String, query: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents(url: Self.host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        let transport = self.transport
        let prepared = request
        requestLog.append(path)
        let outcome: (Data, HTTPURLResponse)
        do {
            outcome = try await gate.run { try await transport.send(prepared) }
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw LyricsError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw LyricsError.unavailable
            }
        }
        let (data, response) = outcome
        switch response.statusCode {
        case 200:
            let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            guard type.contains("json") else {
                throw LyricsError.unavailable
            }
            return data
        case 404:
            return nil
        case 429, 503:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? (response.statusCode == 429 ? 60 : 5)
            let until = await gate.noteRetryAfter(retry)
            throw LyricsError.rateLimited(until: until)
        default:
            throw LyricsError.unavailable
        }
    }
}
