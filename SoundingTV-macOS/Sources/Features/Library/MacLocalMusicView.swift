import SwiftUI

struct MacSongsView: View {
    @ObservedObject var likesModel: MacLibraryModel

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var library = LocalMusicLibrary.shared
    @ObservedObject private var identityStore = LibraryIdentity.shared
    @ObservedObject private var analysisRun = MissingAnalysisRun.shared
    @State private var analysis: [String: MacAnalysisResult] = [:]
    @State private var isAdding = false
    @State private var isSigningIn = false
    @State private var folderFilter: String?
    @AppStorage("mac.songs.source", store: .sounding) private var sourceFilter = SourceFilter.all

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all, local, soundCloud
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .local: return "Files"
            case .soundCloud: return "SoundCloud"
            }
        }
    }

    private var hasSoundCloud: Bool { !credentials.isSignedOut }

    private var localTracks: [Track] {
        let folders = folderFilter.map { id in library.folders.filter { $0.id == id } } ?? library.folders
        return folders.flatMap { library.tracks(in: $0.id) }
    }

    private var soundCloudTracks: [Track] {
        guard hasSoundCloud, folderFilter == nil else { return [] }
        return likesModel.tracks
    }

    private var tracks: [Track] {
        switch sourceFilter {
        case .all:
            let local = localTracks
            let localIDs = Set(local.map(\.id))
            let identity = identityStore.index
            return local + soundCloudTracks.filter { liked in
                !localIDs.contains(liked.id) && identity.localCopy(of: liked).map { localIDs.contains($0.id) } != true
            }
        case .local:
            return localTracks
        case .soundCloud:
            return soundCloudTracks
        }
    }

    private var rows: [MacLibraryRow] {
        tracks.map {
            MacLibraryRow(
                track: $0,
                analysis: analysis[$0.id] ?? likesModel.analysis[$0.id],
                dateAdded: likesModel.likedAtByTrackID[$0.id] ?? $0.createdAt
            )
        }
    }

    var body: some View {
        let rows = rows
        Group {
            if rows.isEmpty {
                emptyState
                    .macFillsPane()
            } else {
                VStack(spacing: 0) {
                    if analysisRun.progress.isActive || analysisRun.isPaused {
                        MissingAnalysisProgressLine()
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                    MacLibraryTable(
                        rows: rows,
                        showsArtwork: true,
                        usesCompactRows: false,
                        onLoad: { track, deck in
                            Task { try? await MacMixLoader.load(track, into: deck) }
                        },
                        onDoubleClick: { play($0, in: rows.map(\.track)) },
                        onShowSetlist: { track in
                            MacRootSelection.shared.request(setlist: track)
                        },
                        onAnalysisChanged: { Task { await refreshAnalysis(rereadStore: false) } },
                        onNearEnd: { if hasSoundCloud { likesModel.loadMore() } },
                        storageKey: "songs",
                        showsSource: true
                    )
                }
            }
        }
        .navigationTitle("Tracks")
        .navigationSubtitle(rows.isEmpty ? "" : LocalMusicFormat.trackCount(rows.count))
        .toolbar {
            ToolbarItem {
                Menu("Show", systemImage: "line.3.horizontal.decrease") {
                    if hasSoundCloud {
                        Picker("Source", selection: $sourceFilter) {
                            ForEach(SourceFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    }
                    if library.folders.count > 1 {
                        Picker("Folder", selection: $folderFilter) {
                            Text("All Folders").tag(String?.none)
                            ForEach(library.folders) { folder in
                                Text(folder.name).tag(Optional(folder.id))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    Section {
                        AnalyseMissingMenuItems(tracks: rows.map(\.track), scopeTitle: "Tracks")
                    }
                    Section {
                        Button("Add Folder…", systemImage: "folder.badge.plus") { isAdding = true }
                        Button("Rescan Folders", systemImage: "arrow.clockwise") { library.rescanAll() }
                            .disabled(library.folders.isEmpty || !library.scanningFolderIDs.isEmpty)
                    }
                }
            }
        }
        .addMusicFolderImporter(isPresented: $isAdding)
        .sheet(isPresented: $isSigningIn) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: false) {
                isSigningIn = false
            }
        }
        .task(id: hasSoundCloud) {
            guard hasSoundCloud, likesModel.tracks.isEmpty else { return }
            likesModel.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
        }
        .task(id: localTracks.count) { await refreshAnalysis(rereadStore: true) }
        .onChange(of: library.folders, initial: true) { _, folders in
            for folder in folders { PlaybackQueueSourceDirectory.note(library.queueSource(for: folder)) }
            if let folderFilter, !folders.contains(where: { $0.id == folderFilter }) { self.folderFilter = nil }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.scanningFolderIDs.isEmpty {
            LocalMusicScanningState()
        } else if hasSoundCloud, likesModel.isLoading {
            ProgressView()
        } else {
            ContentUnavailableView {
                Label("No Music Yet", systemImage: "music.note")
            } description: {
                Text(hasSoundCloud
                     ? "Add a folder of your own music, or like tracks on SoundCloud."
                     : "Add a folder of your own music, or connect SoundCloud.")
            } actions: {
                Button("Add Folder…") { isAdding = true }
                if !hasSoundCloud {
                    Button("Connect SoundCloud") { isSigningIn = true }
                }
            }
        }
    }

    private func play(_ track: Track, in context: [Track]) {
        if let file = track.localFile, let folder = library.folder(id: file.folderID), sourceFilter == .local || folderFilter != nil {
            let source = library.queueSource(for: folder)
            Task {
                await MacPlayback.play(track, in: library.tracks(in: folder.id), collectionId: source.id, source: source)
            }
            return
        }
        Task { await MacPlayback.play(track, in: context) }
    }

    private func refreshAnalysis(rereadStore: Bool) async {
        if rereadStore { await MacAnalysisIndex.shared.refresh() }
        var results: [String: MacAnalysisResult] = [:]
        for track in localTracks {
            results[track.id] = MacAnalysisIndex.shared.result(forTrackId: track.id)
        }
        analysis = results
    }
}
