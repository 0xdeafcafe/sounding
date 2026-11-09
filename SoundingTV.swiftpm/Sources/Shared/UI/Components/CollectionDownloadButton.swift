import SwiftUI

struct CollectionDownloadButton: View {
    let collectionId: String
    let tracks: () -> [Track]
    private let hydrationPlaylist: Playlist?

    @ObservedObject private var manager = DownloadManager.shared
    @Environment(\.downloadPrompter) private var prompter

    init(collectionId: String, tracks: @escaping () -> [Track]) {
        self.collectionId = collectionId
        self.tracks = tracks
        self.hydrationPlaylist = nil
    }

    init(collectionId: String, playlist: Playlist, tracks: @escaping () -> [Track]) {
        self.collectionId = collectionId
        self.tracks = tracks
        self.hydrationPlaylist = playlist
    }

    var body: some View {
        if let item = downloadedItem {
            Menu {
                Text(DownloadsFormat.collectionDetail(item, waitingReason: manager.waitingReason))
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    manager.removeDownload(.collection(collectionId))
                }
            } label: {
                label(for: item)
            }
            .accessibilityLabel(accessibilityLabel(for: item))
        } else {
            Button(action: download) {
                Image(systemName: "arrow.down.circle")
            }
            .disabled(!hasDownloadableTrack)
            .accessibilityLabel("Download")
        }
    }

    private var downloadedItem: DownloadedCollectionItem? {
        guard manager.isCollectionDownloaded(collectionId) else { return nil }
        let library = manager.library
        if collectionId == CollectionPolicyID.likedTracks { return library.likes }
        return library.playlists.first { $0.id == collectionId }
    }

    private var hasDownloadableTrack: Bool {
        tracks().contains { manager.downloadRefusalReason(for: $0) == nil }
    }

    @ViewBuilder
    private func label(for item: DownloadedCollectionItem) -> some View {
        switch item.state {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.scAccent)
        case .downloading(let completed, let total), .waiting(let completed, let total), .failed(let completed, let total):
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.scAccent)
        }
    }

    private func accessibilityLabel(for item: DownloadedCollectionItem) -> String {
        switch item.state {
        case .downloaded: return "Downloaded, \(DownloadsFormat.bytes(item.bytes))"
        case .downloading(let completed, let total): return "Downloading, \(completed) of \(total)"
        case .waiting(let completed, let total): return "Waiting to download, \(completed) of \(total)"
        case .failed(let completed, let total): return "Download failed, \(completed) of \(total)"
        }
    }

    private func download() {
        let allTracks = tracks()
        let descriptor = hydrationPlaylist.map(DownloadCollectionDescriptor.init(playlist:))
            ?? .forCollectionID(collectionId, title: "Playlist")
        prompter.request { confirmed in
            await manager.download(collection: descriptor, tracks: allTracks, confirmed: confirmed)
        }
    }
}
