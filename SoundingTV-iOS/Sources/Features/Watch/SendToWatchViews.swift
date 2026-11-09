import SwiftUI

struct SendToWatchMenuToggle: View {
    let selection: WatchSendSelection
    var prepare: (() -> Void)? = nil

    @ObservedObject private var sync = PhoneWatchOfflineSync.shared
    @ObservedObject private var watch = PhoneWatchLinkServer.shared

    var body: some View {
        if watch.isWatchPaired {
            Toggle(isOn: Binding(
                get: { sync.isSending(selection.id) },
                set: { on in
                    sync.setSending(on, selection)
                    if on { prepare?() }
                }
            )) {
                Label("Send to Watch", systemImage: "applewatch")
            }
        }
    }
}

struct AppleWatchDownloadsSection: View {
    @ObservedObject private var sync = PhoneWatchOfflineSync.shared
    @ObservedObject private var watch = PhoneWatchLinkServer.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var localMusic = LocalMusicLibrary.shared

    private var downloadedCollections: [WatchSendSelection] {
        let library = downloads.library
        var items: [WatchSendSelection] = []
        if let likes = library.likes, likes.downloadedCount > 0 { items.append(.likes) }
        for playlist in library.playlists where playlist.downloadedCount > 0 {
            items.append(WatchSendSelection(id: playlist.id, kind: .playlist, title: playlist.title, artworkURL: playlist.artworkURL))
        }
        let shown = Set(items.map(\.id))
        return items + sync.selections.filter { $0.localAlbumID == nil && !shown.contains($0.id) }
    }

    private var localAlbums: [LocalCollection] {
        LocalCollections.albums(from: localMusic.allTracks)
    }

    var body: some View {
        if watch.isWatchPaired {
            let collections = downloadedCollections
            let albums = localAlbums
            Section {
                ForEach(collections) { selection in
                    toggle(selection)
                }
                if !albums.isEmpty {
                    NavigationLink {
                        SendToWatchAlbumsView(albums: albums)
                    } label: {
                        LabeledContent("Your Music", value: localSummary(albums))
                    }
                }
                Picker("Storage Limit", selection: Binding(
                    get: { sync.budget },
                    set: { sync.setBudget($0) }
                )) {
                    ForEach(WatchStorageBudget.allCases) { budget in
                        Text(budget.displayName).tag(budget)
                    }
                }
                LabeledContent("On Apple Watch", value: onWatchSummary)
            } header: {
                Text("Send to Watch")
            } footer: {
                if sync.manifest.skippedForBudget > 0 {
                    Text("\(DownloadsFormat.trackCount(sync.manifest.skippedForBudget)) don’t fit. Raise the limit or send less.")
                } else if collections.isEmpty, albums.isEmpty {
                    Text("Download a playlist, album or your Likes to send it to Apple Watch.")
                } else {
                    Text("Plays on Apple Watch with AirPods, even without iPhone.")
                }
            }
        }
    }

    private func toggle(_ selection: WatchSendSelection) -> some View {
        Toggle(isOn: Binding(
            get: { sync.isSending(selection.id) },
            set: { sync.setSending($0, selection) }
        )) {
            Label(selection.title, systemImage: selection.kind.symbolName)
        }
    }

    private func localSummary(_ albums: [LocalCollection]) -> String {
        let count = albums.filter { sync.isSending(WatchSendSelection(local: $0).id) }.count
        return count == 0 ? "Off" : (count == 1 ? "1 album" : "\(count) albums")
    }

    private var onWatchSummary: String {
        if sync.sendingCount > 0 { return "Sending \(sync.sendingCount)…" }
        let count = sync.onWatchCount
        guard count > 0 else { return "Nothing yet" }
        return "\(DownloadsFormat.trackCount(count)) · \(DownloadsFormat.bytes(sync.inventory.usedBytes))"
    }
}

struct SendToWatchAlbumsView: View {
    let albums: [LocalCollection]

    @ObservedObject private var sync = PhoneWatchOfflineSync.shared

    var body: some View {
        List {
            ForEach(albums) { album in
                let selection = WatchSendSelection(local: album)
                Toggle(isOn: Binding(
                    get: { sync.isSending(selection.id) },
                    set: { sync.setSending($0, selection) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title)
                        Text(album.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Your Music")
        .navigationBarTitleDisplayMode(.inline)
    }
}
