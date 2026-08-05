import Foundation
import AVFoundation
import MusicUnderstanding
import CoreMedia

// mutool <path-or-url> <types|all> [--beats] [--sections] [--loudness-detail]
//
// Loads the given asset (local path or http(s) URL), builds a
// MusicUnderstandingSession, times session creation and analyze()
// separately, then dumps the requested result detail to stdout as
// plain lines (grep-friendly), prefixed by tag.

func now() -> Double { Date().timeIntervalSinceReferenceDate }

func parseTypes(_ s: String) -> Set<AnalysisType> {
    if s == "all" {
        return [.rhythm, .key, .loudness, .structure, .pace, .instrumentActivity]
    }
    var out = Set<AnalysisType>()
    for part in s.split(separator: ",") {
        switch part {
        case "rhythm": out.insert(.rhythm)
        case "key": out.insert(.key)
        case "loudness": out.insert(.loudness)
        case "structure": out.insert(.structure)
        case "pace": out.insert(.pace)
        case "instrumentActivity": out.insert(.instrumentActivity)
        default: FileHandle.standardError.write("Unknown type: \(part)\n".data(using: .utf8)!)
        }
    }
    return out
}

func assetURL(from s: String) -> URL {
    if s.hasPrefix("http://") || s.hasPrefix("https://") {
        return URL(string: s)!
    }
    return URL(fileURLWithPath: s)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: mutool <path-or-url> <types|all> [flags]")
    exit(1)
}
let inputArg = args[1]
let typesArg = args[2]
let flags = Set(args.dropFirst(3))

let url = assetURL(from: inputArg)
print("INPUT=\(inputArg)")
print("RESOLVED_URL=\(url.absoluteString)")

let types = parseTypes(typesArg)
print("TYPES=\(typesArg)")

let asset = AVURLAsset(url: url)

let tAssetStart = now()
// Touch loadable properties first so asset-load time is visible separately
// from session/analyze time (mirrors what the app would do anyway).
do {
    let duration = try await asset.load(.duration)
    let tAssetLoaded = now()
    print("ASSET_LOAD_MS=\(Int((tAssetLoaded - tAssetStart) * 1000))")
    print("ASSET_DURATION_S=\(duration.seconds)")
} catch {
    let tAssetLoaded = now()
    print("ASSET_LOAD_MS=\(Int((tAssetLoaded - tAssetStart) * 1000))")
    print("ASSET_LOAD_ERROR=\(error)")
}

let tSessionStart = now()
do {
    let session = try await MusicUnderstandingSession(asset: asset)
    let tSessionCreated = now()
    print("SESSION_CREATE_MS=\(Int((tSessionCreated - tSessionStart) * 1000))")

    let tAnalyzeStart = now()
    let result = try await session.analyze(for: types)
    let tAnalyzeEnd = now()
    print("ANALYZE_MS=\(Int((tAnalyzeEnd - tAnalyzeStart) * 1000))")
    print("TOTAL_MS=\(Int((tAnalyzeEnd - tSessionStart) * 1000))")
    print("STATUS=OK")

    if let rhythm = result.rhythm {
        print("RHYTHM_BPM=\(String(describing: rhythm.beatsPerMinute))")
        print("RHYTHM_BEAT_COUNT=\(rhythm.beats.count)")
        print("RHYTHM_BAR_COUNT=\(rhythm.bars.count)")
        if flags.contains("--beats") {
            for (i, b) in rhythm.beats.enumerated() {
                print("BEAT[\(i)]=\(b.seconds)")
            }
            for (i, b) in rhythm.bars.enumerated() {
                print("BAR[\(i)]=\(b.seconds)")
            }
        } else {
            // Print interval stats even without --beats
            let secs = rhythm.beats.map { $0.seconds }
            if secs.count > 1 {
                let intervals = zip(secs.dropFirst(), secs).map { $0 - $1 }
                let avg = intervals.reduce(0, +) / Double(intervals.count)
                print("RHYTHM_AVG_BEAT_INTERVAL_S=\(avg)")
                print("RHYTHM_IMPLIED_BPM_FROM_INTERVALS=\(60.0 / avg)")
                print("RHYTHM_FIRST_BEAT_S=\(secs.first!)")
                print("RHYTHM_LAST_BEAT_S=\(secs.last!)")
            }
        }
    }

    if let key = result.key {
        print("KEY_RANGE_COUNT=\(key.ranges.count)")
        for (i, r) in key.ranges.enumerated() {
            print("KEY[\(i)]=\(r.value.tonic.rawValue) \(r.value.mode.rawValue) start=\(r.range.start.seconds) dur=\(r.range.duration.seconds)")
        }
    }

    if let loudness = result.loudness {
        print("LOUDNESS_INTEGRATED=\(loudness.integrated.value) at t=\(loudness.integrated.time.seconds)")
        print("LOUDNESS_PEAK=\(loudness.peak.value) at t=\(loudness.peak.time.seconds)")
        print("LOUDNESS_MOMENTARY_COUNT=\(loudness.momentary.count)")
        print("LOUDNESS_SHORTTERM_COUNT=\(loudness.shortTerm.count)")
        if flags.contains("--loudness-detail") {
            for (i, v) in loudness.shortTerm.enumerated() {
                print("LOUDNESS_SHORTTERM[\(i)]=t=\(v.time.seconds) v=\(v.value)")
            }
        }
    }

    if let structure = result.structure {
        print("STRUCTURE_SECTIONS=\(structure.sections.count)")
        for (i, s) in structure.sections.enumerated() {
            print("SECTION[\(i)]=start=\(s.start.seconds) end=\(s.end.seconds) dur=\(s.duration.seconds)")
        }
        print("STRUCTURE_SEGMENTS=\(structure.segments.count)")
        for (i, s) in structure.segments.enumerated() {
            print("SEGMENT[\(i)]=start=\(s.start.seconds) end=\(s.end.seconds) dur=\(s.duration.seconds)")
        }
        print("STRUCTURE_PHRASES=\(structure.phrases.count)")
        for (i, s) in structure.phrases.enumerated() {
            print("PHRASE[\(i)]=start=\(s.start.seconds) end=\(s.end.seconds) dur=\(s.duration.seconds)")
        }
    }

    if let pace = result.pace {
        print("PACE_RANGE_COUNT=\(pace.ranges.count)")
        for (i, r) in pace.ranges.enumerated() {
            print("PACE[\(i)]=value=\(r.value) start=\(r.range.start.seconds) dur=\(r.range.duration.seconds)")
        }
    }

    if let instr = result.instrumentActivity {
        print("INSTRUMENT_KEYS=\(instr.ranges.keys.map { $0.rawValue }.sorted().joined(separator: ","))")
        for (inst, ranges) in instr.ranges {
            print("INSTRUMENT[\(inst.rawValue)]_RANGE_COUNT=\(ranges.count)")
            for (i, r) in ranges.enumerated() {
                print("INSTRUMENT[\(inst.rawValue)]_RANGE[\(i)]=start=\(r.start.seconds) end=\(r.end.seconds)")
            }
        }
    }

    // Peak RSS at end of run (high-water mark for the whole process).
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("PEAK_RSS_BYTES=\(usage.ru_maxrss)")

} catch {
    let tFail = now()
    print("STATUS=FAILED")
    print("ERROR=\(error)")
    print("ELAPSED_MS=\(Int((tFail - tSessionStart) * 1000))")
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("PEAK_RSS_BYTES=\(usage.ru_maxrss)")
    exit(2)
}
