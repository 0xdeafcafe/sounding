import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

struct WidgetArtworkView: View {
    let item: SoundingSnapshot.Item?
    var radius: CGFloat = 10

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var image: CGImage? {
        guard let item, let url = WidgetArtworkStore.url(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

struct WidgetEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct WidgetPlayPauseButton: View {
    let isPlaying: Bool

    var body: some View {
        Button(intent: SetPlaybackIntent(playing: !isPlaying)) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct WidgetSkipButton: View {
    var body: some View {
        Button(intent: SkipTrackIntent()) {
            Image(systemName: "forward.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next Track")
    }
}
