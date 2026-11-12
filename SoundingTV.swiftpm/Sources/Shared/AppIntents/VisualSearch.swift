#if (os(iOS) || os(macOS)) && canImport(VisualIntelligence)
import AppIntents
import CoreVideo
import Foundation
import Vision
import VisualIntelligence

@UnionValue
enum VisualSearchResult {
    case artist(ArtistEntity)
    case track(TrackEntity)
}

struct VisualSearchQuery: IntentValueQuery {
    init() {}

    func values(for input: SemanticContentDescriptor) async throws -> [VisualSearchResult] {
        let terms = VisualSearchTerms.terms(from: input)
        guard !terms.isEmpty else { return [] }
        return await VisualSearch.results(for: terms)
    }
}

@AppIntent(schema: .visualIntelligence.semanticContentSearch)
struct VisualSearchMoreResultsIntent {
    var semanticContent: SemanticContentDescriptor

    @MainActor
    func perform() async throws -> some IntentResult {
        let content = semanticContent
        let terms = await Task.detached(priority: .userInitiated) { VisualSearchTerms.terms(from: content) }.value
        if let query = terms.first {
            SearchRequestRouter.shared.search(query)
        }
        return .result()
    }
}

// MARK: - Opening results

struct OpenTrackIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Track"

    @Parameter(title: "Track")
    var target: TrackEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let track = try? await SoundCloudAPI.shared.getTrack(id: target.id) else {
            throw PlaybackIntentError.notFound
        }
        SoundingPageLinkRouter.shared.pending = SoundingPageLinkRouter.Request(page: .track(track))
        return .result()
    }
}

struct OpenArtistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Artist"

    @Parameter(title: "Artist")
    var target: ArtistEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let user = try? await SoundCloudAPI.shared.getUser(id: target.id) else {
            throw PlaybackIntentError.notFound
        }
        SoundingPageLinkRouter.shared.pending = SoundingPageLinkRouter.Request(page: .artist(user))
        return .result()
    }
}

// MARK: - Search

@MainActor
enum VisualSearch {
    static let trackLimit = 6
    static let artistLimit = 3
    private static let freshness: TimeInterval = 600
    private static let cacheLimit = 20
    private static var cache: [String: (results: [VisualSearchResult], at: Date)] = [:]

    static func results(for terms: [String]) async -> [VisualSearchResult] {
        let key = terms.joined(separator: "\n").lowercased()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < freshness { return hit.results }

        let catalog: LiveSoundingEntityCatalog
        if case .waiting = SoundCloudGateway.shared.trafficSafetyState() {
            catalog = LiveSoundingEntityCatalog(remote: OfflineRemoteCatalog())
        } else {
            catalog = LiveSoundingEntityCatalog()
        }

        let lead = terms[0]
        let trackQuery = terms.count > 1 ? "\(terms[0]) \(terms[1])" : lead
        let artists = Array(((try? await catalog.searchArtists(matching: lead)) ?? []).prefix(artistLimit))
        var tracks = Array(((try? await catalog.searchTracks(matching: trackQuery)) ?? []).prefix(trackLimit))
        if tracks.isEmpty, trackQuery != lead, !isLimited {
            tracks = Array(((try? await catalog.searchTracks(matching: lead)) ?? []).prefix(trackLimit))
        }

        let isStrong: (ArtistEntity) -> Bool = { artist in
            terms.contains { MediaText.score(artist.name, query: $0) >= 85 }
        }
        let strongArtists = artists.filter(isStrong)
        let otherArtists = artists.filter { !isStrong($0) }
        let results = strongArtists.map(VisualSearchResult.artist)
            + tracks.map(VisualSearchResult.track)
            + otherArtists.map(VisualSearchResult.artist)

        if !results.isEmpty {
            if cache.count >= cacheLimit {
                cache = cache.filter { Date().timeIntervalSince($0.value.at) < freshness }
                if cache.count >= cacheLimit { cache.removeAll() }
            }
            cache[key] = (results, Date())
        }
        return results
    }

    private static var isLimited: Bool {
        if case .waiting = SoundCloudGateway.shared.trafficSafetyState() { return true }
        return false
    }
}

private struct OfflineRemoteCatalog: SoundingRemoteCatalog {
    func tracks(ids: [String]) async throws -> [TrackEntity] { [] }
    func searchTracks(_ query: String, limit: Int) async throws -> [TrackEntity] { [] }
    func artists(ids: [String]) async throws -> [ArtistEntity] { [] }
    func searchArtists(_ query: String, limit: Int) async throws -> [ArtistEntity] { [] }
    func playlists(ids: [String]) async throws -> [PlaylistEntity] { [] }
    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistEntity] { [] }
    func myPlaylists(limit: Int) async throws -> [PlaylistEntity] { [] }
}

// MARK: - Reading the picture

enum VisualSearchTerms {
    static let maximumTerms = 3
    private static let minimumTextHeight: Float = 0.025

    static func terms(from descriptor: SemanticContentDescriptor) -> [String] {
        let lines = descriptor.pixelBuffer.map { buffer in
            buffer.withUnsafeBuffer { recognisedLines(in: $0) }
        } ?? []
        let cleaned = unique((lines.isEmpty ? descriptor.labels : lines).compactMap(clean))
        return Array(cleaned.prefix(maximumTerms))
    }

    static func recognisedLines(in buffer: CVPixelBuffer) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
        return observations
            .sorted { $0.boundingBox.height > $1.boundingBox.height }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    static func clean(_ text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard collapsed.count >= 2, collapsed.count <= 60 else { return nil }
        guard collapsed.rangeOfCharacter(from: .letters) != nil else { return nil }
        let lower = collapsed.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("www.") || lower.contains(".com") { return nil }
        return collapsed
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }
}
#endif
