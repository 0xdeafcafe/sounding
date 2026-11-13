import Foundation
import AVFoundation
import Combine
import Observation
import ShazamKit

struct IdentifiedSong: Codable, Identifiable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable {
        case around
        case mix
    }

    var id: UUID
    var title: String
    var artist: String?
    var artworkURL: URL?
    var appleMusicURL: URL?
    var webURL: URL?
    var shazamID: String?
    var isrc: String?
    var identifiedAt: Date
    var origin: Origin
    var mixTitle: String?
    var mixTrackID: String?
    var mixPosition: TimeInterval?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String? = nil,
        artworkURL: URL? = nil,
        appleMusicURL: URL? = nil,
        webURL: URL? = nil,
        shazamID: String? = nil,
        isrc: String? = nil,
        identifiedAt: Date = Date(),
        origin: Origin = .around,
        mixTitle: String? = nil,
        mixTrackID: String? = nil,
        mixPosition: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist.flatMap { $0.isEmpty ? nil : $0 }
        self.artworkURL = artworkURL
        self.appleMusicURL = appleMusicURL
        self.webURL = webURL
        self.shazamID = shazamID
        self.isrc = isrc
        self.identifiedAt = identifiedAt
        self.origin = origin
        self.mixTitle = mixTitle
        self.mixTrackID = mixTrackID
        self.mixPosition = mixPosition
    }

    init?(mediaItem: SHMediaItem, origin: Origin = .around, identifiedAt: Date = Date()) {
        guard let title = mediaItem.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        self.init(
            title: title,
            artist: mediaItem.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
            artworkURL: mediaItem.artworkURL,
            appleMusicURL: mediaItem.appleMusicURL,
            webURL: mediaItem.webURL,
            shazamID: mediaItem.shazamID,
            isrc: mediaItem.isrc,
            identifiedAt: identifiedAt,
            origin: origin
        )
    }

    init(match: SetlistShazamScanner.Match, mix: Track, at position: TimeInterval, identifiedAt: Date = Date()) {
        self.init(
            title: match.title,
            artist: match.artist,
            artworkURL: match.artworkURL,
            appleMusicURL: match.appleMusicURL,
            webURL: match.webURL,
            shazamID: match.shazamId,
            isrc: match.isrc,
            identifiedAt: identifiedAt,
            origin: .mix,
            mixTitle: mix.title,
            mixTrackID: mix.id,
            mixPosition: position
        )
    }

    var artIdentity: String { shazamID ?? "\(title)|\(artist ?? "")" }

    var searchQuery: String {
        [artist, title].compactMap { $0 }.joined(separator: " ")
    }

    var shareText: String {
        guard let artist else { return title }
        return "\(title) by \(artist)"
    }

    var shareURL: URL? { appleMusicURL ?? webURL }

    var caption: String {
        if origin == .mix, let mixTitle {
            guard let mixPosition else { return "In \(mixTitle)" }
            return "In \(mixTitle) at \(Self.clock(mixPosition))"
        }
        return identifiedAt.formatted(.relative(presentation: .named))
    }

    func isSameSong(as other: IdentifiedSong) -> Bool {
        if let shazamID, let otherID = other.shazamID { return shazamID == otherID }
        return IdentifiedSongMatching.fold(title) == IdentifiedSongMatching.fold(other.title)
            && IdentifiedSongMatching.fold(artist ?? "") == IdentifiedSongMatching.fold(other.artist ?? "")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

@MainActor
final class IdentifiedSongHistory: ObservableObject {
    static let shared = IdentifiedSongHistory()
    static let storageKey = "red.forbes.sounding.synced.identifiedSongs.v1"
    static let limit = 50
    private static let repeatWindow: TimeInterval = 15 * 60

    @Published private(set) var songs: [IdentifiedSong] = []

    private let defaults: UserDefaults
    private var storedData: Data?
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .sounding) {
        self.defaults = defaults
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func record(_ song: IdentifiedSong) {
        var next = songs
        if let latest = next.first,
           latest.isSameSong(as: song),
           song.identifiedAt.timeIntervalSince(latest.identifiedAt) < Self.repeatWindow {
            next.removeFirst()
        }
        next.insert(song, at: 0)
        save(Array(next.prefix(Self.limit)))
    }

    func remove(_ song: IdentifiedSong) {
        save(songs.filter { $0.id != song.id })
    }

    func remove(atOffsets offsets: IndexSet) {
        var next = songs
        for index in offsets.sorted(by: >) where next.indices.contains(index) {
            next.remove(at: index)
        }
        save(next)
    }

    func clear() {
        save([])
    }

    private func reload() {
        let data = defaults.data(forKey: Self.storageKey)
        guard data != storedData else { return }
        storedData = data
        let decoded = data.flatMap { try? JSONDecoder().decode([IdentifiedSong].self, from: $0) } ?? []
        let sorted = decoded.sorted { $0.identifiedAt > $1.identifiedAt }
        if sorted != songs { songs = sorted }
    }

    private func save(_ next: [IdentifiedSong]) {
        songs = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        storedData = data
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum SongIdentifierFailure: Equatable, Sendable {
    case microphoneDenied
    case unavailable

    var title: String {
        switch self {
        case .microphoneDenied: "Microphone Is Off"
        case .unavailable: "Couldn’t Listen"
        }
    }

    var message: String {
        switch self {
        case .microphoneDenied: "Allow Sounding to use the microphone in Settings, then try again."
        case .unavailable: "Check your connection and try again."
        }
    }
}

enum SongIdentifierState: Equatable, Sendable {
    case idle
    case listening
    case matched(IdentifiedSong)
    case noMatch
    case failed(SongIdentifierFailure)
}

enum SongIdentifierMicrophone {
    nonisolated static var isDenied: Bool {
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
        #elseif os(iOS) || os(watchOS)
        return AVAudioApplication.shared.recordPermission == .denied
        #else
        return false
        #endif
    }
}

@MainActor
@Observable
final class SongIdentifier {
    private(set) var state: SongIdentifierState = .idle
    @ObservationIgnored private var session: SHManagedSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let history: IdentifiedSongHistory

    init(history: IdentifiedSongHistory = .shared) {
        self.history = history
    }

    var isListening: Bool { state == .listening }

    var song: IdentifiedSong? {
        if case .matched(let song) = state { return song }
        return nil
    }

    func start() {
        endSession()
        guard !SongIdentifierMicrophone.isDenied else {
            state = .failed(.microphoneDenied)
            return
        }
        let session = SHManagedSession()
        self.session = session
        state = .listening
        task = Task { [weak self] in
            let outcome = await Self.listen(with: session)
            guard !Task.isCancelled, let self, self.session === session else { return }
            self.session = nil
            self.task = nil
            if case .matched(let song) = outcome { self.history.record(song) }
            self.state = outcome
        }
    }

    func stop() {
        guard isListening else { return }
        endSession()
        state = .idle
    }

    func reset() {
        endSession()
        state = .idle
    }

    private func endSession() {
        task?.cancel()
        task = nil
        session?.cancel()
        session = nil
    }

    nonisolated private static func listen(with session: SHManagedSession) async -> SongIdentifierState {
        await session.prepare()
        switch await session.result() {
        case .match(let match):
            guard let item = match.mediaItems.first,
                  let song = IdentifiedSong(mediaItem: item) else { return .noMatch }
            return .matched(song)
        case .noMatch:
            return .noMatch
        case .error:
            return .failed(SongIdentifierMicrophone.isDenied ? .microphoneDenied : .unavailable)
        }
    }
}

enum IdentifiedSongMatching {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rank(_ tracks: [Track], for song: IdentifiedSong) -> [Track] {
        let title = fold(song.title)
        let artist = song.artist.map(fold)
        let scored = tracks.enumerated().map { index, track -> (Int, Int, Track) in
            let trackTitle = fold(track.title)
            let uploader = fold(track.user.displayName)
            var score = 0
            if trackTitle == title { score += 4 } else if trackTitle.contains(title) { score += 2 }
            if let artist, !artist.isEmpty {
                if uploader == artist { score += 3 } else if uploader.contains(artist) || trackTitle.contains(artist) { score += 2 }
            }
            if track.streamURL != nil { score += 1 }
            return (score, index, track)
        }
        return scored
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }

    static func message(for error: Error) -> String {
        switch error as? APIError {
        case .rateLimited?, .temporarilyBlocked?:
            return "SoundCloud is limiting requests. Try again in a few minutes."
        case .unauthorized?:
            return "Sign in to SoundCloud to search."
        default:
            return "Couldn’t reach SoundCloud. Check your connection and try again."
        }
    }
}

@MainActor
@Observable
final class IdentifiedSongMatches {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    static let shownCount = 5

    let song: IdentifiedSong
    private(set) var phase: Phase = .idle
    private(set) var tracks: [Track] = []
    private(set) var liked: Set<String> = []
    private(set) var updating: Set<String> = []
    private(set) var likeError: String?

    init(song: IdentifiedSong) {
        self.song = song
    }

    var best: Track? { tracks.first }

    var isBestLiked: Bool { best.map { liked.contains($0.id) } ?? false }

    func isLiked(_ track: Track) -> Bool { liked.contains(track.id) }

    func isUpdating(_ track: Track) -> Bool { updating.contains(track.id) }

    func load(force: Bool = false) async {
        guard phase != .loading else { return }
        if phase == .loaded, !force { return }
        phase = .loading
        do {
            let page = try await SoundCloudAPI.shared.searchTracks(query: song.searchQuery, limit: 20)
            let ranked = IdentifiedSongMatching.rank(page.collection, for: song)
            tracks = Array(ranked.prefix(Self.shownCount))
            liked = Set(tracks.filter(\.userFavorite).map(\.id))
            phase = .loaded
        } catch {
            phase = .failed(IdentifiedSongMatching.message(for: error))
        }
    }

    func toggleLike(_ track: Track) async {
        guard !updating.contains(track.id) else { return }
        let wantsLike = !liked.contains(track.id)
        updating.insert(track.id)
        likeError = nil
        if wantsLike { liked.insert(track.id) } else { liked.remove(track.id) }
        do {
            if wantsLike {
                try await SoundCloudAPI.shared.likeTrack(track)
            } else {
                try await SoundCloudAPI.shared.unlikeTrack(track)
            }
        } catch {
            if wantsLike { liked.remove(track.id) } else { liked.insert(track.id) }
            likeError = IdentifiedSongMatching.message(for: error)
        }
        updating.remove(track.id)
    }

    @discardableResult
    func addBestToLibrary() async -> Bool {
        if phase != .loaded { await load() }
        guard let best else { return false }
        if !liked.contains(best.id) { await toggleLike(best) }
        return liked.contains(best.id)
    }
}

actor SetlistShazamScanner {
    struct Match: Sendable {
        let title: String
        let artist: String?
        let shazamId: String?
        let artworkURL: URL?
        let appleMusicURL: URL?
        let webURL: URL?
        let isrc: String?
        let queryStartSeconds: TimeInterval
        let matchOffset: TimeInterval
        let confidence: Double
    }

    private struct Query {
        let signature: SHSignature
        let startSeconds: TimeInterval
    }

    private static let windowSeconds: TimeInterval = 12

    func match(source: any SetlistAudioSource, at position: TimeInterval, retryNoMatch: Bool) async throws -> Match? {
        let requestedStarts = retryNoMatch
            ? [position, max(0, position - 6), position + 6]
            : [position]
        var attemptedStarts: Set<Int64> = []
        let session = SHSession()

        for requestedStart in requestedStarts {
            let key = Int64((requestedStart * 1000).rounded())
            guard attemptedStarts.insert(key).inserted else { continue }
            let window = try await source.window(startingAt: requestedStart, duration: Self.windowSeconds)
            defer { if window.isTemporary { try? FileManager.default.removeItem(at: window.fileURL) } }
            guard let query = try makeQuery(
                fileURL: window.fileURL,
                at: requestedStart - window.startSeconds,
                offset: window.startSeconds
            ) else { continue }

            for attempt in 0..<3 {
                try Task.checkCancellation()
                switch await session.result(from: query.signature) {
                case .match(let shazamMatch):
                    guard let item = shazamMatch.mediaItems.first,
                          let title = item.title, !title.isEmpty else { break }
                    let confidence: Double
                    if #available(macOS 15.4, iOS 18.4, tvOS 18.4, *) {
                        confidence = Double(item.confidence)
                    } else {
                        confidence = 0.82
                    }
                    return Match(
                        title: title,
                        artist: item.artist,
                        shazamId: item.shazamID,
                        artworkURL: item.artworkURL,
                        appleMusicURL: item.appleMusicURL,
                        webURL: item.webURL,
                        isrc: item.isrc,
                        queryStartSeconds: query.startSeconds,
                        matchOffset: item.matchOffset,
                        confidence: confidence
                    )
                case .noMatch:
                    break
                case .error(let error, _):
                    guard attempt < 2 else { throw error }
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 900))
                    continue
                }
                break
            }
        }
        return nil
    }

    private func makeQuery(fileURL: URL, at position: TimeInterval, offset: TimeInterval) throws -> Query? {
        let file = try AVAudioFile(forReading: fileURL)
        let inputFormat = file.processingFormat
        let sampleRate = inputFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let startFrame = AVAudioFramePosition(max(0, position) * sampleRate)
        guard startFrame < file.length else { return nil }
        file.framePosition = startFrame
        let requested = min(file.length - startFrame, AVAudioFramePosition(sampleRate * 12))
        guard requested > 0,
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: inputFormat,
                  frameCapacity: AVAudioFrameCount(min(requested, AVAudioFramePosition(UInt32.max)))
              ) else { return nil }
        try file.read(into: inputBuffer, frameCount: inputBuffer.frameCapacity)
        guard inputBuffer.frameLength > 0,
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }
        guard conversionStatus != .error, outputBuffer.frameLength > 0 else { return nil }

        let generator = SHSignatureGenerator()
        try generator.append(
            outputBuffer,
            at: AVAudioTime(sampleTime: 0, atRate: outputFormat.sampleRate)
        )
        return Query(
            signature: generator.signature(),
            startSeconds: offset + Double(startFrame) / sampleRate
        )
    }
}
