import SwiftUI

struct WatchNowPlayingView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scrubPosition: Double = 0
    @State private var lastSyncedPosition: Double = 0
    @State private var isScrubbing = false
    @State private var scrubCommitTask: Task<Void, Never>?
    @FocusState private var isCrownFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            screen(at: context.date)
        }
        .containerBackground(WatchStyle.style.bgRaised.gradient, for: .navigation)
    }

    @ViewBuilder
    private func screen(at date: Date) -> some View {
        let np = link.nowPlaying

        ZStack {
            backdrop(np)

            if np.hasTrack {
                playingContent(np: np, date: date)
            } else {
                WatchEmptyState(
                    systemImage: "music.note",
                    title: "Nothing Playing",
                    message: "Start a track from Listen Now or your Library."
                )
            }
        }
        .onChange(of: date) { _, newDate in
            guard !isScrubbing, np.hasTrack else { return }
            let projected = np.projectedPosition(at: newDate, since: link.nowPlayingReceivedAt)
            lastSyncedPosition = projected
            scrubPosition = projected
        }
    }

    private func playingContent(np: WatchNowPlaying, date: Date) -> some View {
        let duration = max(np.durationSeconds, 1)
        let projected = np.projectedPosition(at: date, since: link.nowPlayingReceivedAt)
        let displayPosition = isScrubbing ? scrubPosition : projected

        return VStack(spacing: 0) {
            header(np)
            Spacer(minLength: WatchStyle.style.spaceTight)
            progress(duration: duration, displayPosition: displayPosition)
            Spacer(minLength: WatchStyle.style.spaceSnug)
            transport(np)
            Spacer(minLength: WatchStyle.style.spaceSnug)
            secondaryRow(np)
        }
        .padding(.horizontal, WatchStyle.style.spaceSnug)
        .padding(.vertical, WatchStyle.style.spaceTight)
        .focusable()
        .focused($isCrownFocused)
        .digitalCrownRotation(
            $scrubPosition,
            from: 0,
            through: duration,
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear { isCrownFocused = true }
        .onChange(of: scrubPosition) { _, newValue in
            guard abs(newValue - lastSyncedPosition) > 0.01 else { return }
            isScrubbing = true
            scrubCommitTask?.cancel()
            scrubCommitTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                link.seek(to: newValue)
                isScrubbing = false
            }
        }
    }

    private func backdrop(_ np: WatchNowPlaying) -> some View {
        ZStack {
            WatchStyle.style.bgRaised

            if let url = np.artworkURL {
                SCArtworkResolver(url: url, variant: .hero) { image in
                    if let image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 20)
                            .scaleEffect(1.2)
                    } else {
                        Color.clear
                    }
                }
            }

            LinearGradient(
                colors: [Color.black.opacity(0.15), Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func header(_ np: WatchNowPlaying) -> some View {
        HStack(spacing: WatchStyle.style.spaceTight) {
            WatchArtwork(url: np.artworkURL, size: 36, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(np.title)
                    .font(WatchStyle.style.fontBodyEmphasis)
                    .foregroundStyle(WatchStyle.style.textPrimary)
                    .lineLimit(1)
                Text(np.artist)
                    .font(WatchStyle.style.fontCaption)
                    .foregroundStyle(WatchStyle.style.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func progress(duration: Double, displayPosition: Double) -> some View {
        let clamped = min(max(displayPosition, 0), duration)

        return VStack(spacing: WatchStyle.style.spaceHair) {
            ProgressView(value: clamped, total: duration)
                .progressViewStyle(.linear)
                .tint(WatchStyle.style.accent)

            HStack {
                Text(clamped.watchClockString)
                Spacer()
                Text("-\(max(duration - clamped, 0).watchClockString)")
            }
            .font(WatchStyle.style.fontCaption)
            .foregroundStyle(WatchStyle.style.textTertiary)
        }
    }

    private func transport(_ np: WatchNowPlaying) -> some View {
        HStack(spacing: WatchStyle.style.spaceRoomy) {
            Button {
                link.transport(.previous)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
            .buttonStyle(.plain)

            Button {
                link.transport(.toggle)
            } label: {
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Button {
                link.transport(.next)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(WatchStyle.style.textPrimary)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: np.isPlaying)
    }

    private func secondaryRow(_ np: WatchNowPlaying) -> some View {
        GlassEffectContainer(spacing: WatchStyle.style.spaceSnug) {
            HStack(spacing: WatchStyle.style.spaceSnug) {
                Button {
                    link.selectOutput(np.output == .tv ? .phone : .tv)
                } label: {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(np.output == .tv ? WatchStyle.style.accent : WatchStyle.style.textPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)

                NavigationLink {
                    WatchUpNextView()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WatchStyle.style.textPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)

                NavigationLink {
                    WatchTrackInfoView()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WatchStyle.style.textPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)

                Button {
                    link.dj(link.djState.isAutoEnabled ? .autoDisable : .autoEnable)
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(link.djState.isAutoEnabled ? WatchStyle.style.accent : WatchStyle.style.textPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
            }
        }
    }
}
