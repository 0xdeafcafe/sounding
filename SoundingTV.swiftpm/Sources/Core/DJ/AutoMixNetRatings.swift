import Foundation

nonisolated struct AutoMixNetSample: Codable, Equatable, Sendable {
    var id: String
    var observation: AutoMixNetObservation
    var good: Bool
    var rating: Double?
    var source: String
    var fault: String?
}

extension AutoMixNetObservation {
    nonisolated init(rated features: AutoMixTransitionFeatures) {
        self.init(
            moveType: features.moveType,
            blendBars: Double(features.blendBars),
            energyStep: features.energyDelta,
            vocalOverlapSeconds: features.vocalOverlapSeconds,
            keyDistance: features.keyDistance,
            bpmDeltaPercent: features.bpmDistancePercent,
            exitSection: features.outgoingSection,
            entrySection: features.incomingSection
        )
    }
}

nonisolated enum AutoMixNetRatings {
    static func samples(_ ratings: [AutoMixRating]) -> [AutoMixNetSample] {
        ratings.enumerated().map { index, rating in
            AutoMixNetSample(
                id: "rating-\(index)-\(Int(rating.date.timeIntervalSince1970))",
                observation: AutoMixNetObservation(rated: rating.features),
                good: rating.liked,
                rating: rating.liked ? 4 : 2,
                source: "feedback"
            )
        }
    }

    static func load(from url: URL) throws -> [AutoMixNetSample] {
        let data = try Data(contentsOf: url)
        return samples(try JSONDecoder().decode([AutoMixRating].self, from: data))
    }
}
