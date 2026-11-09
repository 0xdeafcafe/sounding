import Foundation
import Observation

struct DeckPick: Identifiable, Equatable {
    var track: Track
    var bpm: Double?
    var key: CamelotKey?
    var tempoShift: Double?
    var keySteps: Int?
    var score: Double

    var id: String { track.id }

    var readoutText: String? {
        var parts: [String] = []
        if let bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        if let key { parts.append(key.label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var matchText: String? {
        var parts: [String] = []
        switch keySteps {
        case 0?: parts.append("Same key")
        case 1?: parts.append("Key fits")
        default: break
        }
        if let tempoShift, abs(tempoShift) <= DeckPickRanking.tempoReach {
            parts.append(abs(tempoShift) < 1 ? "Same tempo" : String(format: "%+.0f%% tempo", tempoShift))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var isGoodMatch: Bool { score >= DeckPickRanking.goodScore }
}

enum DeckPickRanking {
    static let tempoReach: Double = 6
    static let goodScore: Double = 0.6

    static func tempoShift(from: Double, to: Double) -> Double? {
        guard from > 0, to > 0 else { return nil }
        let folded = [to, to * 2, to / 2].min { abs($0 - from) < abs($1 - from) } ?? to
        return (folded / from - 1) * 100
    }

    static func keySteps(from: CamelotKey, to: CamelotKey) -> Int {
        from.wheelSteps(to: to) + (from.mode == to.mode ? 0 : 1)
    }

    static func score(tempoShift: Double?, keySteps: Int?) -> Double {
        let tempo = tempoShift.map { max(0, 1 - abs($0) / tempoReach) } ?? 0.2
        let key = keySteps.map { max(0, 1 - Double($0) / 3) } ?? 0.25
        return tempo * 0.55 + key * 0.45
    }

    static func pick(_ track: Track, summary: TrackAnalysisSummary?, against base: TrackAnalysisSummary?) -> DeckPick {
        let shift = both(base?.bpm, summary?.bpm).flatMap { tempoShift(from: $0.0, to: $0.1) }
        let steps = both(base?.key, summary?.key).map { keySteps(from: $0.0, to: $0.1) }
        return DeckPick(
            track: track,
            bpm: summary?.bpm,
            key: summary?.key,
            tempoShift: shift,
            keySteps: steps,
            score: base == nil ? 0 : score(tempoShift: shift, keySteps: steps)
        )
    }

    private static func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}

@MainActor
@Observable
final class DeckNextPicksModel {
    struct Section: Identifiable, Equatable {
        enum Kind: String { case suggested, upNext, likes }
        var kind: Kind
        var picks: [DeckPick]

        var id: String { kind.rawValue }

        var title: String {
            switch kind {
            case .suggested: return "Mixes Well"
            case .upNext: return "Up Next"
            case .likes: return "Likes"
            }
        }
    }

    static let upNextLimit = 40
    static let likesLimit = 300
    static let suggestionLimit = 8

    private(set) var sections: [Section] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    var isEmpty: Bool { sections.allSatisfy { $0.picks.isEmpty } }

    func load(player: PlayerService = .shared) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        let current = player.currentTrack
        let queue = player.queue
        let start = min(queue.count, player.currentIndex + 1)
        let upNext = Array(queue[start...].prefix(Self.upNextLimit)).filter { $0.id != current?.id }

        let likeCount = await LibraryDB.count(.likes)
        let likes = likeCount > 0
            ? await LibraryDB.tracks(.likes, offset: 0, limit: min(likeCount, Self.likesLimit)).tracks
            : []
        let upNextIds = Set(upNext.map(\.id))
        let likesOnly = likes.filter { $0.id != current?.id && !upNextIds.contains($0.id) }

        let everything = (current.map { [$0] } ?? []) + upNext + likesOnly
        let summaries = await AnalysisLookup.summaries(for: everything)
        guard !Task.isCancelled else { return }
        let base = current.flatMap { Self.summary(for: $0, known: summaries) }

        let upNextPicks = upNext.map { DeckPickRanking.pick($0, summary: summaries[$0.id], against: base) }
        let likePicks = likesOnly.map { DeckPickRanking.pick($0, summary: summaries[$0.id], against: base) }
        let suggested = (upNextPicks + likePicks)
            .filter(\.isGoodMatch)
            .sorted { $0.score > $1.score }
            .prefix(Self.suggestionLimit)

        sections = [
            Section(kind: .suggested, picks: Array(suggested)),
            Section(kind: .upNext, picks: upNextPicks),
            Section(kind: .likes, picks: likePicks),
        ].filter { !$0.picks.isEmpty }
    }

    private static func summary(for track: Track, known: [String: TrackAnalysisSummary]) -> TrackAnalysisSummary? {
        if let summary = known[track.id], summary.bpm != nil || summary.key != nil { return summary }
        guard case .analyzed(let analysis) = DJTransitionService.shared.state(for: track.id) else { return nil }
        return TrackAnalysisSummary(bpm: analysis.bpm, key: analysis.key.flatMap(CamelotKey.parse))
    }
}
