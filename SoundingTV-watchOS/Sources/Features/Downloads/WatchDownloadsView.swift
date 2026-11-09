import SwiftUI

struct WatchDownloadsView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var store = WatchOfflineStore.shared

    var body: some View {
        List {
            if !store.isEmpty {
                Section {
                    Gauge(value: Double(min(store.usedBytes, store.budgetBytes)), in: 0...Double(max(store.budgetBytes, 1))) {
                        Text("Storage")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .listRowBackground(Color.clear)
                    .accessibilityValue("\(store.usedBytes.watchByteString) of \(store.budgetBytes.watchByteString)")
                    ForEach(store.collections) { collection in
                        WatchTrackRow(
                            title: collection.title,
                            subtitle: WatchOnThisWatchRows.subtitle(for: collection),
                            artIdentity: collection.id,
                            artworkURL: collection.artworkURL
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.remove(collection)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    ForEach(store.allTracks) { track in
                        WatchTrackRow(
                            title: track.title,
                            subtitle: "\(track.artist) · \(track.bytes.watchByteString)",
                            artIdentity: track.id,
                            artworkURL: track.artworkURL
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.remove(track)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("On This Watch")
                } footer: {
                    WatchOfflineStorageLine()
                }
            }

            if !link.downloads.items.isEmpty {
                Section {
                    ForEach(link.downloads.items) { item in
                        Button {
                            link.play(trackId: item.id)
                        } label: {
                            WatchTrackRow(
                                title: item.title,
                                subtitle: item.artist,
                                artIdentity: item.id,
                                artworkURL: item.artworkURL,
                                isPlaying: link.nowPlaying.trackId == item.id && link.nowPlaying.isPlaying,
                                isDownloaded: true
                            )
                        }
                        .watchQueueActions(trackId: item.id)
                    }
                } header: {
                    Text("On iPhone")
                } footer: {
                    Text("\(link.downloads.items.count) tracks · \(link.downloads.totalBytes.watchByteString)")
                }
            }
        }
        .overlay {
            if store.isEmpty, link.downloads.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Turn on Send to Watch on iPhone.")
                )
            }
        }
        .navigationTitle("Downloads")
    }
}
