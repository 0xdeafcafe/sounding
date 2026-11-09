import SwiftUI

enum NowPlayingTape {
    static let threshold: TimeInterval = 360

    @MainActor
    static func isActive(router: NowPlayingRouter, trackId: String?, duration: TimeInterval) -> Bool {
        duration >= threshold || (trackId != nil && router.tapeZoomTrackId == trackId)
    }

    static func style(isPad: Bool, timesHeight: CGFloat) -> TapeScrubberStyle {
        isPad
            ? TapeScrubberStyle(waveHeight: 40, labelHeight: 20, labelGap: 8, avatarSize: 20, avatarGap: 6, timesGap: 8, timesHeight: max(timesHeight, 18), labelFont: .footnote, timeFont: .footnote.weight(.medium), pitch: 4)
            : TapeScrubberStyle(waveHeight: 36, labelHeight: 18, labelGap: 6, avatarSize: 20, avatarGap: 6, timesGap: 8, timesHeight: timesHeight)
    }

    static func entries(_ tracklist: Tracklist?) -> [TapeEntry] {
        (tracklist?.entries ?? []).map { entry in
            let parts = NowPlayingSegmentText.parts(entry.segment)
            let placeholders: Set<String> = ["id", "unidentified", "unknown"]
            if NowPlayingSegmentText.isUnknown(entry.segment)
                || (placeholders.contains(parts.title.lowercased()) && placeholders.contains(parts.artist?.lowercased() ?? "id")) {
                return TapeEntry(id: entry.id, start: entry.startSeconds, title: "ID", artist: nil)
            }
            return TapeEntry(id: entry.id, start: entry.startSeconds, title: parts.title, artist: parts.artist)
        }
    }

    static func comments(_ comments: [Comment]) -> [TapeComment] {
        comments
            .compactMap { comment in
                comment.timeInTrack.map {
                    TapeComment(id: comment.id, time: $0, body: comment.body, avatarURL: comment.user.avatarURL, name: comment.user.displayName)
                }
            }
            .sorted { $0.time < $1.time }
    }
}

struct NowPlayingTapeScrubber: View {
    let timeline: NowPlayingTimeline
    let trackId: String?
    let tint: Color
    let onSeek: (TimeInterval) -> Void
    @ObservedObject var store: PhoneWaveformStore
    var style = TapeScrubberStyle()
    var bleed = TapeBleed()
    var compact = false
    var initialSpan: TimeInterval = 240
    var onZoomOutToFit: (() -> Void)?

    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @ObservedObject private var trims = TrackTrimStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var peaks: TapeWaveformPeaks?
    @State private var entries: [TapeEntry] = []
    @State private var comments: [TapeComment] = []

    private var duration: TimeInterval { max(timeline.anchor.duration, 1) }

    private struct PeaksKey: Equatable {
        let waveform: PhoneWaveformState
        let duration: TimeInterval
    }

    private struct CommentsKey: Equatable {
        let trackId: String?
        let comments: TimedComments.Key
    }

    var body: some View {
        let anchor = timeline.anchor
        TapeScrubber(
            clock: TapeClock(position: anchor.position, date: anchor.date, rate: anchor.rate, duration: anchor.duration),
            isActive: scenePhase == .active,
            peaks: peaks,
            trim: TrackTrimTimeline(range: trims.effectiveRange(for: trackId ?? "", duration: duration), duration: duration),
            entries: entries,
            comments: comments,
            style: style,
            bleed: bleed,
            compact: compact,
            initialSpan: initialSpan,
            bubbleTint: tint,
            startsScrubbing: Self.debugShot == "scrub",
            showsBubbleOnAppear: Self.debugShot == "bubble",
            onSeek: onSeek,
            onScrubChange: { value in
                if timeline.scrubPreview != value { timeline.scrubPreview = value }
            },
            onZoomOutToFit: onZoomOutToFit
        ) { comment, size in
            NowPlayingAvatar(url: comment.avatarURL, name: comment.name, size: size)
        }
        .id(trackId)
        .task(id: PeaksKey(waveform: store.waveform, duration: duration)) {
            await rebuildPeaks()
        }
        .task(id: setlists.tracklist(for: trackId)) {
            entries = NowPlayingTape.entries(setlists.tracklist(for: trackId))
        }
        .task(id: CommentsKey(trackId: trackId, comments: TimedComments.Key(store.comments))) {
            comments = NowPlayingTape.comments(store.comments)
        }
        .onDisappear {
            if timeline.scrubPreview != nil { timeline.scrubPreview = nil }
        }
    }

    private static var debugShot: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_NP_SHOT"]
        #else
        nil
        #endif
    }

    private func rebuildPeaks() async {
        guard let samples = store.waveform.samples, !samples.isEmpty, timeline.anchor.duration > 0 else {
            peaks = nil
            return
        }
        let duration = timeline.anchor.duration
        let built = await Task.detached(priority: .userInitiated) {
            TapeWaveformPeaks.build(samples: SCWaveformSampler.visuallyNormalized(samples, floor: 0.10), duration: duration)
        }.value
        guard !Task.isCancelled else { return }
        peaks = built
    }
}
