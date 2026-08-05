import Foundation
import AVFoundation
import AVFAudio
import MusicUnderstanding

// Tests the MusicUnderstandingSession(audioProvider:) streaming-ingestion
// route: play a local file through AVAudioEngine, install a tap that wraps
// each callback buffer into AVReadOnlyAudioPCMBuffer and yields it into an
// AsyncStream, then feed that stream straight to the session -- this is the
// mechanism that would let a live AVPlayer/AVAudioEngine pipeline (which
// CAN play remote HLS fine) sidestep MusicUnderstandingSession(asset:)'s
// local-file-only restriction, since by the time audio is PCM flowing
// through a node, the original source's locality is irrelevant.
//
// Source of PCM here is a local file for simplicity/determinism -- the
// question this answers is "does the audioProvider ingestion path work at
// all, and what are its real-time characteristics", not "can it decode a
// remote HLS stream" (already answered separately, and irrelevant to this
// path since the tap operates purely on already-decoded PCM regardless of
// where it came from).

func now() -> Double { Date().timeIntervalSinceReferenceDate }

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: audioprovider_test <path>")
    exit(1)
}
let path = args[1]
let fileURL = URL(fileURLWithPath: path)

print("INPUT=\(path)")

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)

let file: AVAudioFile
do {
    file = try AVAudioFile(forReading: fileURL)
} catch {
    print("STATUS=FAILED")
    print("ERROR=could not open file: \(error)")
    exit(1)
}
let format = file.processingFormat
let durationSeconds = Double(file.length) / format.sampleRate
print("FILE_DURATION_S=\(durationSeconds)")

engine.connect(player, to: engine.mainMixerNode, format: format)

// AsyncStream bridging the tap callback (sync, called on a realtime audio
// thread) into an AsyncSequence<AVReadOnlyAudioPCMBuffer, Never>, which is
// exactly the shape MusicUnderstandingSession(audioProvider:) wants.
let (stream, continuation) = AsyncStream<AVReadOnlyAudioPCMBuffer>.makeStream()

var tapBufferCount = 0
var tapFirstCallTime: Double? = nil
var tapLastCallTime: Double = 0

do {
    try player.installAudioTap(
        onBus: 0,
        bufferSize: 4096,
        format: format
    ) { buffer, time in
        if tapFirstCallTime == nil { tapFirstCallTime = now() }
        tapLastCallTime = now()
        tapBufferCount += 1
        continuation.yield(buffer)
    }
} catch {
    print("STATUS=FAILED")
    print("ERROR=installAudioTap threw: \(error)")
    exit(1)
}

engine.prepare()
do {
    try engine.start()
} catch {
    print("STATUS=FAILED")
    print("ERROR=engine.start threw: \(error)")
    exit(1)
}

player.scheduleFile(file, at: nil) {
    // Playback finished delivering samples to the node graph.
    continuation.finish()
}

let tPlayStart = now()
player.play()

// Build the session from the audioProvider *before* or concurrently with
// playback -- try concurrently, matching how a live app would do it.
let sessionTask = Task {
    let session = MusicUnderstandingSession(audioProvider: stream)
    print("SESSION_CREATED_MS=\(Int((now() - tPlayStart) * 1000))")
    let tAnalyzeStart = now()
    do {
        let result = try await session.analyze(for: [.rhythm, .loudness])
        let tAnalyzeEnd = now()
        print("ANALYZE_MS=\(Int((tAnalyzeEnd - tAnalyzeStart) * 1000))")
        print("ANALYZE_END_SINCE_PLAY_START_MS=\(Int((tAnalyzeEnd - tPlayStart) * 1000))")
        print("STATUS=OK")
        if let rhythm = result.rhythm {
            print("RHYTHM_BPM=\(String(describing: rhythm.beatsPerMinute))")
            print("RHYTHM_BEAT_COUNT=\(rhythm.beats.count)")
        }
        if let loudness = result.loudness {
            print("LOUDNESS_INTEGRATED=\(loudness.integrated.value)")
        }
    } catch {
        print("STATUS=FAILED")
        print("ERROR=\(error)")
    }
}

await sessionTask.value
engine.stop()
print("TAP_BUFFER_COUNT=\(tapBufferCount)")
if let first = tapFirstCallTime {
    print("TAP_FIRST_CALLBACK_MS_AFTER_PLAY=\(Int((first - tPlayStart) * 1000))")
}
print("TAP_LAST_CALLBACK_MS_AFTER_PLAY=\(Int((tapLastCallTime - tPlayStart) * 1000))")
print("WALLCLOCK_TOTAL_MS=\(Int((now() - tPlayStart) * 1000))")
