import SwiftUI

struct PulseTimeline<Content: View>: View {
    let isActive: Bool
    let reduceMotion: Bool
    var minimumInterval: Double = 1.0 / 30.0
    @ViewBuilder var content: (Pulse) -> Content

    var body: some View {
        if reduceMotion || !isActive {
            content(MusicPulse.shared.resting)
        } else {
            TimelineView(.animation(minimumInterval: minimumInterval)) { context in
                content(MusicPulse.shared.sample(at: context.date))
            }
        }
    }
}

extension Pulse {
    /// The position timeline content should draw at. An explicit scrub/seek
    /// preview always wins; while the timeline is live, the pulse's
    /// interpolated position glides between playback-clock ticks (~0.5 s
    /// apart) instead of jumping one bar per tick; otherwise the caller's
    /// latest clock value is used verbatim (paused, or motion reduced).
    /// This is the tvOS waveform's glide, shared so every platform's lane
    /// moves the same way.
    func timelinePosition(scrubOverride: TimeInterval?, isLive: Bool, fallback: TimeInterval) -> TimeInterval {
        scrubOverride ?? (isLive ? position : fallback)
    }
}

/// A playback timeline with the tvOS waveform's smooth glide packaged for
/// any platform. The playback clock is observed at this leaf only; each tick
/// re-anchors `MusicPulse` (and feeds it the current envelope), and while
/// playing `content` re-renders at display cadence with a continuously
/// interpolated position — frozen while paused, snapped on seek, and handed
/// to `scrubOverride` verbatim while scrubbing.
struct SmoothPlaybackTimeline<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    var isPlaying: Bool
    var trackID: String? = nil
    var samples: [Float] = []
    var scrubOverride: TimeInterval? = nil
    var reduceMotion: Bool = false
    var minimumInterval: Double = 1.0 / 30.0
    @ViewBuilder var content: (TimeInterval, Pulse) -> Content

    private var isLive: Bool { isPlaying && scrubOverride == nil && !reduceMotion }

    private struct AnchorKey: Equatable {
        var position: TimeInterval
        var isPlaying: Bool
    }

    private struct IngestKey: Equatable {
        var trackID: String?
        var sampleCount: Int
        var durationBucket: Int
    }

    var body: some View {
        PulseTimeline(isActive: isLive, reduceMotion: reduceMotion, minimumInterval: minimumInterval) { pulse in
            content(
                pulse.timelinePosition(scrubOverride: scrubOverride, isLive: isLive, fallback: clock.currentTime),
                pulse
            )
        }
        .onChange(of: AnchorKey(position: clock.currentTime, isPlaying: isPlaying), initial: true) { _, key in
            MusicPulse.shared.anchor(position: key.position, isPlaying: key.isPlaying)
        }
        .onChange(
            of: IngestKey(trackID: trackID, sampleCount: samples.count, durationBucket: Int(clock.duration)),
            initial: true
        ) { _, key in
            MusicPulse.shared.ingest(trackId: key.trackID, samples: samples, duration: clock.duration)
        }
    }
}
