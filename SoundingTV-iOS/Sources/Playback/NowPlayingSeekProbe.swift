#if DEBUG
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class NowPlayingSeekProbe {
    static let shared = NowPlayingSeekProbe()
    static let isEnabled = ProcessInfo.processInfo.environment["SOUNDING_TV_SEEK_PROBE"] == "1"

    private(set) var summary = "idle"
    @ObservationIgnored private var task: Task<Void, Never>?

    func begin(target: TimeInterval, timeline: NowPlayingTimeline, player: PlayerService) {
        guard Self.isEnabled else { return }
        task?.cancel()
        summary = "running"
        let began = Date()
        let wasPlaying = player.isPlaying
        task = Task { @MainActor [weak self] in
            var snap: TimeInterval = 0
            var mediaSettled: TimeInterval?
            var uiResumed: TimeInterval?
            var divergence: TimeInterval = 0
            var worstGap: TimeInterval = 0
            var last = began
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                let now = Date()
                let elapsed = now.timeIntervalSince(began)
                guard elapsed < 4 else { break }
                worstGap = max(worstGap, now.timeIntervalSince(last))
                last = now
                let shown = timeline.anchor.position(at: now)
                snap = max(snap, target - 1 - shown, shown - (target + elapsed + 0.5))
                if let media = player.debugMediaPosition {
                    let near = media.seconds >= target - 1 && media.seconds <= target + elapsed + 1
                    if mediaSettled == nil, near, media.isRunning || !wasPlaying {
                        mediaSettled = elapsed
                    }
                    if mediaSettled != nil {
                        divergence = max(divergence, abs(shown - media.seconds))
                    }
                }
                if uiResumed == nil, timeline.anchor.isAdvancing || !wasPlaying, mediaSettled != nil {
                    uiResumed = elapsed
                }
            }
            let line = [
                "target=\(String(format: "%.2f", target))",
                "snap=\(String(format: "%.2f", snap))",
                "mediaMs=\(mediaSettled.map { String(Int($0 * 1000)) } ?? "none")",
                "uiMs=\(uiResumed.map { String(Int($0 * 1000)) } ?? "none")",
                "diverge=\(String(format: "%.2f", divergence))",
                "gapMs=\(Int(worstGap * 1000))",
            ].joined(separator: ";")
            print("[SeekProbe] \(line)")
            self?.summary = line
        }
    }
}

struct NowPlayingSeekProbeLabel: View {
    private let probe = NowPlayingSeekProbe.shared

    var body: some View {
        if NowPlayingSeekProbe.isEnabled {
            Text(probe.summary)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.02))
                .accessibilityIdentifier("np.seek.probe")
                .allowsHitTesting(false)
        }
    }
}
#endif
