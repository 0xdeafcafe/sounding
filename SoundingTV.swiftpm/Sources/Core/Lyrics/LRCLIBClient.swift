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

enum LyricsCandidateRanker {
    static let durationTolerance: Double = 2
    static let minimumTitle = 0.6
    static let minimumArtist = 0.5

    static func score(_ summary: LRCLIBSummary, for signature: LyricsSignature) -> Double? {
        var durationScore = 0.0
        if let wanted = signature.duration {
            guard let duration = summary.duration else { return nil }
            let difference = abs(duration - Double(wanted))
            guard difference <= durationTolerance else { return nil }
            durationScore = 1 - difference / durationTolerance
        }
        let title = max(
            LyricsText.similarity(summary.trackName, signature.track),
            LyricsText.similarity(LyricsText.removeFeaturing(summary.trackName), LyricsText.removeFeaturing(signature.track))
        )
        let artist = max(
            LyricsText.similarity(summary.artistName, signature.artist),
            LyricsText.similarity(LyricsText.primaryArtist(summary.artistName), LyricsText.primaryArtist(signature.artist))
        )
        guard title >= minimumTitle, artist >= minimumArtist else { return nil }
        var score = title * 3 + artist * 2 + durationScore
        if summary.hasSyncedLyrics == true { score += 1 }
        if summary.hasWordSync == true { score += 0.5 }
        if summary.hasPlainLyrics == true { score += 0.2 }
        if summary.instrumental == true { score -= 0.5 }
        if let album = signature.album, let candidate = summary.albumName, LyricsText.similarity(album, candidate) >= 0.8 {
            score += 0.3
        }
        return score
    }

    static func best(_ summaries: [LRCLIBSummary], for signature: LyricsSignature) -> LRCLIBSummary? {
        summaries
            .compactMap { summary in score(summary, for: signature).map { (summary, $0) } }
            .max { $0.1 < $1.1 }?.0
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
        let candidates = LyricsSignatureDeriver.candidates(for: source)
        guard let primary = candidates.first else { return .notFound }
        for candidate in candidates {
            if let record = try await get(candidate), let lyrics = record.lyrics {
                return .found(lyrics)
            }
        }
        if let lyrics = try await searchFallback(primary) {
            return .found(lyrics)
        }
        return .notFound
    }

    func get(_ signature: LyricsSignature) async throws -> LRCLIBRecord? {
        var items = [
            URLQueryItem(name: "track_name", value: signature.track),
            URLQueryItem(name: "artist_name", value: signature.artist),
        ]
        if let album = signature.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = signature.duration, (1...3600).contains(duration) {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        guard let data = try await fetch(path: "/api/get", query: items) else { return nil }
        return try? decoder.decode(LRCLIBRecord.self, from: data)
    }

    func get(id: Int) async throws -> LRCLIBRecord? {
        guard let data = try await fetch(path: "/api/get/\(id)", query: []) else { return nil }
        return try? decoder.decode(LRCLIBRecord.self, from: data)
    }

    private func searchFallback(_ signature: LyricsSignature) async throws -> Lyrics? {
        let query = [
            URLQueryItem(name: "track_name", value: signature.track),
            URLQueryItem(name: "artist_name", value: signature.artist),
        ]
        let summaries: [LRCLIBSummary]?
        do {
            summaries = try await fetch(path: "/api/v2/search", query: query, tolerateFailure: true)
                .flatMap { try? decoder.decode([LRCLIBSummary].self, from: $0) }
        } catch LyricsError.unavailable {
            summaries = nil
        }
        if let summaries {
            guard let best = LyricsCandidateRanker.best(summaries, for: signature) else { return nil }
            return try await get(id: best.id)?.lyrics
        }
        guard let data = try await fetch(path: "/api/search", query: query),
              let records = try? decoder.decode([LRCLIBRecord].self, from: data) else { return nil }
        guard let best = LyricsCandidateRanker.best(records.map(LRCLIBSummary.init(record:)), for: signature) else { return nil }
        return records.first(where: { $0.id == best.id })?.lyrics
    }

    private func fetch(path: String, query: [URLQueryItem], tolerateFailure: Bool = false) async throws -> Data? {
        var components = URLComponents(url: Self.host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
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
                if tolerateFailure { return nil }
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
            if tolerateFailure { return nil }
            throw LyricsError.unavailable
        }
    }
}
