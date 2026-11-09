import SwiftUI

struct NPLyricsScreen: View {
    let track: Track?
    let nextTrack: Track?
    let clock: PlaybackClock
    let isPlaying: Bool
    var accent: Color = Color.white.opacity(0.66)
    let onSeek: (TimeInterval) -> Void

    @State private var playhead = LyricsPlayhead.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .focusable(!lyricsTakeFocus)
                .focusEffectDisabled()
                .padding(.top, 64)
                .padding(.bottom, 8)
            NowPlayingLyrics(track: track, nextTrack: nextTrack, playhead: playhead, style: .tv, onSeek: onSeek)
                .frame(maxWidth: 1380, maxHeight: .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .focusSection()
        }
        .padding(.horizontal, 150)
        .background {
            NPLyricsPlayheadSync(clock: clock, isPlaying: isPlaying, trackID: track?.id, playhead: $playhead)
        }
    }

    private var header: some View {
        HStack(spacing: 26) {
            ArtworkImage(url: track?.artworkURL, identity: track?.id)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(track?.title ?? "")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track?.user.displayName ?? "")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var lyricsTakeFocus: Bool {
        switch LyricsStore.shared.state(for: track?.id) {
        case .needsConsent, .off, .offline, .unavailable:
            return true
        case .loaded(let lyrics):
            if case .instrumental = lyrics.body { return false }
            return true
        case .idle, .loading, .notFound, .mix:
            return false
        }
    }
}

private struct NPLyricsPlayheadSync: View {
    @ObservedObject var clock: PlaybackClock
    let isPlaying: Bool
    let trackID: String?
    @Binding var playhead: LyricsPlayhead

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear { sync(force: true) }
            .onChange(of: clock.currentTime) { _, _ in sync(force: false) }
            .onChange(of: isPlaying) { _, _ in sync(force: true) }
            .onChange(of: trackID) { _, _ in sync(force: true) }
    }

    private func sync(force: Bool) {
        let now = Date()
        #if DEBUG
        if LyricsStore.fixtureState != nil, trackID == nil {
            if playhead.rate == 0 { playhead = LyricsPlayhead(position: 41, date: now, rate: 1) }
            return
        }
        #endif
        let rate: Double = isPlaying ? 1 : 0
        let actual = clock.currentTime
        guard force || rate != playhead.rate || abs(playhead.position(at: now) - actual) > 0.35 else { return }
        playhead = LyricsPlayhead(position: actual, date: now, rate: rate)
    }
}
