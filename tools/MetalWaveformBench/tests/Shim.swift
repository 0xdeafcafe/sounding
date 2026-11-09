import XCTest

struct DJExportWaveform: Equatable, Sendable {
    var amplitude: [Float]
    var low: [Float]?
    var mid: [Float]?
    var high: [Float]?
}

enum DJWaveformSynth {
    static let detailEntriesPerSecond = 150.0
}

@main
enum Runner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: MetalWaveformParityTests.self)
        suite.run()
        exit(suite.testRun!.totalFailureCount == 0 ? 0 : 1)
    }
}
