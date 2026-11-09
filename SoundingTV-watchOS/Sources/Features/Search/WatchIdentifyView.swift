import SwiftUI

struct WatchIdentifyView: View {
    @State private var identifier = SongIdentifier()

    var body: some View {
        content
            .navigationTitle("Identify")
            .watchNavigationTint()
            .task {
                if identifier.state == .idle { identifier.start() }
            }
            .onDisappear { identifier.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch identifier.state {
        case .idle, .listening:
            WatchIdentifyListening(isListening: identifier.isListening)
        case .matched(let song):
            WatchIdentifiedSongView(song: song) { identifier.start() }
        case .noMatch:
            ContentUnavailableView {
                Label("No Match", systemImage: "waveform.slash")
            } description: {
                Text("Move closer to the music.")
            } actions: {
                Button("Try Again") { identifier.start() }
                    .buttonStyle(.glass)
            }
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.title, systemImage: failure == .microphoneDenied ? "mic.slash" : "exclamationmark.triangle")
            } description: {
                Text(failure == .microphoneDenied ? "Allow the microphone in Settings on your Apple Watch." : failure.message)
            } actions: {
                Button("Try Again") { identifier.start() }
                    .buttonStyle(.glass)
            }
        }
    }
}

private struct WatchIdentifyListening: View {
    let isListening: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animates: Bool { isListening && !reduceMotion && !isLuminanceReduced }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animates)
                .frame(width: 72, height: 72)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)
            Text(isListening ? "Listening…" : "Getting Ready…")
                .font(.headline)
            Text("Keep the music playing nearby.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct WatchIdentifiedSongView: View {
    let song: IdentifiedSong
    var onIdentifyAgain: (() -> Void)?

    @State private var matches: IdentifiedSongMatches

    init(song: IdentifiedSong, onIdentifyAgain: (() -> Void)? = nil) {
        self.song = song
        self.onIdentifyAgain = onIdentifyAgain
        _matches = State(initialValue: IdentifiedSongMatches(song: song))
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    WatchArtwork(url: song.artworkURL, size: 88, corner: 12, identity: song.artIdentity)
                    Text(song.title)
                        .font(.headline)
                    if let artist = song.artist {
                        Text(artist)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }

            Section {
                NavigationLink {
                    WatchIdentifiedSongMatchesView(matches: matches)
                } label: {
                    Label("Find on SoundCloud", systemImage: "magnifyingglass")
                }
                Button {
                    Task { await matches.addBestToLibrary() }
                } label: {
                    Label(matches.isBestLiked ? "In Library" : "Add to Library",
                          systemImage: matches.isBestLiked ? "checkmark" : "plus")
                }
                .disabled(matches.isBestLiked || matches.phase == .loading)
                if let onIdentifyAgain {
                    Button(action: onIdentifyAgain) {
                        Label("Identify Again", systemImage: "arrow.clockwise")
                    }
                }
            } footer: {
                if let error = matches.likeError {
                    Text(error)
                } else if case .failed(let message) = matches.phase {
                    Text(message)
                }
            }
        }
        .navigationTitle(song.title)
    }
}

private struct WatchIdentifiedSongMatchesView: View {
    let matches: IdentifiedSongMatches
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        List {
            ForEach(matches.tracks) { track in
                Button {
                    link.play(trackId: track.id)
                } label: {
                    WatchTrackRow(
                        title: track.title,
                        subtitle: track.user.displayName,
                        artIdentity: track.id,
                        artworkURL: track.artworkURL,
                        duration: track.duration,
                        isPlaying: link.nowPlaying.trackId == track.id
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        Task { await matches.toggleLike(track) }
                    } label: {
                        Label(matches.isLiked(track) ? "Unlike" : "Like",
                              systemImage: matches.isLiked(track) ? "heart.slash" : "heart")
                    }
                }
                .watchQueueActions(trackId: track.id)
            }
        }
        .overlay {
            switch matches.phase {
            case .idle, .loading:
                WatchLoadingState(title: "Searching")
            case .failed(let message):
                WatchErrorState(title: "Couldn’t Search", message: message) {
                    Task { await matches.load(force: true) }
                }
            case .loaded:
                if matches.tracks.isEmpty {
                    ContentUnavailableView(
                        "Not on SoundCloud",
                        systemImage: "magnifyingglass",
                        description: Text("Nothing on SoundCloud matches this song.")
                    )
                }
            }
        }
        .navigationTitle("SoundCloud")
        .watchNavigationTint()
        .task { await matches.load() }
    }
}

struct WatchIdentifiedHistoryView: View {
    @ObservedObject private var history = IdentifiedSongHistory.shared

    var body: some View {
        List {
            ForEach(history.songs) { song in
                NavigationLink {
                    WatchIdentifiedSongView(song: song)
                } label: {
                    WatchTrackRow(
                        title: song.title,
                        subtitle: song.artist ?? song.caption,
                        artIdentity: song.artIdentity,
                        artworkURL: song.artworkURL
                    )
                }
            }
            .onDelete { history.remove(atOffsets: $0) }
        }
        .overlay {
            if history.songs.isEmpty {
                ContentUnavailableView(
                    "No Songs Yet",
                    systemImage: "shazam.logo",
                    description: Text("Songs you identify appear here.")
                )
            }
        }
        .navigationTitle("Identified")
        .watchNavigationTint()
    }
}
