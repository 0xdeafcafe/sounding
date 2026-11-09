import SwiftUI

struct WatchUpNextView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var playback = WatchPlayback.shared
    @ObservedObject private var local = WatchLocalPlayer.shared

    var body: some View {
        if playback.isLocal {
            localQueue
        } else {
            phoneQueue
        }
    }

    private var localQueue: some View {
        List {
            if let current = local.current {
                Section("Now Playing") {
                    WatchNowPlayingRow(title: current.title, subtitle: current.artist, isCurrent: true) {
                        WatchArtwork(url: current.artworkURL, identity: current.id)
                    }
                    .watchNowPlayingRowBackground(isCurrent: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(current.title), \(current.artist)")
                    .accessibilityValue("Now Playing")
                }
            }

            Section(local.sourceTitle.map { "Playing from \($0)" } ?? "Up Next") {
                ForEach(local.upNext) { track in
                    Button {
                        local.jump(to: track.id)
                        dismiss()
                    } label: {
                        WatchNowPlayingRow(title: track.title, subtitle: track.artist) {
                            WatchArtwork(url: track.artworkURL, identity: track.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .watchNowPlayingRowBackground()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(track.title), \(track.artist)")
                    .accessibilityHint("Plays this track now")
                    .accessibilityAddTraits(.isButton)
                }

                if local.upNext.isEmpty {
                    Text("Nothing queued")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .watchNowPlayingScreen("Up Next")
    }

    @ViewBuilder
    private var phoneQueue: some View {
        let np = link.nowPlaying
        let dj = link.djState
        let items = link.queue.items
        let showsMixRow = dj.nextTitle != nil && dj.nextTitle != items.first?.title

        ScrollViewReader { proxy in
            List {
                if np.hasTrack {
                    Section("Now Playing") {
                        WatchNowPlayingRow(title: np.title, subtitle: np.artist, isCurrent: true) {
                            WatchArtwork(url: np.artworkURL, identity: np.trackId ?? np.title)
                        }
                        .watchNowPlayingRowBackground(isCurrent: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(np.title), \(np.artist)")
                        .accessibilityValue("Now Playing")
                    }
                }

                Section(link.queue.sourceTitle.map { "Playing from \($0)" } ?? "Up Next") {
                    if showsMixRow, let nextTitle = dj.nextTitle {
                        WatchNowPlayingRow(title: nextTitle, subtitle: dj.nextArtist ?? "") {
                            WatchArtwork(url: dj.nextArtworkURL, identity: nextTitle)
                        }
                        .watchNowPlayingRowBackground()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(nextTitle), \(dj.nextArtist ?? "")")
                        .accessibilityValue("Auto Mix")
                    }

                    ForEach(items) { item in
                        Button {
                            link.jump(toQueueIndex: item.index)
                            if link.isReachable { dismiss() }
                        } label: {
                            WatchNowPlayingRow(title: item.title, subtitle: item.artist) {
                                WatchArtwork(url: item.artworkURL, identity: item.trackId)
                            }
                        }
                        .buttonStyle(.plain)
                        .watchNowPlayingRowBackground()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.title), \(item.artist)")
                        .accessibilityHint("Plays this track now")
                        .accessibilityAddTraits(.isButton)
                    }

                    if items.isEmpty, np.queueCount > 0, dj.nextTitle == nil {
                        WatchNowPlayingRow(
                            title: np.queueCount == 1 ? "1 track queued" : "\(np.queueCount) tracks queued",
                            subtitle: "On iPhone"
                        ) {
                            WatchRoundIcon(systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .watchNowPlayingRowBackground()
                        .accessibilityElement(children: .combine)
                    }

                    if items.isEmpty, dj.nextTitle == nil, np.queueCount == 0 {
                        Text("Nothing queued")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .task { await proxy.scrollToPreviewTarget() }
        }
        .watchNowPlayingScreen("Up Next")
    }
}
