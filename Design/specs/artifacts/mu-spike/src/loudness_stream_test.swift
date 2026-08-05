import Foundation
import AVFoundation
import MusicUnderstanding

// Q5: does `loudnessResults` (the nonisolated AsyncSequence property) yield
// values *during* analyze()'s execution, or only after the whole asset has
// been consumed? Uses a local-file asset-based session (fast decode, not
// realtime-paced) so any incremental delivery is easy to see relative to
// total analyze() time.

func now() -> Double { Date().timeIntervalSinceReferenceDate }

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: loudness_stream_test <path>")
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
let asset = AVURLAsset(url: url)

let tStart = now()
let session = try await MusicUnderstandingSession(asset: asset)
print("SESSION_CREATE_MS=\(Int((now() - tStart) * 1000))")

// Consumer: iterate loudnessResults concurrently, timestamping arrivals.
let consumerTask = Task {
    var count = 0
    var firstArrivalMs: Int? = nil
    do {
        for try await value in session.loudnessResults {
            count += 1
            let ms = Int((now() - tStart) * 1000)
            if firstArrivalMs == nil { firstArrivalMs = ms }
            print("LOUDNESS_STREAM_ITEM[\(count)] at_ms=\(ms) integrated=\(value.integrated.value) short_term_count=\(value.shortTerm.count) momentary_count=\(value.momentary.count)")
        }
    } catch {
        print("LOUDNESS_STREAM_ERROR=\(error)")
    }
    print("LOUDNESS_STREAM_DONE count=\(count) first_arrival_ms=\(String(describing: firstArrivalMs))")
}

// Producer: run analyze(), timestamp completion.
let tAnalyzeStart = now()
let result = try await session.analyze(for: [.loudness])
let tAnalyzeEnd = now()
print("ANALYZE_MS=\(Int((tAnalyzeEnd - tAnalyzeStart) * 1000))")
print("ANALYZE_DONE_AT_MS=\(Int((tAnalyzeEnd - tStart) * 1000))")
if let l = result.loudness {
    print("FINAL_RESULT_INTEGRATED=\(l.integrated.value)")
}

// Give the consumer a moment to drain/finish after analyze() completes, in
// case the sequence only finishes (or only starts delivering) once analyze
// itself has returned.
try? await Task.sleep(nanoseconds: 2_000_000_000)
consumerTask.cancel()
print("TOTAL_MS=\(Int((now() - tStart) * 1000))")
