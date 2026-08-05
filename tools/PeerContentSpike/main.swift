// PeerContentSpike / main.swift (the AVPlayer-integration harness) — proves
// task #25 gap (d): "the resource loader delegate has never met a real
// AVPlayer". Named `main.swift` (not `av_player_harness.swift`) because
// `swiftc` only allows top-level executable statements in a file with that
// exact name once more than one file is passed on the command line — every
// other file here is types/functions only.
//
// Unlike harness.swift (which deliberately *duplicates* the wire types to
// stay clear of `DownloadManager`'s dependency tree), this harness compiles
// in the real, unmodified production files it is actually testing:
//
//   TokenTransferProtocol.swift            (PairingTLS, BonjourConstants)
//   PeerContentTransport.swift             (PeerContentServer/Client — real)
//   PeerContentAssetLoaderDelegate.swift   (the file this trial is about)
//
// `PeerContentServer.defaultResolver` references `DownloadManager`, whose
// real implementation drags in `SubscriptionService`/`SettingsStore`/
// `KeychainService`/UIKit-era singletons — far more than a transport-and-
// delegate trial needs. Duplicating `PeerContentTransport.swift` the way
// `harness.swift` duplicates the wire types would stop this from proving
// anything about the *real* `PeerContentAssetLoaderDelegate`, which is the
// entire point here — so instead this file below supplies a same-named,
// same-shaped stub `DownloadManager` purely so `defaultResolver`'s reference
// typechecks. It is never actually called: every `PeerContentServer` here is
// constructed with an explicit `resolveFile` closure over a real temp file.
//
// Connects over loopback by real port number (`PeerContentServer.boundPort`,
// added alongside this file for exactly this reason) rather than Bonjour:
// mDNS discovery for `_soundingtv._tcp` is already exercised, unmodified, by
// `RemoteQueueServer`/`RemoteQueueClient` in production, and a bare
// `simctl spawn` process has no Info.plist to carry
// `NSLocalNetworkUsageDescription` — mDNS from here would either hang on a
// local-network permission prompt nothing can answer, or fail in a way that
// says nothing about the delegate this trial exists to test.
//
// `PeerContentServer`/`PeerContentClient`/etc. are exactly as `@MainActor`-
// isolated (or not) as they are in the real app, so all of this runs inside
// one `@MainActor` `runHarness()`, scheduled via `Task { @MainActor in }` and
// kept alive with `RunLoop.main.run()` — a bare `swiftc` executable's
// top-level code is *not* itself main-actor-isolated the way an app's entry
// point is, so calling straight into these types from plain top-level
// statements fails to typecheck (`main actor-isolated ... in a synchronous
// nonisolated context`). `waitUntil` pumps that same run loop while polling,
// so nothing here needs a semaphore-blocked thread the run loop can't drain.
//
// Diagnostic-only var-capture-across-queues style (no locks beyond the one
// semaphore used for the connect handshake) matches `harness.swift`'s own
// approach — acceptable for a one-shot throwaway CLI tool that is never
// linked into the app, not code this project ships.
//
// Run (see also tools/PeerContentSpike/run_av_player_harness.sh):
//   ffmpeg -y -f lavfi -i "sine=frequency=440:duration=6" -ar 44100 -ac 2 \
//     -c:a libmp3lame -b:a 128k /tmp/peercontent-av-harness-tone.mp3
//   xcrun swiftc -target arm64-apple-tvos27.0-simulator \
//     -sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)" \
//     ../../SoundingTV.swiftpm/Sources/Services/TokenTransferProtocol.swift \
//     ../../SoundingTV.swiftpm/Sources/Services/PeerContentTransport.swift \
//     ../../SoundingTV.swiftpm/Sources/Services/PeerContentAssetLoaderDelegate.swift \
//     main.swift -o /tmp/av-player-harness
//   xcrun simctl spawn <udid> /tmp/av-player-harness /tmp/peercontent-av-harness-tone.mp3

import AVFoundation
import Foundation
import Network
import UniformTypeIdentifiers

// MARK: - DownloadManager stub — see header comment. Never called.

@MainActor
final class DownloadManager {
    static let shared = DownloadManager()
    func localFileURL(forTrackId trackId: String) -> URL? { nil }
}

// MARK: - Harness plumbing

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  PASS  \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name)  \(detail)")
    }
}

/// Pumps the main run loop in small slices while waiting for `condition` to
/// go true or `timeout` to elapse — lets AVFoundation's internal (possibly
/// run-loop-dependent) completions, and any `Task { @MainActor in }` work
/// queued against this same executor, actually run; a plain `Thread.sleep`
/// loop wouldn't service either.
@discardableResult
func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return condition() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return true
}

@MainActor
func runHarness() {
    print("=== PeerContentSpike / TASK #25 — real AVPlayer integration ===")

    guard CommandLine.arguments.count > 1 else {
        print("usage: av-player-harness <path-to-tone-file> [file-extension, default mp3]")
        exit(2)
    }
    let toneURL = URL(fileURLWithPath: CommandLine.arguments[1])
    // Second argument lets the same harness prove task #25 gap (e) — whether
    // `org.xiph.flac` is a real, resolvable UTType on this SDK, and whether
    // `AVAssetResourceLoadingContentInformationRequest.contentType` actually
    // accepts it — by running exactly the same three trials against a real
    // FLAC file instead of the default MP3.
    let fileExtension = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mp3"
    guard FileManager.default.fileExists(atPath: toneURL.path) else {
        print("FATAL: tone file not found at \(toneURL.path)")
        exit(2)
    }
    let toneSize = (try? FileManager.default.attributesOfItem(atPath: toneURL.path)[.size] as? Int64) ?? nil
    print("tone file: \(toneURL.path) (\(toneSize.map(String.init) ?? "?") bytes, extension=\(fileExtension))")

    // --- UTType diagnostics for task #25 gap (e): does `org.xiph.flac`
    // actually resolve on this SDK at all, independent of whether AVPlayer
    // goes on to accept it? `UTType(_:)` returns `nil` for an identifier the
    // system has never heard of — a fabricated/wrong identifier — as opposed
    // to a real-but-unrelated type, which is exactly the failure mode worth
    // ruling out before trusting the delegate's `contentType` mapping.
    for identifier in ["org.xiph.flac", "public.mp3", "public.mpeg-4-audio", "public.audio"] {
        if let type = UTType(identifier) {
            print(
                "UTType(\"\(identifier)\") resolves: preferredMIMEType=\(type.preferredMIMEType ?? "nil") "
                    + "conformsToAudio=\(type.conforms(to: .audio)) "
                    + "preferredFilenameExtension=\(type.preferredFilenameExtension ?? "nil")"
            )
        } else {
            print("UTType(\"\(identifier)\") does NOT resolve on this SDK — returns nil")
        }
    }

    let harnessSessionId = "av-harness-session-\(UUID().uuidString.prefix(8))"
    let harnessSecret = Data("AVPlayerHarness-not-a-real-secret-\(UUID().uuidString)".utf8)
    let trackId = "harness-track-1"

    #if canImport(AVFAudio)
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    try? AVAudioSession.sharedInstance().setActive(true)
    #endif

    // --- Start the real PeerContentServer, resolving `trackId` to the tone
    // file exactly the way `DownloadManager.localFileURL(forTrackId:)` would
    // for a real download — see this closure as standing in for that one
    // sanctioned read path.
    let server = PeerContentServer(resolveFile: { requestedId in
        requestedId == trackId ? toneURL : nil
    })
    do {
        try server.start(sessionId: harnessSessionId, secret: harnessSecret)
    } catch {
        print("FATAL: server failed to start: \(error)")
        exit(1)
    }

    // `PeerContentServer.start` sets no `stateUpdateHandler` (production
    // never needed one — Bonjour advertisement is fire-and-forget), so
    // `listener.port` is non-nil immediately but holds the placeholder
    // `.any` (rawValue 0) until the listener actually reaches `.ready` and
    // the OS hands back a real ephemeral port. Waiting on `!= 0` rather than
    // `!= nil` is what actually waits for that.
    guard waitUntil(5, { (server.boundPort?.rawValue ?? 0) != 0 }), let port = server.boundPort else {
        print("FATAL: server never bound a real port")
        exit(1)
    }
    print("server listening on 127.0.0.1:\(port.rawValue)")

    // --- Real PeerContentClient, real content-PSK handshake, over loopback.
    let client = PeerContentClient()
    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)

    let connectSem = DispatchSemaphore(value: 0)
    var connectOutcome: Result<Void, PeerContentError>?
    client.connect(to: endpoint, sessionId: harnessSessionId, secret: harnessSecret, timeout: 10) { result in
        connectOutcome = result
        connectSem.signal()
    }
    waitUntil(12) { connectSem.wait(timeout: .now()) == .success }
    switch connectOutcome {
    case .success:
        check("content-PSK connect succeeds over loopback", true)
    case .failure(let error):
        check("content-PSK connect succeeds over loopback", false, "\(error)")
        exit(1)
    case nil:
        check("content-PSK connect succeeds over loopback", false, "timed out waiting for connect callback")
        exit(1)
    }

    // --- The real delegate, feeding a real AVPlayer through the custom scheme.
    let contentType = PeerContentAssetLoaderDelegate.contentType(forFileExtension: fileExtension)
    let delegate = PeerContentAssetLoaderDelegate(client: client, trackId: trackId, contentType: contentType)
    let assetURL = PeerContentAssetLoaderDelegate.assetURL(trackId: trackId)
    print("asset URL: \(assetURL.absoluteString) (contentType: \(contentType))")

    let asset = AVURLAsset(url: assetURL)
    asset.resourceLoader.setDelegate(delegate, queue: delegate.queue)

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)

    // --- Trial 1: the asset actually becomes playable — proves
    // `contentInformationRequest` round-trips through the delegate (the
    // length probe, the content-type hint) and AVPlayer accepts what it got
    // back.
    print("\n--- Trial 1: asset resolves to a playable item via the real delegate ---")
    waitUntil(20) { item.status != .unknown }
    check(
        "AVPlayerItem reaches .readyToPlay (not .failed/.unknown)",
        item.status == .readyToPlay,
        "status=\(item.status.rawValue) error=\(String(describing: item.error))"
    )

    let durationSeconds = item.asset.duration.seconds
    check(
        "duration resolved and matches the generated ~6s tone",
        durationSeconds.isFinite && durationSeconds > 4 && durationSeconds < 8,
        "duration=\(durationSeconds)"
    )

    guard item.status == .readyToPlay else {
        print("\n=== ABORTED: item never became playable, skipping playback/seek trials ===")
        client.disconnect()
        server.stop()
        print("\n=== DONE: \(failures) FAILURE(S) ===")
        exit(1)
    }

    // --- Trial 2: playback genuinely progresses through the peer-fed asset.
    // Same evidentiary bar CLAUDE.md's AVSBOSpike measurement used to
    // establish real progress without a speaker: `timeControlStatus ==
    // .playing` plus `currentTime` advancing in step with wall-clock time,
    // not just "didn't crash" or "reached .readyToPlay".
    print("\n--- Trial 2: playback actually progresses via range fetches over the peer transport ---")
    player.play()
    let sawPlaying = waitUntil(15) { player.timeControlStatus == .playing }
    check("player reaches .playing", sawPlaying, "timeControlStatus=\(player.timeControlStatus.rawValue)")

    let t0 = player.currentTime().seconds
    let wallStart = Date()
    waitUntil(2.5) { false } // pump the run loop for a fixed window
    let t1 = player.currentTime().seconds
    let wallElapsed = Date().timeIntervalSince(wallStart)
    check(
        "currentTime advances in real time while playing",
        t1 > t0 + 1.0,
        "t0=\(t0) t1=\(t1) wallElapsed=\(wallElapsed)"
    )

    // --- Trial 3: seeking actually lands, and the delegate serves the range
    // at the *new* offset — not just replaying whatever was already buffered
    // from zero. Exercises exactly the "range requests, seeking" hard part
    // the delegate's own header comment calls out.
    print("\n--- Trial 3: seek lands at the requested offset ---")
    let seekTarget = max(0, durationSeconds - 2.0)
    var seekFinishedFlag: Bool?
    player.seek(to: CMTime(seconds: seekTarget, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
        seekFinishedFlag = finished
    }
    waitUntil(15) { seekFinishedFlag != nil }
    let afterSeek = player.currentTime().seconds
    check(
        "seek completion handler fired with finished == true",
        seekFinishedFlag == true,
        "seekFinishedFlag=\(String(describing: seekFinishedFlag))"
    )
    check(
        "currentTime lands near the requested offset",
        abs(afterSeek - seekTarget) < 1.0,
        "target=\(seekTarget) actual=\(afterSeek)"
    )

    player.pause()
    client.disconnect()
    server.stop()

    print("\n=== DONE: \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ===")
    exit(failures == 0 ? 0 : 1)
}

// Direct `assumeIsolated`, not `Task { @MainActor in }`: the latter enters
// `runHarness()` as a block scheduled onto the MainActor executor's own
// dispatch queue, which then needs the run loop pumped just to get that
// *first* call dispatched — indistinguishable, from a hang, from any of the
// waits inside `runHarness()` itself never resolving. This process's initial
// thread genuinely is the main thread, so asserting that directly and
// calling straight in avoids the extra indirection entirely.
MainActor.assumeIsolated {
    runHarness()
}
