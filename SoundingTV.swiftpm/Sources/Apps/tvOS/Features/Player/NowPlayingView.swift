import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var navigationState: NavigationState
    @StateObject private var recap = NowPlayingRecapModel()
    @FocusState private var focus: NowPlayingEmptyFocus?

    var body: some View {
        if showsEmptyState {
            emptyState
        } else {
            PlayerView()
        }
    }

    private var showsEmptyState: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_FORCE_EMPTY_NOWPLAYING"] == "1" {
            return true
        }
        #endif
        return playerService.currentTrack == nil
    }

    private var emptyState: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.section) {
                hero
                    .focusSection()

                if !recap.recentTracks.isEmpty {
                    shelf(title: "Recently Played", tracks: recap.recentTracks)
                }
                if !recap.suggestedTracks.isEmpty {
                    shelf(title: "From Your Stream", tracks: recap.suggestedTracks)
                }
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .padding(.bottom, Space.section)
            .scrollTargetLayout()
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .defaultFocus($focus, .browse)
        .onAppear { DispatchQueue.main.async { focus = .browse } }
        .task { await recap.loadIfNeeded() }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: Space.section) {
            ZStack {
                Circle()
                    .fill(Color.scAccentMuted)
                Image(systemName: "waveform")
                    .font(.system(size: 72, weight: .heavy))
                    .foregroundStyle(Color.scAccent)
                    .symbolEffect(.pulse)
            }
            .frame(width: 176, height: 176)

            VStack(alignment: .leading, spacing: Space.snug) {
                Text("Nothing Playing")
                    .font(.tvDisplay)
                    .foregroundStyle(Color.scTextPrimary)
                    .kerning(-1.5)

                Text(subtitle)
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)

                BrowseHomeButton(focused: $focus, tag: .browse) {
                    navigationState.selectedTab = .home
                }
                .accessibilityIdentifier("nowplaying.empty.browseHome")
                .padding(.top, Space.tight)
            }
        }
        .padding(.horizontal, Space.page)
    }

    private var subtitle: String {
        recap.recentTracks.isEmpty && recap.suggestedTracks.isEmpty
            ? "Pick a track from Home or Search to get started."
            : "Pick up where you left off, or start something new from Home or Search."
    }

    @ViewBuilder
    private func shelf(title: String, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(title)
                .font(.tvSection)
                .foregroundStyle(Color.scTextPrimary)
                .padding(.horizontal, Space.page)

            TrackShelf(tracks: tracks)
        }
        .focusSection()
    }
}

fileprivate enum NowPlayingEmptyFocus: Hashable { case browse }

private struct BrowseHomeButton: View {
    var focused: FocusState<NowPlayingEmptyFocus?>.Binding
    let tag: NowPlayingEmptyFocus
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isFocused: Bool { focused.wrappedValue == tag }

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "house.fill")
            Text("Browse Home")
        }
        .font(.tvBodyEmph)
        .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scAccentOn)
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.snug)
        .background(Capsule(style: .continuous).fill(isFocused ? Color.scChromeFocus : Color.scAccent))
        .contentShape(Capsule())
        .focusable()
        .focused(focused, equals: tag)
        .focusEffectDisabled()
        .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
        .onTapGesture(perform: action)
    }
}

@MainActor
final class NowPlayingRecapModel: ObservableObject {
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var suggestedTracks: [Track] = []

    private var didLoad = false

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true

        guard let snapshot = TopShelfStore.load() else { return }

        async let recents = Self.resolve(snapshot.section(kind: TopShelfStore.recentsKind))
        async let suggested = Self.resolve(snapshot.section(kind: "stream"))

        recentTracks = await recents
        let recentIDs = Set(recentTracks.map(\.id))
        suggestedTracks = await suggested.filter { !recentIDs.contains($0.id) }
    }

    private static func resolve(_ section: TopShelfSection?) async -> [Track] {
        guard let entries = section?.entries, !entries.isEmpty else { return [] }
        let ids = entries.map { rawTrackID(from: $0.id) }
        guard let tracks = try? await SoundCloudAPI.shared.getTracks(ids: ids) else { return [] }

        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    private static func rawTrackID(from entryID: String) -> String {
        guard let colon = entryID.firstIndex(of: ":") else { return entryID }
        return String(entryID[entryID.index(after: colon)...])
    }
}
