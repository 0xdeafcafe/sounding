import Foundation

struct AnalysisEngineIdentity: Hashable, Codable, Sendable {
    let name: String
    let version: Int
}

struct BeatThisResult: Codable, Sendable, Equatable {
    let beats: [Double]
    let downbeats: [Double]
    let barDownbeats: [Double]
    let bpm: Double?
    let confidence: Double
    let downbeatConfidence: Double
    let beatsPerBar: Int?
}
