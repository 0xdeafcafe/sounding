import ActivityKit
import SwiftUI
import WidgetKit

struct TVSignInLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TVSignInActivityAttributes.self) { context in
            TVSignInLockScreenView(attributes: context.attributes, phase: context.state.phase)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let phase = context.state.phase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.symbolName)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(.leading, 6)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TVSignInGlyph(phase: phase)
                        .font(.title2)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TVSignInProgress(phase: phase)
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbolName)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            } compactTrailing: {
                TVSignInGlyph(phase: phase)
            } minimal: {
                TVSignInGlyph(phase: phase)
            }
        }
    }
}

struct TVSignInLockScreenView: View {
    let attributes: TVSignInActivityAttributes
    let phase: TVSignInActivityAttributes.Phase

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: attributes.symbolName)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(attributes.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                TVSignInProgress(phase: phase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TVSignInGlyph(phase: phase)
                .font(.title2)
        }
        .environment(\.colorScheme, .dark)
        .padding(16)
    }
}

struct TVSignInProgress: View {
    let phase: TVSignInActivityAttributes.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: phase.progress)
                .tint(phase == .failed ? .red : .white)
                .accessibilityHidden(true)
            Text(phase.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TVSignInGlyph: View {
    let phase: TVSignInActivityAttributes.Phase

    var body: some View {
        Group {
            switch phase {
            case .connecting:
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.white)
            case .waitingForSoundCloud:
                Image(systemName: "hourglass")
                    .foregroundStyle(.white)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .accessibilityLabel(phase.line)
    }
}
