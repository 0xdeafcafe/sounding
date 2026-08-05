import SwiftUI

struct TrackListView: View {
    let tracks: [Track]
    var collectionId: String? = nil
    var dateAdded: (Track) -> Date = { $0.createdAt }
    var emptyIcon = "music.note.list"
    var emptyTitle = "No tracks"
    var onNearEnd: (() -> Void)?
    var isLoadingMore = false
    /// Optional parent-specific actions rendered in the same toolbar as search and sort.
    var toolbarActions: AnyView? = nil
    /// Lets a parent title/action header share the same visual toolbar row.
    var toolbarHeaderOverlap: CGFloat = 0

    @EnvironmentObject var playerService: PlayerService
    @StateObject private var analysisStore = TrackAnalysisStore()

    @State private var searchText = ""
    @State private var sortKey: TrackSortKey = .dateAdded
    @State private var ascending = false
    @FocusState private var toolbarFocus: ToolbarFocus?

    private enum ToolbarFocus: Hashable { case search, sort, direction }

    private var searchIsExpanded: Bool {
        toolbarFocus == .search || !searchText.isEmpty
    }

    private static let artworkLookahead = 10

    var body: some View {
        let visible = visibleTracks

        VStack(alignment: .leading, spacing: Space.snug) {
            if tracks.count > 1 {
                toolbar
                    .offset(y: -toolbarHeaderOverlap)
                    .padding(.bottom, -toolbarHeaderOverlap)
            }

            if visible.isEmpty {
                StatusPanel(
                    kind: .empty,
                    icon: emptyIcon,
                    title: searchText.isEmpty ? emptyTitle : "No matches for \u{201C}\(searchText)\u{201D}",
                    minHeight: 320
                )
            } else {
                LazyVStack(spacing: Space.tight) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            analysis: analysisStore.summaries[track.id],
                            action: { Task { await playerService.play(track, in: visible, collectionId: collectionId) } }
                        )
                        .onAppear {
                            guard let onNearEnd, visible.isNearEnd(track, lead: 6) else { return }
                            onNearEnd()
                        }
                        .onAppear {
                            let lookahead = visible[index..<min(index + Self.artworkLookahead, visible.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
                        }
                    }

                    if isLoadingMore {
                        LoadingMoreRow()
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control))
                .focusEffectDisabled()
            }
        }
        .task(id: tracks.map(\.id)) {
            await analysisStore.load(for: tracks)
            if let collectionId {
                DownloadManager.shared.applyCollectionPolicy(tracks: tracks, collectionId: collectionId)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Space.base) {
            Spacer(minLength: 0)

            if let toolbarActions {
                toolbarActions
            }

            HStack(spacing: Space.tight) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(toolbarFocus == .search ? Color.scChromeFocusOn : Color.scTextTertiary)
                TextField("Search this list", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.tvBody)
                    .foregroundStyle(toolbarFocus == .search ? Color.scChromeFocusOn : Color.scTextPrimary)
                    .opacity(searchIsExpanded ? 1 : 0)
                    .frame(width: searchIsExpanded ? 320 : 0)
            }
            .padding(.horizontal, 20)
            .frame(width: searchIsExpanded ? 404 : 68, height: 68, alignment: .leading)
            .background(
                toolbarFocus == .search ? Color.scChromeFocus : Color.white.opacity(0.10),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
            .focused($toolbarFocus, equals: .search)
            .animation(.easeInOut(duration: 0.20), value: searchIsExpanded)

            Menu {
                ForEach(TrackSortKey.allCases) { key in
                    Button {
                        sortKey = key
                        ascending = key.defaultAscending
                    } label: {
                        Label(key.rawValue, systemImage: sortKey == key ? "checkmark" : key.icon)
                    }
                }
            } label: {
                toolbarCircle(icon: "line.3.horizontal.decrease", isFocused: toolbarFocus == .sort)
            }
            .buttonStyle(SCPlainButtonStyle())
            .focusEffectDisabled()
            .accessibilityIdentifier("tracklist.sort")
            .focused($toolbarFocus, equals: .sort)

            Button {
                ascending.toggle()
            } label: {
                toolbarCircle(
                    icon: ascending ? "arrow.up" : "arrow.down",
                    isFocused: toolbarFocus == .direction
                )
            }
            .buttonStyle(SCPlainButtonStyle())
            .focusEffectDisabled()
            .focused($toolbarFocus, equals: .direction)
        }
        .focusSection()
    }

    private func toolbarCircle(icon: String, isFocused: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: Control.circleIcon, weight: .semibold))
            .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
            .frame(width: 68, height: 68)
            .background(isFocused ? Color.scChromeFocus : Color.white.opacity(0.10), in: Circle())
            .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 14, y: 7)
    }

    private var visibleTracks: [Track] {
        let filtered: [Track]
        if searchText.isEmpty {
            filtered = tracks
        } else {
            let needle = searchText.lowercased()
            filtered = tracks.filter {
                $0.title.lowercased().contains(needle) || $0.user.displayName.lowercased().contains(needle)
            }
        }
        return TrackSort.sorted(
            filtered,
            by: sortKey,
            ascending: ascending,
            analysis: analysisStore.summaries,
            dateAdded: dateAdded
        )
    }
}

private struct TrackRow: View {
    let track: Track
    let analysis: TrackAnalysisSummary?
    let action: () -> Void

    @EnvironmentObject private var playerService: PlayerService
    @FocusState private var isFocused: Bool

    private var isPlayable: Bool { track.streamURL != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.snug) {
                ArtworkImage(url: track.artworkURL)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                    .kyleCrowned(user: track.user, context: track.title)

                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(track.title)
                        .font(.tvBodyEmph)
                        .foregroundStyle(Color.scTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(track.user.displayName)
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let analysis, !analysis.isEmpty {
                        analysis.badgeRow(style: .tv)
                            .padding(.top, Space.hair / 2)
                    }
                }

                Spacer(minLength: Space.snug)

                if isPlayable {
                    Text(track.formattedDuration)
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextTertiary)
                } else {
                    Label("Unavailable", systemImage: "lock.fill")
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextTertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isPlayable ? 1 : 0.5)
        }
        .disabled(!isPlayable)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            // Focusing a row is the tvOS form of selection; warm the stream
            // URL so pressing play skips the blocking resolve.
            if focused { playerService.warmStreamURL(for: track) }
        }
    }

}
