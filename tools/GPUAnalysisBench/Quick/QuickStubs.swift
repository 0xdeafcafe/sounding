import Foundation

struct BeatGrid: Equatable, Sendable, Codable {
    static func fromMeasuredBars(bpm: Double, beats: [TimeInterval], bars: [TimeInterval], barsPerPhrase: Int = 8, confidence: Double, phraseOffsetBars: Int? = nil) -> BeatGrid? { BeatGrid() }
    static func tempoOnly(_ bpm: Double, barsPerPhrase: Int = 8) -> BeatGrid? { BeatGrid() }
}
