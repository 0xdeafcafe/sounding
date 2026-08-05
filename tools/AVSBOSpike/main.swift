// Standalone spike harness for TASK #85 — does NOT compile into any Xcode
// target. Run directly via `swiftc` against the macOS 27 SDK (this host is
// macOS 27.0, so AVPlayerItemSampleBufferOutput and MusicUnderstanding are
// both available natively without needing a simulator).
//
// Answers, in order, stopping at the first failure (per
// Design/specs/os27-api-survey.md §2.1's own spike order):
//   1. Can an AVPlayerItemSampleBufferOutput attach to a SoundCloud-shaped
//      HLS AVPlayerItem (stream URL -> JSON second hop -> .m3u8) at all?
//   2. Does it deliver PCM at the requested format, and can it be pulled
//      ahead of real playback time?
//   3. Feeding those buffers to MusicUnderstandingSession(audioProvider:),
//      does analysis complete, and faster than real time?

import AVFoundation
import AVFAudio
import CoreMedia
import Foundation
import MusicUnderstanding

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

struct StreamResponse: Decodable { let url: String }

func resolveStreamURL(_ streamHopURL: URL) async throws -> URL {
    let (data, response) = try await URLSession.shared.data(from: streamHopURL)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "second hop failed"])
    }
    let decoded = try JSONDecoder().decode(StreamResponse.self, from: data)
    guard let url = URL(string: decoded.url) else {
        throw NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad url in second hop"])
    }
    return url
}

/// Converts a decoded-PCM `CMSampleBuffer` (as delivered by
/// `AVPlayerItemSampleBufferOutput`) into an `AVReadOnlyAudioPCMBuffer`.
func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVReadOnlyAudioPCMBuffer? {
    guard let formatDesc = sampleBuffer.formatDescription else { return nil }
    guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return nil }
    guard let avFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
    let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
    guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else { return nil }
    pcmBuffer.frameLength = frameCount

    do {
        try sampleBuffer.withAudioBufferList { ablPtr, _ in
            if let dst = pcmBuffer.floatChannelData {
                for (i, buf) in ablPtr.enumerated() where i < Int(avFormat.channelCount) {
                    if let src = buf.mData { memcpy(dst[i], src, Int(buf.mDataByteSize)) }
                }
            } else if let dst = pcmBuffer.int16ChannelData {
                for (i, buf) in ablPtr.enumerated() where i < Int(avFormat.channelCount) {
                    if let src = buf.mData { memcpy(dst[i], src, Int(buf.mDataByteSize)) }
                }
            }
        }
    } catch {
        return nil
    }
    return AVReadOnlyAudioPCMBuffer(copying: pcmBuffer)
}

// MARK: - Script body

let streamHopURL = URL(string: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:18799/stream/1")!

log("=== AVPlayerItemSampleBufferOutput spike ===")
log("second-hop URL: \(streamHopURL.absoluteString)")

let hlsURL: URL
do {
    hlsURL = try await resolveStreamURL(streamHopURL)
    log("STEP 0 OK: resolved HLS URL = \(hlsURL.absoluteString)")
} catch {
    log("STEP 0 FAIL: \(error)")
    exit(1)
}

let asset = AVURLAsset(url: hlsURL)
let item = AVPlayerItem(asset: asset)
let player = AVPlayer(playerItem: item)

// --- STEP 1: attach AVPlayerItemSampleBufferOutput to the item ---
let audioConfig = AVPlayerItemSampleBufferOutputAudioConfiguration()
// Request 44.1kHz stereo Float32 PCM, non-interleaved.
var asbd = AudioStreamBasicDescription(
    mSampleRate: 44100,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4,
    mFramesPerPacket: 1,
    mBytesPerFrame: 4,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 32,
    mReserved: 0
)
var formatDesc: CMAudioFormatDescription?
let fdStatus = CMAudioFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    asbd: &asbd,
    layoutSize: 0, layout: nil,
    magicCookieSize: 0, magicCookie: nil,
    extensions: nil,
    formatDescriptionOut: &formatDesc
)
guard fdStatus == noErr, let formatDesc else {
    log("STEP 1 FAIL: could not build CMAudioFormatDescription (status \(fdStatus))")
    exit(1)
}
audioConfig.requestedAudioFormat = formatDesc

let output = AVPlayerItemSampleBufferOutput(configuration: audioConfig)
item.add(output)
log("STEP 1: added AVPlayerItemSampleBufferOutput to AVPlayerItem (pre-ready)")

// Item must become ready to play before the output can deliver anything, and
// must be the player's *current* item (per the header's "Playback only
// happens when the AVPlayerItem is the current item of its AVPlayer").
let readyStart = Date()
var isReady = false
for _ in 0..<200 { // up to ~20s
    if item.status == .readyToPlay { isReady = true; break }
    if item.status == .failed {
        log("STEP 1 FAIL: item failed to become ready: \(String(describing: item.error))")
        exit(1)
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
}
log("item.status ready in \(Date().timeIntervalSince(readyStart))s, status=\(item.status.rawValue)")
guard isReady else {
    log("STEP 1 FAIL: item never became ready")
    exit(1)
}
log("STEP 1 OK: AVPlayerItemSampleBufferOutput attached to a real HLS AVPlayerItem and the item is ready")

// Start playback (muted) -- the header says delivery only happens while the
// item is current/playing.
player.volume = 0
player.play()

// Pull as many sample buffers as we can, as fast as we can (NOT gated on a
// delegate callback or on real playback pacing), and measure: (a) whether we
// get real audio-bearing buffers, (b) the format we actually receive, (c) how
// much audio (by PTS span) we can pull vs. the wall-clock time it took --
// i.e. can we get ahead of real-time playback.
var pcmBuffers: [AVReadOnlyAudioPCMBuffer] = []
var totalFrames: Int64 = 0
var firstPTS: CMTime?
var lastPTS: CMTime?
var restarts = 0
let pullStart = Date()
var pulls = 0
var nilPulls = 0
let maxPulls = 40000

while pulls < maxPulls {
    pulls += 1
    guard let entry = output.nextAvailableSampleBuffer() else {
        nilPulls += 1
        if nilPulls > 200 { break } // no more ready right now
        // Brief backoff, mirroring what a real client would do while waiting
        // on outputMediaDataAvailable.
        try? await Task.sleep(nanoseconds: 5_000_000)
        continue
    }
    nilPulls = 0
    if entry.sequenceWasRestarted { restarts += 1 }
    let ready = entry.sampleBuffer
    let numSamples = ready.sampleCount
    if numSamples > 0 {
        totalFrames += Int64(numSamples)
        let pts = ready.outputPresentationTimeStamp
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts
        if let pcm = ready.withUnsafeSampleBuffer(makePCMBuffer) {
            pcmBuffers.append(pcm)
        }
    }
    // Stop once we've pulled a healthy amount (~50s of audio) so the spike
    // finishes quickly rather than draining the whole item.
    if let first = firstPTS, let last = lastPTS,
       CMTimeGetSeconds(CMTimeSubtract(last, first)) > 50 {
        break
    }
}
let pullWallClock = Date().timeIntervalSince(pullStart)
let audioSeconds = (firstPTS != nil && lastPTS != nil)
    ? CMTimeGetSeconds(CMTimeSubtract(lastPTS!, firstPTS!)) : 0

log("STEP 2: pulls=\(pulls) buffersWithSamples=\(pcmBuffers.count) totalFrames=\(totalFrames) restarts=\(restarts)")
log("STEP 2: audio PTS span pulled = \(audioSeconds)s, wall clock to pull it = \(pullWallClock)s")
if audioSeconds > 0, pullWallClock > 0 {
    let ratio = audioSeconds / pullWallClock
    log("STEP 2: pull throughput = \(ratio)x real time (>1 means we can pull faster than real-time playback)")
}
log("STEP 2: player.currentTime = \(CMTimeGetSeconds(player.currentTime()))s at end of pull loop (started muted playback at t=0)")

guard let first = pcmBuffers.first else {
    log("STEP 2 FAIL: never received/converted a sample buffer with actual PCM samples")
    exit(1)
}
log("STEP 2 OK: delivered format = \(first.format), frameLength(first)=\(first.frameLength)")
let isPCM = first.format.commonFormat != .otherFormat
log("STEP 2: isPCM=\(isPCM)")

// --- STEP 3: feed into MusicUnderstandingSession(audioProvider:) ---
// Drain the already-pulled PCM buffers into the session's AsyncStream as fast
// as we can (no artificial real-time pacing), to test whether the *session*
// itself paces consumption to real time or accepts buffers at whatever rate
// the provider yields.
guard !pcmBuffers.isEmpty else {
    log("STEP 3 FAIL: no convertible PCM buffers, cannot feed MusicUnderstanding")
    exit(1)
}

let feedStart = Date()
let feedEndBox = Box<Date?>(nil)
let provider = AsyncStream<AVReadOnlyAudioPCMBuffer> { continuation in
    Task {
        for buf in pcmBuffers {
            continuation.yield(buf)
        }
        feedEndBox.value = Date()
        continuation.finish()
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

let session = MusicUnderstandingSession(audioProvider: provider)
do {
    let analyzeStart = Date()
    let result = try await session.analyze(for: [.pace])
    let analyzeElapsed = Date().timeIntervalSince(analyzeStart)
    let feedElapsed = (feedEndBox.value ?? Date()).timeIntervalSince(feedStart)
    log("STEP 3 OK: analyze(for: [.pace]) returned in \(analyzeElapsed)s (feed loop took \(feedElapsed)s) for \(audioSeconds)s of audio")
    log("STEP 3: result.pace = \(String(describing: result.pace))")
    if audioSeconds > 0 {
        log("STEP 3: end-to-end speed = \(audioSeconds / analyzeElapsed)x real time")
    }
} catch {
    log("STEP 3 FAIL: MusicUnderstandingSession(audioProvider:).analyze threw: \(error)")
    exit(1)
}

log("=== spike complete ===")
exit(0)
