import QuartzCore
import SwiftUI

@MainActor
func run() {
    let envelope = (0 ..< 1800).map { i in Float(0.3 + 0.6 * abs(sin(Double(i) * 0.37))) }
    let set = (0 ..< 1_080_000).map { i in Float(0.3 + 0.6 * abs(sin(Double(i) * 0.0137))) }
    let cases: [(String, SCWaveformPlayheadMode, CGFloat, CGFloat, [Float], Double)] = [
        ("2 h set at 150/s, whole, 1200x120", .fixed, 1200, 120, set, 7200),
        ("2 h set at 150/s, centered 10 s, 1200x120", .centered(windowSeconds: 10), 1200, 120, set, 7200),
        ("Mac deck lane, centered 10 s, 1200x120", .centered(windowSeconds: 10), 1200, 120, envelope, 360),
        ("Mac overview strip, fixed, 600x24", .fixed, 600, 24, envelope, 360),
        ("Scrubber, fixed, 1200x60", .fixed, 1200, 60, envelope, 360),
    ]
    for (label, mode, width, height, samples, duration) in cases {
        var times: [Double] = []
        for f in 0 ..< 120 {
            let view = SCWaveformRenderer(
                envelope: samples, duration: duration, progress: Double(f) / 120 * 0.5 + 0.2,
                mode: mode, beatGrid: SCBeatGrid(bpm: 128),
                cueMarkers: [SCWaveformMarker(id: "a", position: 0.3), SCWaveformMarker(id: "b", position: 0.5)],
                identity: "x", motionSuppressed: true, style: .decks
            ).frame(width: width, height: height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let t0 = CACurrentMediaTime()
            _ = renderer.cgImage
            times.append(CACurrentMediaTime() - t0)
        }
        times.sort()
        print(String(format: "  %-44@ main-thread median %.2f ms  p95 %.2f ms", label as NSString, times[60] * 1000, times[114] * 1000))
    }
}

@main
enum Main {
    static func main() async {
        await run()
    }
}
