import Foundation

enum AnalysisBackend: String, Sendable, CaseIterable {
    case cpu
    case gpu

    static let overrideKey = "SOUNDING_ANALYSIS_BACKEND"

    static var requested: AnalysisBackend? {
        let raw = ProcessInfo.processInfo.environment[overrideKey] ?? UserDefaults.sounding.string(forKey: overrideKey)
        return raw.flatMap { AnalysisBackend(rawValue: $0.lowercased()) }
    }

    static var isGPUAvailable: Bool {
        #if canImport(Metal) && !os(watchOS)
        return GPUAnalysisContext.shared != nil
        #else
        return false
        #endif
    }

    static var preferred: AnalysisBackend {
        let wanted = requested ?? .gpu
        return wanted == .gpu && isGPUAvailable ? .gpu : .cpu
    }
}

enum AnalysisFeatureBackend {
    static func options(_ base: BeatTracker.Options, backend: AnalysisBackend = .preferred) -> BeatTracker.Options {
        var options = base
        options.makeExtractor = { makeExtractor(hop: $0, expectedSeconds: $1, backend: backend) }
        return options
    }

    static func makeExtractor(
        hop: Int,
        expectedSeconds: Double,
        backend: AnalysisBackend = .preferred
    ) -> any BeatTrackerFeatureExtracting {
        #if canImport(Metal) && !os(watchOS)
        if backend == .gpu, let context = GPUAnalysisContext.shared,
           let extractor = GPUFeatureExtractor(hop: hop, expectedSeconds: expectedSeconds, context: context) {
            return extractor
        }
        #endif
        return BeatTrackerFeatureExtractor(hop: hop, expectedSeconds: expectedSeconds)
    }

    static func extract(
        _ samples: UnsafeBufferPointer<Float>,
        hop: Int,
        expectedSeconds: Double,
        backend: AnalysisBackend = .preferred
    ) -> BeatTrackerFeatures {
        let extractor = makeExtractor(hop: hop, expectedSeconds: expectedSeconds, backend: backend)
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + 8192)
            extractor.consume(UnsafeBufferPointer(rebasing: samples[offset..<end]))
            offset = end
        }
        return extractor.finish()
    }
}
