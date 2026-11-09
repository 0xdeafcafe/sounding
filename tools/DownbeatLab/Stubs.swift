import Foundation

struct AnalysisEngineIdentity: Codable, Hashable, Sendable {
    let name: String
    let version: Int
}

struct BeatGrid:Equatable, Sendable, Codable {
    static func fromMeasuredBars(bpm: Double, beats: [TimeInterval], bars: [TimeInterval], barsPerPhrase: Int = 8, confidence: Double, phraseOffsetBars: Int? = nil) -> BeatGrid? { BeatGrid() }
    static func tempoOnly(_ bpm: Double, barsPerPhrase: Int = 8) -> BeatGrid? { BeatGrid() }
}

enum SectionKind: String, Codable, Sendable, CaseIterable {
    case ambientIntro, intro, buildup, drop, breakdown, bridge, cooldown, outro, ambientOutro
    case build
    case unknown
}

struct TrackSection: Equatable, Sendable, Codable {
    let kind: SectionKind
    let start: TimeInterval
    let end: TimeInterval
}
