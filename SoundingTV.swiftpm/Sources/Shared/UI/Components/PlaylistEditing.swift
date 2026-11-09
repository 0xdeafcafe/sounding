#if os(iOS) || os(macOS)
import SwiftUI

struct PlaylistEditActions {
    var edit: @MainActor (Playlist, [Track]) -> Void = { _, _ in }
    var delete: @MainActor (Playlist) -> Void = { _ in }
    var report: @MainActor (String, String) -> Void = { _, _ in }
    var isAvailable = false
}

struct PlaylistTrackEditing {
    let trackIDs: Set<String>
    let remove: @MainActor (Set<String>) -> Void
    let move: @MainActor (String, String) -> Void
}

extension EnvironmentValues {
    @Entry var playlistEditActions: PlaylistEditActions = PlaylistEditActions()
    @Entry var playlistTrackEditing: PlaylistTrackEditing? = nil
}

extension View {
    func playlistEditingHost() -> some View {
        modifier(PlaylistEditingHost())
    }

    func playlistEditing(_ viewModel: PlaylistDetailViewModel, onRootDelete: (@MainActor () -> Void)? = nil) -> some View {
        modifier(PlaylistPageEditing(viewModel: viewModel, onRootDelete: onRootDelete))
    }

    func playlistRowEditing(_ track: Track, reorders: Bool) -> some View {
        modifier(PlaylistRowEditing(track: track, reorders: reorders))
    }
}

enum PlaylistTrackOrder {
    static func moving(_ id: String, onto target: String, in tracks: [Track]) -> [Track]? {
        guard let from = tracks.firstIndex(where: { $0.id == id }),
              let to = tracks.firstIndex(where: { $0.id == target }),
              from != to else { return nil }
        var next = tracks
        let moved = next.remove(at: from)
        next.insert(moved, at: to)
        return next
    }

    static let dragPrefix = "red.forbes.sounding.playlist-row:"

    static func dragToken(_ id: String) -> String { dragPrefix + id }

    static func trackID(fromToken token: String) -> String? {
        guard token.hasPrefix(dragPrefix) else { return nil }
        let id = String(token.dropFirst(dragPrefix.count))
        return id.isEmpty ? nil : id
    }
}

private struct PlaylistEditRequest: Identifiable {
    let playlist: Playlist
    let tracks: [Track]
    var id: String { playlist.id }
}

private struct PlaylistEditNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct PlaylistEditingHost: ViewModifier {
    @State private var editing: PlaylistEditRequest?
    @State private var deleting: Playlist?
    @State private var notice: PlaylistEditNotice?

    func body(content: Content) -> some View {
        content
            .environment(\.playlistEditActions, PlaylistEditActions(
                edit: { editing = PlaylistEditRequest(playlist: $0, tracks: $1) },
                delete: { deleting = $0 },
                report: { notice = PlaylistEditNotice(title: $0, message: $1) },
                isAvailable: true
            ))
            .sheet(item: $editing) { request in
                PlaylistEditSheet(playlist: request.playlist, tracks: request.tracks)
            }
            .playlistDeleteConfirmation($deleting, perform: delete)
            .alert(
                notice?.title ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                presenting: notice
            ) { _ in
                Button("OK", role: .cancel) { notice = nil }
            } message: { notice in
                Text(notice.message)
            }
    }

    private func delete(_ playlist: Playlist) {
        Task {
            do {
                try await PlaylistEditCenter.shared.delete(playlist)
            } catch {
                notice = PlaylistEditNotice(
                    title: "Couldn’t Delete Playlist",
                    message: PlaylistEditFailure.message(for: error, action: "delete the playlist")
                )
            }
        }
    }
}

@MainActor
private extension View {
    @ViewBuilder
    func playlistDeleteConfirmation(_ playlist: Binding<Playlist?>, perform: @escaping @MainActor (Playlist) -> Void) -> some View {
        let isPresented = Binding(
            get: { playlist.wrappedValue != nil },
            set: { if !$0 { playlist.wrappedValue = nil } }
        )
        if PlaylistEditLayout.confirmsWithAlert {
            alert(PlaylistEditCopy.deleteTitle, isPresented: isPresented, presenting: playlist.wrappedValue) { item in
                Button("Delete", role: .destructive) { perform(item) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(PlaylistEditCopy.deleteMessage)
            }
        } else {
            confirmationDialog(
                PlaylistEditCopy.deleteTitle,
                isPresented: isPresented,
                titleVisibility: .visible,
                presenting: playlist.wrappedValue
            ) { item in
                Button("Delete Playlist", role: .destructive) { perform(item) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(PlaylistEditCopy.deleteMessage)
            }
        }
    }
}

@MainActor
private enum PlaylistEditLayout {
    static var confirmsWithAlert: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
}

private struct PlaylistPageEditing: ViewModifier {
    @ObservedObject var viewModel: PlaylistDetailViewModel
    let onRootDelete: (@MainActor () -> Void)?

    @ObservedObject private var center = PlaylistEditCenter.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.playlistEditActions) private var actions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    private var id: String { viewModel.playlist.id }

    private var isOwned: Bool { viewModel.playlist.isOwned(by: credentials.currentUser?.id) }

    func body(content: Content) -> some View {
        content
            .environment(\.playlistTrackEditing, isOwned ? editing : nil)
            .onAppear {
                if let snapshot = center.snapshots[id] {
                    viewModel.applyEdit(snapshot.playlist, tracks: nil)
                }
            }
            .onChange(of: center.snapshots[id]) { _, snapshot in
                guard let snapshot else { return }
                viewModel.applyEdit(snapshot.playlist, tracks: snapshot.tracks)
            }
            .onChange(of: center.deletedIDs.contains(id)) { _, deleted in
                guard deleted else { return }
                if isPresented {
                    dismiss()
                } else {
                    onRootDelete?()
                }
            }
    }

    private var editing: PlaylistTrackEditing {
        let model = viewModel
        let actions = actions
        return PlaylistTrackEditing(
            trackIDs: Set(model.tracks.map(\.id)),
            remove: { ids in
                Task {
                    do {
                        try await PlaylistEditCenter.shared.remove(ids, from: model.playlist, tracks: model.tracks)
                    } catch {
                        actions.report(
                            ids.count == 1 ? "Couldn’t Remove Track" : "Couldn’t Remove Tracks",
                            PlaylistEditFailure.message(for: error, action: "change the playlist")
                        )
                    }
                }
            },
            move: { moved, target in
                let tracks = model.tracks
                guard let next = PlaylistTrackOrder.moving(moved, onto: target, in: tracks) else { return }
                Task {
                    do {
                        try await PlaylistEditCenter.shared.reorder(next, in: model.playlist, tracks: tracks)
                    } catch {
                        actions.report("Couldn’t Move Track", PlaylistEditFailure.message(for: error, action: "change the playlist"))
                    }
                }
            }
        )
    }
}

struct PlaylistManagementMenuItems: View {
    let playlist: Playlist
    var tracks: [Track]? = nil
    var includesPrivacy = true

    @ObservedObject private var center = PlaylistEditCenter.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.playlistEditActions) private var actions

    var body: some View {
        let current = center.current(playlist)
        if actions.isAvailable,
           current.isOwned(by: credentials.currentUser?.id),
           !center.deletedIDs.contains(current.id) {
            Divider()
            Button {
                actions.edit(current, tracks ?? current.loadedTracks)
            } label: {
                Label("Edit Playlist…", systemImage: "pencil")
            }
            if includesPrivacy {
                Button {
                    toggleSharing(current)
                } label: {
                    Label(
                        current.isPrivate ? "Make Public" : "Make Private",
                        systemImage: current.isPrivate ? "globe" : "lock"
                    )
                }
                .disabled(center.isBusy(current))
            }
            Button(role: .destructive) {
                actions.delete(current)
            } label: {
                Label("Delete Playlist…", systemImage: "trash")
            }
            .disabled(center.isBusy(current))
        }
    }

    private func toggleSharing(_ playlist: Playlist) {
        let actions = actions
        Task {
            do {
                try await PlaylistEditCenter.shared.setPrivate(!playlist.isPrivate, playlist: playlist)
            } catch {
                actions.report("Couldn’t Change Playlist", PlaylistEditFailure.message(for: error, action: "change the playlist"))
            }
        }
    }
}

struct RemoveFromPlaylistMenuItem: View {
    let track: Track
    @Environment(\.playlistTrackEditing) private var editing

    var body: some View {
        if let editing, editing.trackIDs.contains(track.id) {
            Button(role: .destructive) {
                editing.remove([track.id])
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        }
    }
}

private struct PlaylistRowEditing: ViewModifier {
    let track: Track
    let reorders: Bool

    @Environment(\.playlistTrackEditing) private var editing
    @FocusState private var isFocused: Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if let editing, editing.trackIDs.contains(track.id) {
            content
                #if os(macOS)
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .simultaneousGesture(TapGesture().onEnded { isFocused = true })
                .onDeleteCommand { editing.remove([track.id]) }
                #endif
                .modifier(PlaylistRowReordering(track: track, editing: editing, isEnabled: reorders, isTargeted: $isTargeted))
        } else {
            content
        }
    }
}

private struct PlaylistRowReordering: ViewModifier {
    let track: Track
    let editing: PlaylistTrackEditing
    let isEnabled: Bool
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .draggable(PlaylistTrackOrder.dragToken(track.id))
                .dropDestination(for: String.self) { items, _ in
                    guard let moved = items.lazy.compactMap(PlaylistTrackOrder.trackID(fromToken:)).first,
                          moved != track.id else { return false }
                    editing.move(moved, track.id)
                    return true
                } isTargeted: { isTargeted = $0 }
                .overlay(alignment: .top) {
                    if isTargeted {
                        Capsule()
                            .fill(Color.scAccent)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Edit sheet

struct PlaylistEditSheet: View {
    let playlist: Playlist

    private struct Entry: Identifiable {
        let id: Int
        let track: Track
    }

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var details: String
    @State private var isPublic: Bool
    @State private var original: [Track]
    @State private var entries: [Entry]
    @State private var isSaving = false
    @State private var failure: String?
    @State private var isLoadingTracks = false
    @State private var targetedEntry: Int?

    init(playlist: Playlist, tracks: [Track]) {
        self.playlist = playlist
        _title = State(initialValue: playlist.title)
        _details = State(initialValue: playlist.description ?? "")
        _isPublic = State(initialValue: !playlist.isPrivate)
        _original = State(initialValue: tracks)
        _entries = State(initialValue: tracks.enumerated().map { Entry(id: $0.offset, track: $0.element) })
    }

    private var draft: PlaylistDraft {
        var draft = PlaylistDraft(playlist: playlist, tracks: original)
        draft.title = title
        draft.description = details
        draft.isPrivate = !isPublic
        draft.tracks = entries.map(\.track)
        return draft
    }

    private var hasChanges: Bool { draft.differs(from: playlist, tracks: original) }

    private var canSave: Bool { !draft.trimmedTitle.isEmpty && !isSaving }

    private var hiddenCount: Int {
        max(0, playlist.totalTrackCount - original.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    artwork
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $details, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Toggle("Public", isOn: $isPublic)
                }

                tracksSection
            }
            .formStyle(.grouped)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .disabled(isSaving)
            .navigationTitle("Edit Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Done", action: save)
                            .disabled(!canSave)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 680)
        #endif
        .interactiveDismissDisabled(isSaving || hasChanges)
        .task { await loadStoredTracks() }
    }

    @ViewBuilder
    private var tracksSection: some View {
        Section {
            if entries.isEmpty, isLoadingTracks {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
                .onMove { source, destination in
                    entries.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    entries.remove(atOffsets: offsets)
                }
            }
        } header: {
            Text("Tracks")
        } footer: {
            if hiddenCount > 0, !isLoadingTracks {
                Text(hiddenCount == 1 ? "1 track that can’t be shown keeps its place." : "\(hiddenCount) tracks that can’t be shown keep their place.")
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            thumbnail(entry.track)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.title)
                    .lineLimit(1)
                Text(entry.track.user.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            #if os(macOS)
            Button {
                entries.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.plain)
            .help("Remove from Playlist")
            .accessibilityLabel("Remove \(entry.track.title)")
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            #endif
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .draggable(String(entry.id))
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first.flatMap(Int.init), moved != entry.id,
                  let from = entries.firstIndex(where: { $0.id == moved }),
                  let to = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
            let item = entries.remove(at: from)
            entries.insert(item, at: to)
            return true
        } isTargeted: { targeted in
            if targeted {
                targetedEntry = entry.id
            } else if targetedEntry == entry.id {
                targetedEntry = nil
            }
        }
        .overlay(alignment: .top) {
            if targetedEntry == entry.id {
                Capsule()
                    .fill(Color.scAccent)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        #endif
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var artwork: some View {
        let url = playlist.artworkURL ?? entries.first?.track.artworkURL ?? playlist.displayArtworkURL
        #if os(macOS)
        ArtworkThumbnail(url: url, identity: playlist.id, size: 140, cornerRadius: 10)
            .accessibilityHidden(true)
        #else
        ArtworkImage(url: url, variant: .standard, icon: "music.note.list", identity: playlist.id)
            .aspectRatio(1, contentMode: .fill)
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
        #endif
    }

    @ViewBuilder
    private func thumbnail(_ track: Track) -> some View {
        #if os(macOS)
        ArtworkThumbnail(url: track.artworkURL, identity: track.id, size: 36, cornerRadius: 4)
        #else
        ArtworkImage(url: track.artworkURL, variant: .thumbnail, identity: track.id)
            .aspectRatio(1, contentMode: .fill)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        #endif
    }

    private func loadStoredTracks() async {
        guard original.count < playlist.totalTrackCount else { return }
        isLoadingTracks = true
        defer { isLoadingTracks = false }
        guard let stored = await LibraryDB.playlistTracks(id: playlist.id),
              stored.count > original.count,
              entries.map(\.track.id) == original.map(\.id) else { return }
        original = stored
        entries = stored.enumerated().map { Entry(id: $0.offset, track: $0.element) }
    }

    private func save() {
        guard canSave else { return }
        let draft = draft
        guard draft.differs(from: playlist, tracks: original) else {
            dismiss()
            return
        }
        isSaving = true
        failure = nil
        let playlist = playlist
        let original = original
        Task {
            do {
                try await PlaylistEditCenter.shared.save(draft, playlist: playlist, tracks: original)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                failure = PlaylistEditFailure.message(for: error, action: "save the playlist")
            }
        }
    }
}
#endif
