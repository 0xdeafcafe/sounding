import SwiftUI
#if os(iOS)
import UIKit
#endif

struct IdentifySongRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        case listen
        case song(IdentifiedSong)
        case history
    }

    let id = UUID()
    let mode: Mode
}

@MainActor
final class IdentifySongPresenter: ObservableObject {
    static let shared = IdentifySongPresenter()

    @Published var request: IdentifySongRequest?

    private init() {}

    func listen() { request = IdentifySongRequest(mode: .listen) }

    func show(_ song: IdentifiedSong) { request = IdentifySongRequest(mode: .song(song)) }

    func showHistory() { request = IdentifySongRequest(mode: .history) }

    func dismiss() { request = nil }
}

struct IdentifySongActions {
    var play: @MainActor (Track, [Track]) -> Void = { _, _ in }
    var addToPlaylist: (@MainActor (Track) -> Void)?
}

extension EnvironmentValues {
    @Entry var identifySongActions = IdentifySongActions()
}

enum IdentifySongRoute: Hashable {
    case history
    case song(IdentifiedSong)
}

private enum IdentifySongStyle {
    static var content: SCContentStyle {
        #if os(macOS)
        .mac
        #else
        .phone
        #endif
    }
}

struct IdentifySongSheet: View {
    let request: IdentifySongRequest

    @Environment(\.dismiss) private var dismiss
    @State private var path: [IdentifySongRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: IdentifySongRoute.self) { route in
                    switch route {
                    case .history:
                        IdentifiedSongHistoryView()
                    case .song(let song):
                        IdentifiedSongView(song: song)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", role: .close) { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch request.mode {
        case .listen:
            IdentifySongListenView { path.append(.history) }
        case .song(let song):
            IdentifiedSongView(song: song)
        case .history:
            IdentifiedSongHistoryView()
        }
    }
}

struct IdentifySongListenView: View {
    let openHistory: () -> Void

    @State private var identifier = SongIdentifier()
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .navigationTitle(identifier.song?.title ?? "Identify Song")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Recently Identified", systemImage: "clock", action: openHistory)
                }
            }
            .task {
                if identifier.state == .idle { identifier.start() }
            }
            .onDisappear { identifier.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch identifier.state {
        case .idle, .listening:
            IdentifyListeningView(isListening: identifier.isListening)
        case .matched(let song):
            IdentifiedSongView(song: song, setsTitle: false) { identifier.start() }
                .id(song.id)
        case .noMatch:
            ContentUnavailableView {
                Label("No Match", systemImage: "waveform.slash")
            } description: {
                Text("Sounding couldn’t name this song. Move closer to the music and try again.")
            } actions: {
                Button("Try Again") { identifier.start() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.title, systemImage: failure == .microphoneDenied ? "mic.slash" : "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                if failure == .microphoneDenied, let url = Self.microphoneSettingsURL {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Try Again") { identifier.start() }
            }
        }
    }

    private static var microphoneSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #elseif os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #else
        nil
        #endif
    }
}

struct IdentifyListeningView: View {
    let isListening: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var glyph: CGFloat = 44

    private var animates: Bool { isListening && !reduceMotion && scenePhase == .active }

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                rings
                Image(systemName: "waveform")
                    .font(.system(size: glyph, weight: .semibold))
                    .foregroundStyle(Color.scAccent)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animates)
            }
            .frame(width: 240, height: 240)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(isListening ? "Listening…" : "Getting Ready…")
                    .font(.title2.bold())
                    .contentTransition(.opacity)
                Text("Keep the music playing nearby.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rings: some View {
        if animates {
            PhaseAnimator([0.2, 0.95]) { level in
                SoundingSoundRings(level: level)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        } else {
            SoundingSoundRings(level: 0.5)
        }
    }
}

struct IdentifiedSongView: View {
    let song: IdentifiedSong
    var setsTitle = true
    var onIdentifyAgain: (() -> Void)?

    @State private var matches: IdentifiedSongMatches
    @State private var showsMatches = false
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.identifySongActions) private var actions
    @Environment(\.dismiss) private var dismiss

    init(song: IdentifiedSong, setsTitle: Bool = true, onIdentifyAgain: (() -> Void)? = nil) {
        self.song = song
        self.setsTitle = setsTitle
        self.onIdentifyAgain = onIdentifyAgain
        _matches = State(initialValue: IdentifiedSongMatches(song: song))
    }

    var body: some View {
        Form {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                if let url = song.appleMusicURL {
                    Link(destination: url) {
                        Label("Open in Apple Music", systemImage: "arrow.up.forward.app")
                    }
                }
                share
            }

            if showsMatches {
                matchesSection
            }
        }
        .formStyle(.grouped)
        .modifier(IdentifiedSongTitle(title: setsTitle ? song.title : nil))
        .toolbar {
            if let onIdentifyAgain {
                ToolbarItem(placement: .primaryAction) {
                    Button("Identify Again", systemImage: "arrow.clockwise", action: onIdentifyAgain)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            SCArtworkResolver(url: song.artworkURL, variant: .standard) { image in
                SCArtwork(image: image, identity: song.artIdentity, style: IdentifySongStyle.content, cornerRadius: 14)
            }
            .frame(width: 220, height: 220)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(song.title)
                    .font(.title2.bold())
                Text(song.artist ?? "Unknown Artist")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(song.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: findOnSoundCloud) {
                        Label("Find on SoundCloud", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)

                    Button(action: addToLibrary) {
                        Label(matches.isBestLiked ? "In Library" : "Add to Library",
                              systemImage: matches.isBestLiked ? "checkmark" : "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(!credentials.isAuthenticated || matches.isBestLiked || matches.phase == .loading)
                }
                .controlSize(.large)
                .labelStyle(.titleAndIcon)
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var share: some View {
        if let url = song.shareURL {
            ShareLink(item: url, subject: Text(song.title), message: Text(song.shareText)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } else {
            ShareLink(item: song.shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    private var matchesSection: some View {
        Section {
            switch matches.phase {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await matches.load(force: true) } }
                }
            case .loaded:
                if matches.tracks.isEmpty {
                    ContentUnavailableView {
                        Label("Not on SoundCloud", systemImage: "magnifyingglass")
                    } description: {
                        Text("Nothing on SoundCloud matches this song.")
                    } actions: {
                        Button("Search SoundCloud", action: searchEverything)
                    }
                } else {
                    ForEach(matches.tracks) { track in
                        IdentifiedSongMatchRow(
                            track: track,
                            isLiked: matches.isLiked(track),
                            isUpdating: matches.isUpdating(track),
                            canLike: credentials.isAuthenticated,
                            play: { actions.play(track, matches.tracks) },
                            toggleLike: { Task { await matches.toggleLike(track) } },
                            addToPlaylist: actions.addToPlaylist == nil ? nil : { actions.addToPlaylist?(track) }
                        )
                    }
                    Button("See All Results", action: searchEverything)
                }
            }
        } header: {
            Text("On SoundCloud")
        } footer: {
            if let error = matches.likeError {
                Text(error)
            }
        }
    }

    private func findOnSoundCloud() {
        showsMatches = true
        Task { await matches.load() }
    }

    private func addToLibrary() {
        showsMatches = true
        Task { await matches.addBestToLibrary() }
    }

    private func searchEverything() {
        SearchRequestRouter.shared.search(song.searchQuery)
        IdentifySongPresenter.shared.dismiss()
        dismiss()
    }
}

private struct IdentifiedSongTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } else {
            content
        }
    }
}

struct IdentifiedSongMatchRow: View {
    let track: Track
    let isLiked: Bool
    let isUpdating: Bool
    let canLike: Bool
    let play: () -> Void
    let toggleLike: () -> Void
    let addToPlaylist: (() -> Void)?

    @ScaledMetric(relativeTo: .body) private var artwork: CGFloat = 44

    private var isPlayable: Bool { track.streamURL != nil }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    SCArtworkResolver(url: track.artworkURL, variant: .thumbnail) { image in
                        SCArtwork(image: image, identity: track.id, style: IdentifySongStyle.content, cornerRadius: 6)
                    }
                    .frame(width: artwork, height: artwork)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .lineLimit(2)
                        Text("\(track.user.displayName) · \(IdentifiedSong.clock(track.duration))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isPlayable)

            Button(action: toggleLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(!canLike || isUpdating)
            .accessibilityLabel(isLiked ? "Unlike" : "Like")
        }
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: play)
                .disabled(!isPlayable)
            if canLike {
                Button(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.slash" : "heart", action: toggleLike)
            }
            if let addToPlaylist {
                Button("Add to Playlist…", systemImage: "text.badge.plus", action: addToPlaylist)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Play", play)
        .accessibilityAction(named: isLiked ? "Unlike" : "Like", toggleLike)
    }
}

struct IdentifiedSongHistoryView: View {
    @ObservedObject private var history = IdentifiedSongHistory.shared
    @State private var confirmsClear = false

    var body: some View {
        Group {
            if history.songs.isEmpty {
                ContentUnavailableView(
                    "No Songs Yet",
                    systemImage: "shazam.logo",
                    description: Text("Songs you identify appear here.")
                )
            } else {
                List {
                    ForEach(history.songs) { song in
                        NavigationLink(value: IdentifySongRoute.song(song)) {
                            IdentifiedSongHistoryRow(song: song)
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { history.remove(song) }
                        }
                    }
                    .onDelete { history.remove(atOffsets: $0) }
                }
            }
        }
        .navigationTitle("Recently Identified")
        .toolbar {
            if !history.songs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { confirmsClear = true }
                }
            }
        }
        .confirmationDialog("Clear Recently Identified?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { history.clear() }
        }
    }
}

struct IdentifiedSongHistoryRow: View {
    let song: IdentifiedSong

    @ScaledMetric(relativeTo: .body) private var artwork: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            SCArtworkResolver(url: song.artworkURL, variant: .thumbnail) { image in
                SCArtwork(image: image, identity: song.artIdentity, style: IdentifySongStyle.content, cornerRadius: 6)
            }
            .frame(width: artwork, height: artwork)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(2)
                Text([song.artist, song.caption].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
