import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var navigationState: NavigationState
    @StateObject private var recap = NowPlayingRecapModel()
    @ObservedObject private var presence = DevicePresenceModel.shared
    @FocusState private var browseFocused: Bool

    var body: some View {
        if showsEmptyState {
            emptyState
        } else {
            PlayerView()
                .overlay(alignment: .bottomLeading) {
                    TVDevicePresenceCaption(entries: presence.entries)
                }
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
            LazyVStack(alignment: .leading, spacing: Space.section) {
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
        .defaultFocus($browseFocused, true)
        .onAppear { DispatchQueue.main.async { browseFocused = true } }
        .task { await recap.loadIfNeeded() }
    }

    private var hero: some View {
        let other = presence.primary
        return ContentUnavailableView {
            Label("Nothing Playing", systemImage: "play.circle")
        } description: {
            if let other {
                Label(other.sentence(at: Date()), systemImage: other.deviceClass.symbolName)
            } else {
                Text(subtitle)
            }
        } actions: {
            if let other, presence.actions(for: other).contains(.playHere) {
                Button {
                    presence.perform(.playHere, on: other)
                } label: {
                    TVGlassPillLabel(title: "Play Here", systemImage: "play.fill")
                }
                .buttonStyle(TVGlassPillStyle())
                .disabled(presence.busyEntryID != nil)
                .accessibilityIdentifier("nowplaying.empty.playHere")
            }
            Button {
                navigationState.selectedTab = .home
            } label: {
                TVGlassPillLabel(title: "Browse Music", systemImage: "rectangle.grid.2x2")
            }
            .buttonStyle(TVGlassPillStyle())
            .focused($browseFocused)
            .accessibilityIdentifier("nowplaying.empty.browseHome")
        }
        .frame(maxWidth: .infinity, minHeight: 380)
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
                .padding(.horizontal, SCBrowseMetrics.pageInset)
                .accessibilityAddTraits(.isHeader)

            TrackShelf(tracks: tracks)
        }
        .focusSection()
    }
}

private struct TVDevicePresenceCaption: View {
    let entries: [DevicePresenceEntry]

    var body: some View {
        if let first = entries.first {
            HStack(spacing: 10) {
                Image(systemName: first.deviceClass.symbolName)
                Text(first.sentence(at: Date()))
                    .lineLimit(1)
                if let more = DevicePresence.moreLabel(count: entries.count) {
                    Text(more)
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(first.isLive ? 0.7 : 0.5))
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.leading, Spacing.screen)
            .padding(.bottom, Space.page)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DevicePresence.summary(localTitle: nil, others: entries, now: Date()))
            .transition(.opacity)
        }
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
