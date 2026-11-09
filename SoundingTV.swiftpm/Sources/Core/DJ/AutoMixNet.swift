import Foundation

nonisolated struct AutoMixNetModel: Codable, Equatable, Sendable {
    struct Dense: Codable, Equatable, Sendable {
        var inputs: Int
        var outputs: Int
        var weights: [Float]
        var bias: [Float]

        func apply(_ x: [Float]) -> [Float] {
            var y = bias
            for o in 0..<outputs {
                var s = y[o]
                let row = o * inputs
                for i in 0..<inputs { s += weights[row + i] * x[i] }
                y[o] = s
            }
            return y
        }
    }

    struct Prediction: Equatable, Sendable {
        var good: Double
        var rating: Double
    }

    var version = 1
    var featureNames: [String]
    var mean: [Float]
    var scale: [Float]
    var hidden: [Dense]
    var good: Dense
    var rating: Dense?

    func standardise(_ x: [Float]) -> [Float] {
        (0..<min(x.count, mean.count)).map { i in
            x[i].isFinite ? (x[i] - mean[i]) / max(1e-6, scale[i]) : 0
        }
    }

    func embed(_ standardised: [Float]) -> [Float] {
        var h = standardised
        for layer in hidden { h = layer.apply(h).map { max(0, $0) } }
        return h
    }

    func predict(_ raw: [Float]) -> Prediction? {
        guard raw.count == featureNames.count, mean.count == raw.count else { return nil }
        let h = embed(standardise(raw))
        let logit = good.apply(h)[0]
        let r = rating.map { 1 + 4 * Self.sigmoid($0.apply(h)[0]) } ?? (1 + 4 * Self.sigmoid(logit))
        return Prediction(good: Double(Self.sigmoid(logit)), rating: Double(r))
    }

    func predict(_ observation: AutoMixNetObservation) -> Prediction? {
        predict(AutoMixNetFeatures.vector(observation))
    }

    static func sigmoid(_ z: Float) -> Float { 1 / (1 + exp(-max(-30, min(30, z)))) }

    static func load(from url: URL) -> AutoMixNetModel? {
        guard let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode(AutoMixNetModel.self, from: data),
              model.featureNames == AutoMixNetFeatures.names else { return nil }
        return model
    }
}

nonisolated enum AutoMixNetExperiment {
    static let enabledKey = "AutoMixNetExperiment"
    static let weightsPathKey = "AutoMixNetExperimentWeights"
    static let maximumAdjustment = 0.03

    static func adjustment(good: Double) -> Double {
        guard good.isFinite else { return 0 }
        return min(maximumAdjustment, max(-maximumAdjustment, (good - 0.5) * 2 * maximumAdjustment))
    }

    static var defaultWeightsURL: URL? {
        AppDataDirectory.folder("AutoMix").appendingPathComponent("transition-net.json")
    }

    static func model(defaults: UserDefaults = .standard) -> AutoMixNetModel? {
        #if DEBUG
        guard defaults.bool(forKey: enabledKey) else { return nil }
        let url = defaults.string(forKey: weightsPathKey).map { URL(fileURLWithPath: $0) } ?? defaultWeightsURL
        return url.flatMap(AutoMixNetModel.load(from:))
        #else
        return nil
        #endif
    }
}
