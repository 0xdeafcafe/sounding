import SwiftUI
import os

struct CollectionDownloadSummary {
    let totalCount: Int
    let entitledCount: Int
    let downloadedCount: Int
    let activeCount: Int
    let failedCount: Int
    let totalBytes: Int64

    var skippedCount: Int { totalCount - entitledCount }
    var isFullyDownloaded: Bool { entitledCount > 0 && downloadedCount == entitledCount }
    var isActive: Bool { activeCount > 0 }

    @MainActor
    static func summarize(tracks: [Track], manager: DownloadManager) -> CollectionDownloadSummary {
        var entitled = 0, downloaded = 0, active = 0, failed = 0
        var bytes: Int64 = 0
        for track in tracks {
            guard manager.downloadRefusalReason(for: track) == nil else { continue }
            entitled += 1
            switch manager.state(for: track.id) {
            case .downloaded:
                downloaded += 1
                bytes += manager.entries[track.id]?.fileSize ?? 0
            case .queued, .downloading, .paused:
                active += 1
            case .failed:
                failed += 1
            case .notDownloaded:
                break
            }
        }
        return CollectionDownloadSummary(
            totalCount: tracks.count, entitledCount: entitled, downloadedCount: downloaded,
            activeCount: active, failedCount: failed, totalBytes: bytes
        )
    }
}

struct CollectionDownloadButton: View {
    let collectionId: String
    let tracks: () -> [Track]

    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        let summary = CollectionDownloadSummary.summarize(tracks: tracks(), manager: manager)
        Menu {
            menuContent(for: summary)
        } label: {
            label(for: summary)
        }
        .disabled(summary.entitledCount == 0)
        .accessibilityLabel(accessibilityLabel(for: summary))
    }

    @ViewBuilder
    private func label(for summary: CollectionDownloadSummary) -> some View {
        if summary.isActive {
            ProgressView(value: Double(summary.downloadedCount), total: Double(max(summary.entitledCount, 1)))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.scAccent)
        } else if summary.isFullyDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.scAccent)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private func menuContent(for summary: CollectionDownloadSummary) -> some View {
        if summary.isFullyDownloaded {
            Text(byteLabel(summary.totalBytes))
            Button(role: .destructive) {
                removeAll()
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else if summary.isActive {
            Text("\(summary.downloadedCount) of \(summary.entitledCount) downloaded")
            Button(role: .destructive) {
                removeAll()
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                downloadAll()
            } label: {
                Label("Download All", systemImage: "arrow.down.circle")
            }
            if summary.skippedCount > 0 {
                Text("\(summary.skippedCount) track\(summary.skippedCount == 1 ? "" : "s") can't be downloaded")
            }
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func accessibilityLabel(for summary: CollectionDownloadSummary) -> String {
        if summary.isFullyDownloaded { return "Downloaded, \(byteLabel(summary.totalBytes))" }
        if summary.isActive { return "Downloading, \(summary.downloadedCount) of \(summary.entitledCount)" }
        return "Download All"
    }

    private func downloadAll() {
        let allTracks = tracks()
        CollectionQualityOverrideStore.shared.updatePolicy(for: collectionId) {
            $0.automaticDownloads = true
        }
        let accepted = manager.pinForOffline(tracks: allTracks, collectionId: collectionId)
        let skipped = allTracks.count - accepted
        if skipped > 0 {
            Log.download.info("\(collectionId, privacy: .public): \(accepted, privacy: .public) accepted, \(skipped, privacy: .public) skipped (not entitled)")
        }
    }

    private func removeAll() {
        let ids = tracks().map(\.id)
        CollectionQualityOverrideStore.shared.updatePolicy(for: collectionId) {
            $0.automaticDownloads = false
        }
        manager.unpinCollection(collectionId)
        for trackId in ids {
            guard let entry = manager.entries[trackId], !entry.isEffectivelyPinned else { continue }
            switch manager.state(for: trackId) {
            case .queued, .downloading, .paused:
                manager.cancel(trackId: trackId)
            default:
                break
            }
        }
    }
}
