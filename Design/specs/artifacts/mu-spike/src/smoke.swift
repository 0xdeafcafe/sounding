import Foundation
import AVFoundation
import MusicUnderstanding

print("MusicUnderstanding smoke test starting...")

let path = "/Users/afr/.claude/jobs/3fc7cb5a/tmp/mu-spike/audio/click_128.wav"
let url = URL(fileURLWithPath: path)
let asset = AVURLAsset(url: url)

do {
    let session = try await MusicUnderstandingSession(asset: asset)
    print("Session created OK")
    let result = try await session.analyze(for: [.rhythm])
    print("Analyze OK")
    if let rhythm = result.rhythm {
        print("BPM: \(String(describing: rhythm.beatsPerMinute))")
        print("Beat count: \(rhythm.beats.count)")
        print("Bar count: \(rhythm.bars.count)")
        if let first = rhythm.beats.first {
            print("First beat: \(first.seconds)")
        }
    } else {
        print("No rhythm result")
    }
} catch {
    print("FAILED: \(error)")
}
