import SwiftUI

struct WatchDJView: View {
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(at: context.date)
        }
        .navigationTitle("Auto DJ")
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.22), for: .navigation)
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let dj = link.djState
        let mixIn = dj.projectedMixIn(at: date, since: link.djStateReceivedAt)

        ScrollView {
            VStack(spacing: WatchStyle.style.spaceSnug) {
                engineStatusPanel(dj)
                nextTrackPanel(dj, mixIn: mixIn)
                controlsPanel(dj)
            }
            .padding(.horizontal, WatchStyle.style.spaceSnug)
            .padding(.vertical, WatchStyle.style.spaceTight)
        }
    }

    private func engineStatusPanel(_ dj: WatchDJState) -> some View {
        WatchGlassPanel(corner: WatchStyle.style.cornerCard) {
            HStack(spacing: WatchStyle.style.spaceTight) {
                WatchArtwork(url: link.nowPlaying.artworkURL, size: 36, corner: 9)

                VStack(alignment: .leading, spacing: 1) {
                    Text(dj.isEngineLive ? "Engine Live" : "Engine Idle")
                        .font(WatchStyle.style.fontBodyEmphasis)
                        .foregroundStyle(WatchStyle.style.textPrimary)
                    Text(dj.isEngineLive ? "Mixing on iPhone" : "Not mixing")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textSecondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func controlsPanel(_ dj: WatchDJState) -> some View {
        WatchGlassPanel(corner: WatchStyle.style.cornerCard) {
            VStack(spacing: WatchStyle.style.spaceSnug) {
                Toggle(isOn: Binding(
                    get: { dj.isAutoEnabled },
                    set: { link.dj($0 ? .autoEnable : .autoDisable) }
                )) {
                    Text("Auto DJ")
                        .font(WatchStyle.style.fontBodyEmphasis)
                        .foregroundStyle(WatchStyle.style.textPrimary)
                }
                .tint(WatchStyle.style.accent)
            }
        }
    }

    private func nextTrackPanel(_ dj: WatchDJState, mixIn: TimeInterval?) -> some View {
        WatchGlassPanel(corner: WatchStyle.style.cornerCard) {
            VStack(alignment: .leading, spacing: WatchStyle.style.spaceTight) {
                WatchSectionHeader(title: "Next")

                if let nextTitle = dj.nextTitle {
                    WatchTrackRow(
                        title: nextTitle,
                        subtitle: dj.nextArtist ?? "",
                        artworkURL: dj.nextArtworkURL,
                        trailingSystemImage: "arrow.turn.down.right"
                    )
                } else {
                    Text("Nothing queued yet")
                        .font(WatchStyle.style.fontBody)
                        .foregroundStyle(WatchStyle.style.textSecondary)
                }

                if let mixIn {
                    Text("Mixing in \(mixIn.watchClockString)")
                        .font(WatchStyle.style.fontCaptionEmphasis)
                        .foregroundStyle(WatchStyle.style.accent)
                } else {
                    Text("Mix not planned yet")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textTertiary)
                }

                if let reasoning = dj.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textSecondary)
                }

                Button {
                    link.dj(.mixNow)
                } label: {
                    Label("Mix Now", systemImage: "bolt.fill")
                        .font(WatchStyle.style.fontCaptionEmphasis)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchStyle.style.accent)
                .disabled(dj.nextTitle == nil)
                .accessibilityHint("Starts the transition immediately")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
