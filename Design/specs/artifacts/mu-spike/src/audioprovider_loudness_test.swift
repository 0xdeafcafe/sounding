import Foundation
import AVFoundation
import AVFAudio
import MusicUnderstanding

// Q5 (audioProvider variant): with a *live* tap-fed session, does
// loudnessResults arrive paced to real playback time (i.e. useful for a
// realtime visualizer), unlike the near-instant batch delivery observed on
// a local-file asset-based session (see loudness_stream_test.swift)?

func now() -> Double { Date().timeIntervalSinceReferenceDate }

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: audioprovider_loudness_test <path>")
    exit(1)
}
let fileURL = URL(fileURLWithPath: args[1])

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
let file = try AVAudioFile(forReading: fileURL)
let format = file.processingFormat
print("FILE_DURATION_S=\(Double(file.length) / format.sampleRate)")
engine.connect(player, to: engine.mainMixerNode, format: format)

let (stream, continuation) = AsyncStream<AVReadOnlyAudioPCMBuffer>.makeStream()
try player.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
    continuation.yield(buffer)
}
engine.prepare()
try engine.start()
player.scheduleFile(file, at: nil) { continuation.finish() }

let tPlayStart = now()
player.play()

let session = MusicUnderstandingSession(audioProvider: stream)

let consumerTask = Task {
    var count = 0
    for try await value in session.loudnessResults {
        count += 1
        let ms = Int((now() - tPlayStart) * 1000)
        if count <= 5 || count % 50 == 0 {
            print("LOUDNESS_ITEM[\(count)] play_elapsed_ms=\(ms) integrated=\(value.integrated.value)")
        }
    }
    print("LOUDNESS_STREAM_DONE count=\(count) play_elapsed_ms=\(Int((now() - tPlayStart) * 1000))")
}

_ = try await session.analyze(for: [.loudness])
print("ANALYZE_DONE play_elapsed_ms=\(Int((now() - tPlayStart) * 1000))")
try? await Task.sleep(nanoseconds: 500_000_000)
consumerTask.cancel()
engine.stop()
