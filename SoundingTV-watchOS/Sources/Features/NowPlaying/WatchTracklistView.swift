import SwiftUI

@MainActor
final class WatchNowPlayingDetails: ObservableObject {
    static let shared = WatchNowPlayingDetails()

    @Published private(set) var trackId: String?
    @Published private(set) var track: Track?
    @Published private(set) var tracklist: Tracklist?
    @Published private(set) var isLoading = false
    @Published private(set) var didFail = false
    @Published private(set) var canLike = false
    @Published private(set) var isLiked = false
    @Published private(set) var likeCount = 0
    @Published private(set) var isUpdatingLike = false

    private var loadTask: Task<Void, Never>?

    func load(trackId: String?) {
        guard trackId != self.trackId else { return }
        loadTask?.cancel()
        self.trackId = trackId
        track = nil
        tracklist = nil
        didFail = false
        canLike = false
        isLiked = false
        likeCount = 0
        guard let trackId else { return }
        #if DEBUG
        if WatchUIPreview.isEnabled {
            installPreviewFixture(trackId: trackId)
            return
        }
        #endif
        loadTask = Task { await fetch(trackId: trackId) }
    }

    private func fetch(trackId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await SoundCloudAPI.shared.getTrack(id: trackId)
            guard !Task.isCancelled, self.trackId == trackId else { return }
            track = fetched
            canLike = true
            isLiked = fetched.userFavorite
            likeCount = fetched.likeCount

            var comments: [Comment] = []
            if DeckIdentityResolver.isLikelyMix(fetched) {
                comments = (try? await SoundCloudAPI.shared.getComments(trackId: trackId, limit: 100).collection) ?? []
            }
            guard !Task.isCancelled, self.trackId == trackId else { return }
            let seeded = SetlistMerging.seeded(nil, track: fetched, comments: comments)
            let list = seeded.tracklist
            tracklist = list.isEmpty ? nil : list
        } catch {
            guard self.trackId == trackId else { return }
            didFail = true
        }
    }

    func toggleLike() async {
        guard let track, canLike, !isUpdatingLike else { return }
        isUpdatingLike = true
        defer { isUpdatingLike = false }
        let wantsLike = !isLiked
        do {
            if wantsLike {
                try await SoundCloudAPI.shared.likeTrack(track)
            } else {
                try await SoundCloudAPI.shared.unlikeTrack(track)
            }
            guard self.track?.id == track.id else { return }
            isLiked = wantsLike
            likeCount = max(0, likeCount + (wantsLike ? 1 : -1))
        } catch {
            Log.link.error("[WatchNowPlaying] like failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    private func installPreviewFixture(trackId: String) {
        canLike = true
        isLiked = WatchUIPreview.hasFlag("-SoundingWatchUILiked")
        likeCount = 12_400
        guard WatchUIPreview.hasFlag("-SoundingWatchUITracklist") else { return }
        let entries: [(TimeInterval, String?, String)] = [
            (0, "Night Tapes", "Low Tide Intro"),
            (6 * 60 + 40, "Maya Sol", "Northbound"),
            (13 * 60 + 5, "Glass District", "Sodium Lights"),
            (19 * 60 + 30, "Low Sun", "Harbour Static"),
            (25 * 60 + 12, "Juno Vale", "Paper Satellites"),
            (31 * 60 + 48, nil, "ID"),
            (37 * 60 + 2, "Glass District", "Sodium Lights (Club Edit)"),
            (41 * 60 + 40, "Low Sun", "Long Exposure"),
            (47 * 60 + 15, "Juno Vale", "Paper Satellites (Reprise)"),
            (53 * 60 + 30, "Soft Static", "Midnight Transit")
        ]
        let segments = entries.enumerated().map { index, entry in
            SetlistSegment(
                id: "description#\(index)",
                startSeconds: entry.0,
                observedAtSeconds: entry.0,
                artist: entry.1,
                title: entry.2,
                version: nil,
                source: .uploaderTracklist,
                confidence: 0.94,
                evidence: nil,
                shazamId: nil,
                soundCloudTrackId: nil,
                isUserEdited: false
            )
        }
        let setlist = GeneratedSetlist(
            trackId: trackId,
            trackTitle: "Low Tide 041",
            duration: 61 * 60,
            segments: segments,
            isSaved: false,
            updatedAt: Date()
        )
        tracklist = setlist.tracklist
    }
    #endif
}

struct WatchTracklistView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var details = WatchNowPlayingDetails.shared
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var hasScrolledToCurrent = false

    private var tickInterval: TimeInterval {
        isLuminanceReduced || scenePhase != .active || !link.nowPlaying.isPlaying ? 60 : 2
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            content(at: context.date)
        }
        .watchNowPlayingScreen("Tracklist")
        .task(id: link.nowPlaying.trackId) { details.load(trackId: link.nowPlaying.trackId) }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let np = link.nowPlaying
        let position = np.projectedPosition(at: date, since: link.nowPlayingReceivedAt)
        let currentId = details.tracklist?.currentEntry(at: position)?.id

        if let tracklist = details.tracklist {
            ScrollViewReader { proxy in
                List {
                    ForEach(tracklist.entries) { entry in
                        let isCurrent = entry.id == currentId
                        Button {
                            link.seek(to: entry.startSeconds + 0.05)
                        } label: {
                            WatchNowPlayingRow(
                                title: entry.segment.title,
                                subtitle: subtitle(for: entry),
                                isCurrent: isCurrent
                            ) {
                                if !dynamicTypeSize.isAccessibilitySize {
                                    Text(entry.startSeconds.watchClockString)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                                        .minimumScaleFactor(0.7)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .watchNowPlayingRowBackground(isCurrent: isCurrent)
                        .id(entry.id)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(spokenLabel(for: entry))
                        .accessibilityValue(isCurrent ? "Now Playing" : "")
                        .accessibilityHint("Jumps to this point in the mix")
                        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .onAppear {
                    guard !hasScrolledToCurrent, let currentId else { return }
                    hasScrolledToCurrent = true
                    if reduceMotion {
                        proxy.scrollTo(currentId, anchor: .center)
                    } else {
                        withAnimation { proxy.scrollTo(currentId, anchor: .center) }
                    }
                }
            }
        } else if details.isLoading {
            WatchLoadingState()
        } else {
            ContentUnavailableView(
                "No Tracklist",
                systemImage: "list.number",
                description: Text("This track has no tracklist.")
            )
        }
    }

    private func subtitle(for entry: TracklistEntry) -> String {
        let artist = entry.segment.artist ?? "Unidentified"
        return dynamicTypeSize.isAccessibilitySize ? "\(entry.startSeconds.watchClockString) · \(artist)" : artist
    }

    private func spokenLabel(for entry: TracklistEntry) -> String {
        var parts = [entry.segment.title]
        parts.append(entry.segment.artist ?? "Unidentified")
        parts.append("at \(entry.startSeconds.watchSpokenDuration)")
        return parts.joined(separator: ", ")
    }
}
