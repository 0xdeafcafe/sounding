#if os(iOS) || os(macOS)
import SwiftUI

struct NewPlaylistSheet: View {
    var trackIDs: [String] = []
    let onCreated: (Playlist) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var title = ""
    @State private var details = ""
    @State private var isPrivate = true
    @State private var isCreating = false
    @State private var failure: String?
    @FocusState private var focusesTitle: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canCreate: Bool { !trimmedTitle.isEmpty && !isCreating && !credentials.isSignedOut }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($focusesTitle)
                        .onSubmit(create)
                    TextField("Description (Optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Picker("Visibility", selection: $isPrivate) {
                        Text("Private").tag(true)
                        Text("Public").tag(false)
                    }
                } footer: {
                    if let failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    } else if credentials.isSignedOut {
                        Text("Sign in to SoundCloud to make playlists.")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            .navigationTitle("New Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create", action: create)
                            .disabled(!canCreate)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
        .interactiveDismissDisabled(isCreating)
        .onAppear { focusesTitle = true }
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        failure = nil
        let title = trimmedTitle
        let details = details
        let isPrivate = isPrivate
        let trackIDs = trackIDs
        Task {
            do {
                let playlist = try await PlaylistCreation.create(
                    title: title,
                    description: details,
                    isPrivate: isPrivate,
                    trackIds: trackIDs
                )
                isCreating = false
                dismiss()
                onCreated(playlist)
            } catch {
                isCreating = false
                failure = PlaylistEditFailure.message(for: error, action: "make the playlist")
            }
        }
    }
}

struct AddTracksSheet: View {
    let playlist: Playlist
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var selection: Set<String> = []
    @State private var isAdding = false
    @State private var failure: String?

    private var shown: [Track] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.user.displayName.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Tracks")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .searchable(text: $searchText, prompt: "Search Your Likes")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .disabled(isAdding)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isAdding {
                            ProgressView()
                        } else {
                            Button(selection.isEmpty ? "Add" : "Add \(selection.count)", action: add)
                                .disabled(selection.isEmpty)
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .interactiveDismissDisabled(isAdding)
        .alert("Couldn’t Add Tracks", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            ContentUnavailableView(
                "No Likes Yet",
                systemImage: "heart",
                description: Text("Tracks you like on SoundCloud appear here to add.")
            )
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(shown) { track in
                Button {
                    toggle(track.id)
                } label: {
                    row(track)
                }
                .buttonStyle(.plain)
                .disabled(isAdding)
            }
            .listStyle(.plain)
        }
    }

    private func row(_ track: Track) -> some View {
        let isSelected = selection.contains(track.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                Text(track.user.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.scAccent : Color.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func load() async {
        let page = await LibraryDB.tracks(.likes, offset: 0, limit: 1_000)
        tracks = page.tracks.filter { !$0.isLocal }
        isLoading = false
    }

    private func add() {
        guard !selection.isEmpty, !isAdding else { return }
        let ordered = tracks.map(\.id).filter { selection.contains($0) }
        isAdding = true
        Task {
            do {
                try await SoundCloudAPI.shared.addTracks(ordered, toPlaylist: playlist.id)
                LibrarySyncEngine.shared.requestRefresh([.ownPlaylists, .playlist(playlist.id)])
                isAdding = false
                dismiss()
                onAdded()
            } catch {
                isAdding = false
                failure = PlaylistEditFailure.message(for: error, action: "add the tracks")
            }
        }
    }
}

struct AddTracksEmptyState: View {
    let playlist: Playlist
    let onAdded: () -> Void

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var isAdding = false

    private var isOwned: Bool {
        guard let user = credentials.currentUser else { return false }
        return user.id == playlist.user.id && !playlist.isAlbum
    }

    var body: some View {
        if isOwned {
            ContentUnavailableView {
                Label("No Tracks Yet", systemImage: "music.note.list")
            } description: {
                Text("Add tracks from your likes.")
            } actions: {
                Button("Add Tracks") { isAdding = true }
                    .buttonStyle(.borderedProminent)
            }
            .sheet(isPresented: $isAdding) {
                AddTracksSheet(playlist: playlist, onAdded: onAdded)
            }
        } else {
            ContentUnavailableView(
                "Empty Playlist",
                systemImage: "music.note.list",
                description: Text("This playlist has no tracks.")
            )
        }
    }
}
#endif
