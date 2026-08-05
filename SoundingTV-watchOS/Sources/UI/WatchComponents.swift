import SwiftUI

enum WatchStyle {
    static let style = SCContentStyle.watch
    static let rowCorner: CGFloat = 10
    static let artwork: CGFloat = 34
}

struct WatchArtwork: View {
    let url: URL?
    var size: CGFloat = WatchStyle.artwork
    var corner: CGFloat = 7
    var identity: String? = nil

    var body: some View {
        SCArtworkResolver(url: url, variant: .standard) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let identity, !identity.isEmpty {
                GeneratedArtworkCard(identity: identity, style: .watch, isAnimated: false)
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(WatchStyle.style.bgOverlay)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.36, weight: .semibold))
                            .foregroundStyle(WatchStyle.style.textTertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct WatchTrackRow: View {
    let title: String
    let subtitle: String
    var artworkURL: URL?
    var isPlaying = false
    var trailingSystemImage: String?

    var body: some View {
        HStack(spacing: WatchStyle.style.spaceTight) {
            WatchArtwork(url: artworkURL, identity: title)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(WatchStyle.style.fontBodyEmphasis)
                    .foregroundStyle(isPlaying ? WatchStyle.style.accent : WatchStyle.style.textPrimary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WatchStyle.style.accent)
            } else if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WatchStyle.style.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct WatchDestinationRow: View {
    let title: String
    let systemImage: String
    var tint: Color = WatchStyle.style.accent

    var body: some View {
        HStack(spacing: WatchStyle.style.spaceTight) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(title)
                .font(WatchStyle.style.fontBodyEmphasis)
                .foregroundStyle(WatchStyle.style.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct WatchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(WatchStyle.style.fontEyebrow)
            .foregroundStyle(WatchStyle.style.textTertiary)
            .padding(.top, WatchStyle.style.spaceTight)
    }
}

struct WatchEmptyState: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: WatchStyle.style.spaceTight) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(WatchStyle.style.textTertiary)
            Text(title)
                .font(WatchStyle.style.fontBodyEmphasis)
                .foregroundStyle(WatchStyle.style.textSecondary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(WatchStyle.style.fontCaption)
                    .foregroundStyle(WatchStyle.style.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WatchStyle.style.spaceRoomy)
    }
}

struct WatchGlassPanel<Content: View>: View {
    var corner: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(WatchStyle.style.spaceTight)
            .glassEffect(.regular, in: .rect(cornerRadius: corner))
    }
}

struct WatchLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, WatchStyle.style.spaceTight)
    }
}

extension TimeInterval {
    var watchClockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Int64 {
    var watchByteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
