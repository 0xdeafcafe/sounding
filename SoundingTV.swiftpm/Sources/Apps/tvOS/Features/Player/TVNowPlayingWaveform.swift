import SwiftUI
import UIKit

struct NPWaveform: View {
    let track: Track?
    let clock: PlaybackClock
    @ObservedObject var comments: TrackCommentsStore
    let isPlaying: Bool
    let isActive: Bool
    let accent: Color
    let entries: [TracklistEntry]
    let showsBubble: Bool
    let reduceMotion: Bool
    var focus: FocusState<NPFocus?>.Binding
    let onTogglePlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void

    @ObservedObject private var waveforms = WaveformService.shared

    @State private var bars: [Float] = []
    @State private var images = NPBarImages.placeholder
    @State private var timed: [Comment] = []
    @State private var preview: TimeInterval?
    @State private var restingPosition: TimeInterval = 0
    @State private var commitTask: Task<Void, Never>?
    @State private var panAnchor: TimeInterval?
    @State private var isPanning = false
    @State private var suppressMoves = false
    @State private var moveCooldownTask: Task<Void, Never>?

    fileprivate static let width: CGFloat = 1920 - Space.page * 2
    private static let height: CGFloat = 76
    private static let pitch: CGFloat = 6.2
    private static let barWidth: CGFloat = 3.4
    private static let minimumBar: CGFloat = 0.08
    private static let labelRow: CGFloat = 36
    private static let dotRow: CGFloat = 28
    static let tapeThreshold: TimeInterval = 360
    private static let tapeWindow: TimeInterval = 450

    private var isTape: Bool { duration >= Self.tapeThreshold }

    private var duration: TimeInterval { max(clock.duration, track?.duration ?? 0) }
    private var isFocused: Bool { focus.wrappedValue == .wave }

    private struct BarsKey: Equatable {
        let trackId: String?
        let sampleCount: Int
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: tickInterval, paused: !isPlaying || !isActive || preview != nil)) { context in
            let position = displayedPosition(at: context.date)
            let active = showsBubble && preview == nil ? activeComment(at: position) : nil
            VStack(spacing: 0) {
                NPTapeLabels(entries: entries, position: position, pinsCurrent: isTape, x: { x(for: $0, at: position) })
                    .frame(width: Self.width, height: Self.labelRow)
                scrubLane(position: position, bubbleComment: active)
                NPTapeDots(entries: entries, comments: timed, accent: accent, x: { x(for: $0, at: position) })
                    .frame(width: Self.width, height: Self.dotRow)
                times(position: position, hidesHint: active != nil)
            }
            .frame(width: Self.width)
        }
        .task(id: BarsKey(trackId: track?.id, sampleCount: waveformSamples?.count ?? 0)) {
            bars = Self.makeBars(from: waveformSamples)
            images = NPBarImages(bars: bars)
        }
        .task(id: track?.id) {
            guard let track else { return }
            waveforms.load(track)
        }
        .onReceive(clock.$currentTime) { time in
            if !isPlaying { restingPosition = time }
        }
        .onChange(of: isPlaying, initial: true) { _, _ in
            restingPosition = clock.currentTime
        }
        .onChange(of: comments.comments.count, initial: true) { _, _ in
            timed = comments.timedComments
        }
        .onChange(of: track?.id) { _, _ in
            resetScrub()
            timed = comments.timedComments
        }
    }

    private func scrubLane(position: TimeInterval, bubbleComment: Comment?) -> some View {
        lane(position: position)
            .frame(width: Self.width, height: Self.height)
            .scaleEffect(x: 1, y: isFocused ? 1.28 : 1)
            .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
            .overlay(alignment: .topLeading) { bubble(bubbleComment) }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .focusable()
            .focused(focus, equals: .wave)
            .focusEffectDisabled()
            .background(
                RemoteScrubSurface(
                    isActive: isFocused && duration > 0,
                    capturesExit: isPanning || preview != nil,
                    onBegan: beginPan,
                    onChanged: { preview = panTime(for: $0) },
                    onEnded: endPan,
                    onCancelled: cancelPan,
                    onExit: cancelScrub
                )
                .allowsHitTesting(false)
            )
            .onTapGesture(perform: click)
            .onMoveCommand { direction in
                guard !suppressMoves else { return }
                switch direction {
                case .left: scrub(by: -step)
                case .right: scrub(by: step)
                default: break
                }
            }
            .onPlayPauseCommand(perform: onTogglePlayPause)
            .onExitCommand(perform: scrubExit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(DJFormat.time(preview ?? position)) of \(DJFormat.time(duration))")
            .accessibilityHint(isTape ? "Swipe or press left or right to move the tape. Click to play from there." : "Press left or right to scrub. Click to play or pause.")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAdjustableAction { direction in
                let jump = max(10, duration / 50)
                let base = preview ?? clock.currentTime
                let target: TimeInterval
                switch direction {
                case .increment: target = min(max(duration, 0), base + jump)
                case .decrement: target = max(0, base - jump)
                @unknown default: return
                }
                preview = nil
                commitTask?.cancel()
                onSeek(target)
            }
    }

    private var step: TimeInterval {
        if isTape { return Self.tapeWindow / 16 }
        return duration > 900 ? 30 : 10
    }

    private var tickInterval: TimeInterval {
        if isTape { return reduceMotion ? 1 : 0.25 }
        if duration > 1200 { return 2 }
        return duration > 400 ? 1 : 0.5
    }

    private var waveformSamples: [Float]? {
        guard let track else { return nil }
        return waveforms.state(for: track.id).waveform?.samples
    }

    private static func makeBars(from samples: [Float]?) -> [Float] {
        guard let samples, !samples.isEmpty else { return [] }
        let count = Int(width / pitch)
        return SCWaveformSampler.resample(SCWaveformSampler.visuallyNormalized(samples, floor: 0.08), toCount: count)
    }

    fileprivate static let layout = (width: width, height: height, pitch: pitch, barWidth: barWidth, minimumBar: minimumBar)

    private func x(for time: TimeInterval, at position: TimeInterval) -> CGFloat {
        guard duration > 0 else { return -1 }
        if isTape {
            let window = min(Self.tapeWindow, duration)
            return Self.width / 2 + CGFloat((time - position) / window) * Self.width
        }
        return CGFloat(time / duration) * Self.width
    }

    private func displayedPosition(at date: Date) -> TimeInterval {
        if let preview { return preview }
        guard isPlaying else { return restingPosition }
        let elapsed = max(0, date.timeIntervalSince(clock.updatedAt))
        return min(max(duration, 0), clock.currentTime + elapsed)
    }

    @ViewBuilder
    private func lane(position: TimeInterval) -> some View {
        if isTape {
            tapeLane(position: position)
        } else {
            barLane(position: position)
        }
    }

    private func tapeLane(position: TimeInterval) -> some View {
        SCWaveformRenderer(
            envelope: waveformSamples ?? [],
            duration: duration,
            progress: duration > 0 ? position / duration : 0,
            mode: .centered(windowSeconds: min(Self.tapeWindow, duration)),
            cueMarkers: [],
            playheadEmphasis: preview == nil ? 0 : 1,
            placeholder: .loading,
            identity: track?.id,
            motionSuppressed: reduceMotion,
            style: .tv
        )
        .frame(width: Self.width, height: Self.height)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .accessibilityHidden(true)
    }

    private func barLane(position: TimeInterval) -> some View {
        let progress = duration > 0 ? min(1, max(0, position / duration)) : 0
        return ZStack(alignment: .leading) {
            Image(uiImage: images.unplayed)
            Image(uiImage: images.played)
                .frame(width: Self.width, height: Self.height, alignment: .leading)
                .frame(width: Self.width * progress, height: Self.height, alignment: .leading)
                .clipped()
        }
        .accessibilityHidden(true)
    }

    private func times(position: TimeInterval, hidesHint: Bool) -> some View {
        HStack {
            Text(NPFormat.time(position))
            Spacer()
            Text(hint)
                .font(.caption2.weight(.medium))
                .opacity(isFocused && !hidesHint ? 0.7 : 0)
            Spacer()
            Text("\u{2212}\(NPFormat.time(max(0, duration - position)))")
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.52))
        .frame(height: 30)
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(NPFormat.time(position)) elapsed, \(NPFormat.time(max(0, duration - position))) remaining")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func bubble(_ comment: Comment?) -> some View {
        if let comment, let time = comment.timeInTrack, duration > 0 {
            let x = isTape ? Self.width / 2 : Self.width * min(1, max(0, time / duration))
            let left = min(max(x - 110, 110), Self.width - 110 - 360)
            NPCommentBubble(comment: comment, maxWidth: min(640, Self.width - 110 - left - 110))
                .offset(x: left, y: Self.height + 8 + Self.dotRow + 4)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                .id(comment.id)
                .allowsHitTesting(false)
        }
    }

    private func activeComment(at position: TimeInterval) -> Comment? {
        guard !timed.isEmpty else { return nil }
        var low = 0
        var high = timed.count - 1
        var found: Comment?
        while low <= high {
            let mid = (low + high) / 2
            if (timed[mid].timeInTrack ?? 0) <= position + 0.5 {
                found = timed[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let found, let time = found.timeInTrack, position - time <= 4 else { return nil }
        return found
    }

    private var hint: String {
        if isTape, preview != nil { return "Click to Play from Here" }
        return "\u{25C0} \u{25B6} to scrub"
    }

    private func click() {
        if preview != nil {
            commit(after: .zero)
        } else {
            onTogglePlayPause()
        }
    }

    private func scrub(by delta: TimeInterval) {
        let base = preview ?? clock.currentTime
        preview = min(max(0, base + delta), max(duration, 0))
        scheduleCommit()
    }

    private func scheduleCommit() {
        commit(after: isTape ? .seconds(6) : .milliseconds(550))
    }

    private func commit(after delay: Duration) {
        commitTask?.cancel()
        commitTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let target = preview else { return }
            onSeek(target)
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            preview = nil
        }
    }

    private var scrubExit: (() -> Void)? {
        guard preview != nil || isPanning else { return nil }
        return cancelScrub
    }

    private func cancelScrub() {
        guard preview != nil || isPanning else { return }
        resetScrub()
    }

    private func resetScrub() {
        preview = nil
        commitTask?.cancel()
        moveCooldownTask?.cancel()
        panAnchor = nil
        isPanning = false
        suppressMoves = false
    }

    private func panTime(for translation: CGFloat) -> TimeInterval {
        RemoteScrub.time(
            from: panAnchor ?? clock.currentTime,
            translation: translation,
            duration: duration,
            span: isTape ? Self.tapeWindow : nil
        )
    }

    private func beginPan() {
        commitTask?.cancel()
        moveCooldownTask?.cancel()
        panAnchor = preview ?? clock.currentTime
        isPanning = true
        suppressMoves = true
    }

    private func endPan(_ translation: CGFloat) {
        preview = panTime(for: translation)
        panAnchor = nil
        isPanning = false
        scheduleCommit()
        releaseMoveSuppression()
    }

    private func cancelPan() {
        panAnchor = nil
        isPanning = false
        if preview != nil { scheduleCommit() }
        releaseMoveSuppression()
    }

    private func releaseMoveSuppression() {
        moveCooldownTask?.cancel()
        moveCooldownTask = Task {
            try? await Task.sleep(for: RemoteScrub.moveCooldown)
            guard !Task.isCancelled else { return }
            suppressMoves = false
        }
    }
}

private struct NPBarImages {
    let unplayed: UIImage
    let played: UIImage

    init(bars: [Float]) {
        unplayed = NPBarImage.render(bars: bars, color: UIColor.white.withAlphaComponent(0.3))
        played = NPBarImage.render(bars: bars, color: UIColor.white.withAlphaComponent(0.95))
    }

    @MainActor static let placeholder = NPBarImages(bars: [])
}

private enum NPBarImage {
    static func render(bars: [Float], color: UIColor) -> UIImage {
        let layout = NPWaveform.layout
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: layout.width, height: layout.height), format: format)
        let count = bars.isEmpty ? Int(layout.width / layout.pitch) : bars.count
        return renderer.image { context in
            color.setFill()
            for index in 0..<count {
                let value = bars.isEmpty ? 0.16 : CGFloat(bars[index])
                let barHeight = max(layout.barWidth, max(layout.minimumBar, value) * layout.height)
                let x = CGFloat(index) * layout.pitch + (layout.pitch - layout.barWidth) / 2
                let rect = CGRect(x: x, y: (layout.height - barHeight) / 2, width: layout.barWidth, height: barHeight)
                UIBezierPath(roundedRect: rect, cornerRadius: layout.barWidth / 2).fill()
            }
        }
    }
}

private struct NPTapeLabels: View {
    let entries: [TracklistEntry]
    let position: TimeInterval
    let pinsCurrent: Bool
    let x: (TimeInterval) -> CGFloat

    private struct Slot {
        let x: CGFloat
        let label: String
        let hasTick: Bool
    }

    var body: some View {
        Canvas { context, size in
            guard !entries.isEmpty else { return }
            var slots: [Slot] = []
            let currentIndex = entries.lastIndex { $0.startSeconds <= position }
            if let currentIndex {
                let entry = entries[currentIndex]
                let px = x(entry.startSeconds)
                if pinsCurrent, px < 0 {
                    slots.append(Slot(x: 0, label: entry.segment.displayLabel, hasTick: false))
                } else if px >= 0, px <= size.width {
                    slots.append(Slot(x: px, label: entry.segment.displayLabel, hasTick: true))
                }
            }
            let upcoming = currentIndex.map { $0 + 1 } ?? 0
            for entry in entries[upcoming...] {
                let px = x(entry.startSeconds)
                guard px >= 0 else { continue }
                guard px <= size.width else { break }
                slots.append(Slot(x: px, label: entry.segment.displayLabel, hasTick: true))
            }
            for (index, slot) in slots.enumerated() {
                let next = index + 1 < slots.count ? slots[index + 1].x : size.width
                let textX = slot.x + (slot.hasTick ? 14 : 0)
                let available = next - textX - 20
                guard available > 48 else { continue }
                if slot.hasTick {
                    context.fill(
                        Path(CGRect(x: slot.x - 1, y: size.height * 0.25, width: 2, height: size.height * 0.75)),
                        with: .color(.white.opacity(0.55))
                    )
                }
                var clipped = context
                clipped.clip(to: Path(CGRect(x: textX, y: 0, width: available, height: size.height)))
                let text = Text(slot.label).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.72))
                clipped.draw(clipped.resolve(text), at: CGPoint(x: textX, y: size.height / 2), anchor: .leading)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct NPTapeDots: View {
    let entries: [TracklistEntry]
    let comments: [Comment]
    let accent: Color
    let x: (TimeInterval) -> CGFloat

    private static let bucket: CGFloat = 96

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            for entry in entries where entry.startSeconds > 0 {
                let px = x(entry.startSeconds)
                guard px >= 0, px <= size.width else { continue }
                context.fill(Path(ellipseIn: CGRect(x: px - 6, y: midY - 6, width: 12, height: 12)), with: .color(accent.opacity(0.9)))
            }
            guard !comments.isEmpty else { return }
            var buckets: [Int: (x: CGFloat, count: Int)] = [:]
            for comment in comments {
                guard let time = comment.timeInTrack else { continue }
                let px = x(time)
                guard px >= 0, px <= size.width else { continue }
                let key = Int(px / Self.bucket)
                if let existing = buckets[key] {
                    buckets[key] = (existing.x, existing.count + 1)
                } else {
                    buckets[key] = (px, 1)
                }
            }
            for (_, bucket) in buckets {
                let side = 8 + CGFloat(min(bucket.count, 5)) * 1.6
                let opacity = min(0.35 + Double(bucket.count) * 0.08, 0.75)
                context.fill(Path(ellipseIn: CGRect(x: bucket.x - side / 2, y: midY - side / 2, width: side, height: side)), with: .color(.white.opacity(opacity)))
            }
        }
        .accessibilityHidden(true)
    }
}

struct NPCommentBubble: View {
    let comment: Comment
    var maxWidth: CGFloat = 640

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: comment.user.avatarURL, icon: "person.fill", identity: comment.user.id)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .kyleCrowned(user: comment.user, context: comment.user.displayName)
            Text(comment.body)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, 22)
        .padding(.vertical, 8)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(Capsule().fill(Color.black.opacity(0.3)))
        .accessibilityHidden(true)
    }
}

enum NPFormat {
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, !seconds.isNaN else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
