import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

typealias NowPlayingActivityState = NowPlayingActivityAttributes.ContentState

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            NowPlayingActivityContent(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(context.state.backgroundColor)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityFocusIcon(state: state)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityFocusTrailing(state: state, countdownFont: .title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    ActivityFocusHeadline(state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityFocusFooter(state: state, isStale: context.isStale, showsArtwork: false)
                        .padding(.top, 2)
                }
            } compactLeading: {
                ActivityFocusIcon(state: state)
            } compactTrailing: {
                ActivityFocusTrailing(state: state, countdownFont: .caption.weight(.semibold), compact: true)
                    .frame(maxWidth: 52)
            } minimal: {
                ActivityFocusIcon(state: state)
            }
            .keylineTint(state.tintColor)
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

// MARK: - Lock Screen

struct NowPlayingActivityContent: View {
    @Environment(\.activityFamily) private var family

    let state: NowPlayingActivityState
    let isStale: Bool

    var body: some View {
        switch family {
        case .small:
            NowPlayingCompactActivityView(state: state, isStale: isStale)
        default:
            NowPlayingLockScreenView(state: state, isStale: isStale)
        }
    }
}

struct NowPlayingCompactActivityView: View {
    let state: NowPlayingActivityState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 10) {
            ActivityArtwork(file: state.artworkFile, side: 44, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(state.tintColor)
                    .lineLimit(1)
                progress
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: state.isPlaying && !isStale ? "waveform" : "pause.fill")
                .font(.title3)
                .foregroundStyle(state.tintColor)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.title), \(state.artist), \(state.isPlaying && !isStale ? "playing" : "paused")")
    }

    private var subtitle: String {
        if state.focus == .autoMix, let next = state.nextTitle {
            return "Next: \(next)"
        }
        return state.artist
    }

    @ViewBuilder
    private var progress: some View {
        if state.isPlaying, !isStale, let range = state.timerRange, range.upperBound > .now {
            ProgressView(timerInterval: range, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(state.tintColor)
        } else {
            ProgressView(value: state.pausedProgress)
                .tint(state.tintColor)
        }
    }
}

struct NowPlayingLockScreenView: View {
    let state: NowPlayingActivityState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ActivityFocusLabel(state: state)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActivityFocusTrailing(state: state, countdownFont: .title2.weight(.semibold))
            }
            ActivityFocusHeadline(state: state)
            ActivityFocusFooter(state: state, isStale: isStale, showsArtwork: true)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Focus

extension NowPlayingActivityState {
    var focusSymbol: String {
        switch focus {
        case .autoMix: "arrow.triangle.merge"
        case .inMix: "music.note.list"
        case .sleep, nil: "moon.zzz.fill"
        }
    }

    var focusTitle: String {
        switch focus {
        case .autoMix: "Auto Mix"
        case .inMix: "In This Mix"
        case .sleep, nil: "Sleep Timer"
        }
    }

    var focusCountdownDate: Date? {
        let date: Date?
        switch focus {
        case .autoMix: date = mixDate
        case .sleep: date = sleepEndsAt
        case .inMix, nil: date = nil
        }
        guard let date, date > .now else { return nil }
        return date
    }
}

struct ActivityFocusIcon: View {
    let state: NowPlayingActivityState

    var body: some View {
        Image(systemName: state.focusSymbol)
            .foregroundStyle(state.tintColor)
            .accessibilityLabel(state.focusTitle)
    }
}

struct ActivityFocusLabel: View {
    let state: NowPlayingActivityState

    var body: some View {
        Label {
            Text(state.focusTitle)
        } icon: {
            Image(systemName: state.focusSymbol)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(state.tintColor)
        .lineLimit(1)
    }
}

struct ActivityFocusTrailing: View {
    let state: NowPlayingActivityState
    let countdownFont: Font
    var compact = false

    var body: some View {
        if let date = state.focusCountdownDate {
            Text(timerInterval: Date.now...date, countsDown: true)
                .font(countdownFont)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(minWidth: compact ? 40 : 64, alignment: .trailing)
        } else if let position = state.inMixPosition, state.focus == .inMix {
            Text(position)
                .font(compact ? .caption2 : .subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}

struct ActivityFocusHeadline: View {
    let state: NowPlayingActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch state.focus {
            case .autoMix:
                if let move = state.moveLine {
                    Text(move)
                        .font(.headline)
                        .lineLimit(2)
                    if let next = state.nextTitle {
                        Text("Next: \(next)")
                            .font(.subheadline)
                            .foregroundStyle(state.tintColor)
                            .lineLimit(1)
                    }
                } else if let next = state.nextTitle {
                    Text("Next: \(next)")
                        .font(.headline)
                        .lineLimit(2)
                }
            case .inMix:
                if let title = state.inMixTitle {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                }
                if let artist = state.inMixArtist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(state.tintColor)
                        .lineLimit(1)
                }
            case .sleep, nil:
                Text("Fades out, then pauses")
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActivityFocusFooter: View {
    let state: NowPlayingActivityState
    let isStale: Bool
    let showsArtwork: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsArtwork {
                ActivityArtwork(file: state.artworkFile, side: 28, radius: 6)
            }
            Text(context)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isStale {
                if state.focus != .sleep, let sleep = state.sleepEndsAt, sleep > .now {
                    ActivitySleepCountdown(sleepEndsAt: sleep)
                }
                if state.focus == .autoMix, state.focusCountdownDate != nil {
                    ActivityMixNowButton()
                }
            }
        }
    }

    private var context: String {
        switch state.focus {
        case .inMix: "\(state.title) · \(state.artist)"
        default: "\(state.title) – \(state.artist)"
        }
    }
}

struct ActivitySleepCountdown: View {
    let sleepEndsAt: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz.fill")
                .imageScale(.small)
                .accessibilityLabel("Sleep timer")
            Text(timerInterval: Date.now...sleepEndsAt, countsDown: true)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.7))
    }
}

struct ActivityMixNowButton: View {
    var body: some View {
        Button(intent: MixNowIntent()) {
            Text("Mix Now")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct ActivityArtwork: View {
    let file: String?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.14)
                    Image(systemName: "waveform")
                        .font(.system(size: side * 0.4))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var image: UIImage? {
        guard let file, let url = LiveActivityArtworkStore.url(for: file) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

extension NowPlayingActivityAttributes.ContentState {
    var tintColor: Color {
        guard let tint, tint.count == 3 else { return .white.opacity(0.85) }
        return Color(red: tint[0], green: tint[1], blue: tint[2])
    }

    var backgroundColor: Color {
        guard let tint, tint.count == 3 else { return Color(white: 0.08) }
        return Color(red: tint[0] * 0.28 + 0.03, green: tint[1] * 0.28 + 0.03, blue: tint[2] * 0.28 + 0.03)
    }
}
