import SwiftUI

struct WatchOnThisWatchView: View {
    @ObservedObject private var store = WatchOfflineStore.shared
    @ObservedObject private var playback = WatchPlayback.shared

    var body: some View {
        List {
            if !store.isEmpty {
                Section {
                    WatchPlayShuffleButtons(
                        subject: "everything on this watch",
                        play: { playback.play(store.allTracks, title: "On This Watch") },
                        shuffle: { playback.playShuffled(store.allTracks, title: "On This Watch") }
                    )
                    .listRowBackground(Color.clear)
                }
                WatchOnThisWatchRows()
                Section {
                    NavigationLink {
                        WatchDownloadsView()
                    } label: {
                        Label("Manage Storage", systemImage: "internaldrive")
                    }
                } footer: {
                    WatchOfflineStorageLine()
                }
            }
        }
        .overlay {
            if store.isEmpty {
                ContentUnavailableView(
                    "Nothing on This Watch",
                    systemImage: "applewatch",
                    description: Text("Turn on Send to Watch on iPhone.")
                )
            }
        }
        .navigationTitle("On This Watch")
        .watchNavigationTint()
    }
}

struct WatchOnThisWatchRows: View {
    var header: String? = nil

    @ObservedObject private var store = WatchOfflineStore.shared

    var body: some View {
        Section {
            ForEach(store.collections) { collection in
                NavigationLink {
                    WatchOfflineCollectionView(collection: collection)
                } label: {
                    WatchTrackRow(
                        title: collection.title,
                        subtitle: Self.subtitle(for: collection),
                        artIdentity: collection.id,
                        artworkURL: collection.artworkURL
                    )
                }
            }
            NavigationLink {
                WatchOfflineTracksView()
            } label: {
                LabeledContent {
                    Text(store.tracks.count, format: .number)
                } label: {
                    Label("Tracks", systemImage: "music.note")
                }
            }
        } header: {
            if let header { Text(header) }
        }
    }

    static func subtitle(for collection: WatchOfflineCollection) -> String {
        let count = collection.trackIDs.count == 1 ? "1 track" : "\(collection.trackIDs.count) tracks"
        guard let subtitle = collection.subtitle, !subtitle.isEmpty else { return count }
        return "\(subtitle) · \(count)"
    }
}

struct WatchOnThisWatchLibrarySection: View {
    @ObservedObject private var store = WatchOfflineStore.shared

    var body: some View {
        if !store.isEmpty {
            WatchOnThisWatchRows(header: "On This Watch")
        }
    }
}

struct WatchOfflineCollectionView: View {
    let collection: WatchOfflineCollection

    @ObservedObject private var store = WatchOfflineStore.shared

    private var tracks: [WatchOfflineTrack] { store.tracks(in: collection) }

    var body: some View {
        WatchOfflineTrackList(
            tracks: tracks,
            title: collection.title,
            emptyTitle: "Not on This Watch"
        )
        .navigationTitle(collection.title)
    }
}

struct WatchOfflineTracksView: View {
    @ObservedObject private var store = WatchOfflineStore.shared

    var body: some View {
        WatchOfflineTrackList(tracks: store.allTracks, title: "On This Watch", emptyTitle: "No Tracks")
            .navigationTitle("Tracks")
    }
}

struct WatchOfflineTrackList: View {
    let tracks: [WatchOfflineTrack]
    let title: String
    let emptyTitle: LocalizedStringKey

    @ObservedObject private var playback = WatchPlayback.shared
    @ObservedObject private var local = WatchLocalPlayer.shared
    @ObservedObject private var store = WatchOfflineStore.shared

    var body: some View {
        List {
            if !tracks.isEmpty {
                Section {
                    WatchPlayShuffleButtons(
                        subject: title,
                        play: { playback.play(tracks, title: title) },
                        shuffle: { playback.playShuffled(tracks, title: title) }
                    )
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                    Button {
                        playback.play(tracks, startAt: offset, title: title)
                    } label: {
                        WatchTrackRow(
                            title: track.title,
                            subtitle: track.artist,
                            artIdentity: track.id,
                            artworkURL: track.artworkURL,
                            duration: track.durationSeconds,
                            isPlaying: playback.isLocal && local.current?.id == track.id && local.isPlaying,
                            isDownloaded: true
                        )
                    }
                    .disabled(!store.isPlayable(track))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.remove(track)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "applewatch")
            }
        }
    }
}

struct WatchOfflineStorageLine: View {
    @ObservedObject private var store = WatchOfflineStore.shared

    var body: some View {
        Text("\(store.usedBytes.watchByteString) of \(store.budgetBytes.watchByteString)")
    }
}

struct WatchRouteSwitch: View {
    @ObservedObject private var playback = WatchPlayback.shared

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                option(.phone, title: "iPhone", systemImage: "iphone")
                option(.watch, title: "This Watch", systemImage: "applewatch")
            }
        }
        .font(.footnote.weight(.semibold))
    }

    @ViewBuilder
    private func option(_ route: WatchPlayback.Route, title: String, systemImage: String) -> some View {
        let isSelected = playback.route == route
        if isSelected {
            Button {
                playback.switchTo(route)
            } label: {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleOnly)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                playback.switchTo(route)
            } label: {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleOnly)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }
}
