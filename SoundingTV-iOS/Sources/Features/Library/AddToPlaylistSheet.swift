import SwiftUI
import TipKit
import UniformTypeIdentifiers

extension View {
    func addToPlaylistHost() -> some View { modifier(AddToPlaylistHost()) }
}

private struct AddToPlaylistHost: ViewModifier {
    @State private var track: PlaylistTrackRef?
    @StateObject private var confirmation = QueueConfirmationController()

    func body(content: Content) -> some View {
        content
            .environment(\.presentAddToPlaylist) { track = $0 }
            .environment(\.announcePlaylistChange) { confirmation.show($0, icon: $1) }
            .sheet(item: $track) { track in
                AddToPlaylistSheet(track: track) { playlist in
                    confirmation.show("Added to \(playlist.title)")
                }
            }
            .queueConfirmationOverlay(confirmation)
            .playlistEditingHost()
            .wakeAlarmHost()
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.environment["SOUNDING_TV_ADD_TO_PLAYLIST"] == "1",
                      track == nil, let first = VisualFixtures.tracks.first else { return }
                try? await Task.sleep(for: .seconds(1.5))
                track = PlaylistTrackRef(track: first)
            }
            #endif
    }
}

struct AddToPlaylistMenuButton: View {
    let track: PlaylistTrackRef
    @Environment(\.presentAddToPlaylist) private var present

    init(track: Track) {
        self.track = PlaylistTrackRef(track: track)
    }

    init(trackID: String, title: String) {
        track = PlaylistTrackRef(id: trackID, title: title)
    }

    var body: some View {
        Button {
            AddToPlaylistTip().invalidate(reason: .actionPerformed)
            present(track)
        } label: {
            Label("Add to Playlist…", systemImage: "text.badge.plus")
        }
    }
}

private struct AddToPlaylistSheet: View {
    let onAdded: (PlaylistSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AddToPlaylistModel
    @State private var isNaming = false
    @State private var finished = false

    init(track: PlaylistTrackRef, onAdded: @escaping (PlaylistSummary) -> Void) {
        self.onAdded = onAdded
        _model = StateObject(wrappedValue: AddToPlaylistModel(track: track))
    }

    private var track: PlaylistTrackRef { model.track }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to Playlist")
                .navigationSubtitle(track.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
                .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Playlists")
        }
        .presentationDetents(PadLayout.isPad ? [.large] : [.medium, .large])
        .presentationSizing(.form)
        .interactiveDismissDisabled(model.isAdding)
        .sensoryFeedback(.success, trigger: finished)
        .sheet(isPresented: $isNaming) {
            NewPlaylistSheet(trackIDs: [track.id]) { made in
                finish(PlaylistSummary(made))
            }
        }
        .alert("Couldn’t Add to Playlist", isPresented: Binding(
            get: { model.failure != nil },
            set: { if !$0 { model.failure = nil } }
        )) {
            Button("Try Again") { model.retryLastAdd() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load Playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
            }
        case .loaded(let playlists):
            list(playlists)
        }
    }

    private func list(_ playlists: [PlaylistSummary]) -> some View {
        let shown = model.playlists(from: playlists)
        return List {
            if model.query.isEmpty {
                Section {
                    Button {
                        isNaming = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                    .disabled(model.isAdding)
                }
            }
            if shown.isEmpty {
                if playlists.isEmpty {
                    ContentUnavailableView("No Playlists Yet", systemImage: "music.note.list")
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView.search(text: model.query)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section(model.query.isEmpty ? "Your Playlists" : "") {
                    ForEach(shown) { playlist in
                        row(playlist)
                    }
                }
            }
        }
    }

    private func row(_ playlist: PlaylistSummary) -> some View {
        Button {
            model.add(to: playlist) { finish($0) }
        } label: {
            HStack(spacing: Space.snug) {
                PlaylistArtworkView(
                    identity: playlist.id,
                    artworkURL: playlist.artworkURL,
                    trackArtworkURLs: [],
                    style: .phone
                )
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(playlist.trackCount.trackCountLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.pendingID == playlist.id {
                    ProgressView()
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isAdding)
        .accessibilityLabel("\(playlist.title), \(playlist.trackCount.trackCountLabel)")
        .accessibilityHint("Adds \(track.title)")
    }

    private func finish(_ playlist: PlaylistSummary) {
        finished.toggle()
        onAdded(playlist)
        dismiss()
    }
}

extension View {
    func upNextTrackDropTarget() -> some View {
        modifier(MiniPlayerDropTarget())
    }
}

private struct MiniPlayerDropTarget: ViewModifier {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    func body(content: Content) -> some View {
        content.upNextOutlineTarget { tracks in
            for track in tracks { coordinator.addToQueue(track) }
        }
    }
}
