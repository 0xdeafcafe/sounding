import Foundation
import SwiftUI

#if canImport(AVFoundation) && !os(tvOS)
@MainActor
private final class SetlistPreviewController: ObservableObject {
    @Published private(set) var activeID: String?
    @Published private(set) var label: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var requestTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var requestGeneration = 0

    func previewSet(track: Track, at position: TimeInterval, id: String, label: String) {
        if activeID == id {
            stop(resumeMainPlayback: true)
            return
        }
        beginPreview(track: track, position: position, id: id, label: label)
    }

    func previewSong(_ track: Track, id: String? = nil) {
        let previewID = id ?? "song#\(track.id)"
        if activeID == previewID {
            stop(resumeMainPlayback: true)
            return
        }
        beginPreview(track: track, position: 0, id: previewID, label: track.title)
    }

    func stop(resumeMainPlayback: Bool) {
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
        stopTask?.cancel()
        stopTask = nil
        activeID = nil
        label = nil
        isLoading = false

        Task { @MainActor in
            await PlayerService.shared.endPreviewPlayback(resumeOriginal: resumeMainPlayback)
        }
    }

    private func beginPreview(
        track: Track,
        position: TimeInterval,
        id: String,
        label: String
    ) {
        requestGeneration &+= 1
        let generation = requestGeneration
        requestTask?.cancel()
        stopTask?.cancel()
        errorMessage = nil
        activeID = id
        self.label = label
        isLoading = true

        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await PlayerService.shared.beginPreviewPlayback(of: track, at: position)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if let playbackError = PlayerService.shared.playbackErrorMessage {
                errorMessage = playbackError
                stop(resumeMainPlayback: true)
                return
            }
            isLoading = false
            stopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self?.requestGeneration == generation else { return }
                self?.stop(resumeMainPlayback: true)
            }
        }
    }
}
#endif

struct SetlistEditorView: View {
    let track: Track
    let currentPosition: TimeInterval
    let comments: [Comment]
    let localFileURL: URL?
    let onSeek: (TimeInterval) -> Void
    let onDownload: () -> Void
    let onPlaySearchResult: (Track) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SetlistIntelligenceStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var editingSegment: SetlistSegment?
    @State private var searchingSegment: SetlistSegment?
    @State private var playlistSegment: SetlistSegment?
    @State private var playingLinkedSegmentID: String?
    @State private var segmentActionError: String?
    @State private var shouldScanAfterDownload = false
    @State private var downloadScanMessage: String?
    @State private var trackAnalysis: TrackAnalysisSummary?
    #if canImport(AVFoundation) && !os(tvOS)
    @StateObject private var preview = SetlistPreviewController()
    #endif

    var body: some View {
        NavigationStack {
            container
                .navigationDestination(for: SetlistRoute.self) { route in
                    SetlistPage(route: route)
                }
                .navigationTitle("Setlist")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                #if !os(tvOS)
                .toolbar { toolbarContent }
                #endif
        }
        .task(id: "\(track.id)#\(comments.count)") {
            store.seed(track: track, comments: comments)
            if comments.isEmpty {
                await store.hydrateMetadataIfNeeded(for: track)
            }
        }
        .task(id: track.id) {
            trackAnalysis = await AnalysisLookup.summaries(for: [track])[track.id]
        }
        .onChange(of: downloadState, initial: true) { _, state in
            handleDownloadState(state)
        }
        .onDisappear {
            #if canImport(AVFoundation) && !os(tvOS)
            preview.stop(resumeMainPlayback: true)
            #endif
        }
        .sheet(item: $editingSegment) { segment in
            SetlistSegmentEditView(segment: segment) { updated in
                store.update(updated, trackId: track.id)
            }
        }
        .sheet(item: $searchingSegment) { segment in
            SetlistSoundCloudSearchView(
                segment: segment,
                onLink: { result in store.link(result, to: segment.id, trackId: track.id) },
                onPlay: { result in
                    #if canImport(AVFoundation) && !os(tvOS)
                    preview.previewSong(result)
                    #else
                    onPlaySearchResult(result)
                    #endif
                }
            )
        }
        .sheet(item: $playlistSegment) { segment in
            if let soundCloudTrackID = segment.soundCloudTrackId {
                SetlistPlaylistPickerView(
                    soundCloudTrackID: soundCloudTrackID,
                    trackLabel: segment.displayLabel
                )
            }
        }
        .alert("Couldn’t Complete", isPresented: Binding(
            get: { segmentActionError != nil },
            set: { if !$0 { segmentActionError = nil } }
        )) {
            Button("OK", role: .cancel) { segmentActionError = nil }
        } message: {
            Text(segmentActionError ?? "")
        }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        Form { sections }
            .formStyle(.grouped)
        #else
        List { sections }
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            scanStatus
            if let trackAnalysis, !trackAnalysis.isEmpty {
                trackAnalysis.badgeRow(style: analysisStyle)
            }
            if let currentSegment {
                Button { previewInSet(currentSegment) } label: {
                    LabeledContent("Current Track", value: currentSegment.displayLabel)
                }
            }
            #if canImport(AVFoundation) && !os(tvOS)
            if preview.isLoading || preview.activeID != nil {
                HStack {
                    if preview.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(preview.label ?? "Preview", systemImage: "headphones")
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") { preview.stop(resumeMainPlayback: true) }
                }
            }
            #endif
        } header: {
            Text("Identify")
        } footer: {
            Text("Needs the mix downloaded first. Tracks are matched with Shazam, helped by timestamps from the uploader and listeners.")
        }

        Section {
            if segments.isEmpty {
                ContentUnavailableView(
                    "No Tracks Yet",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("Use Identify Tracks to fill in this list.")
                )
            } else {
                segmentRows
            }
            Button(action: addTrackAtCurrentPosition) {
                Label("Add Track at \(SetlistViewFormat.clock(currentPosition))", systemImage: "plus")
            }
        } header: {
            Text("Tracks")
        }

        #if os(tvOS)
        Section {
            Button {
                store.setSaved(!isSaved, trackId: track.id)
            } label: {
                Label(
                    isSaved ? "Remove from Saved Setlists" : "Save Setlist",
                    systemImage: isSaved ? "bookmark.slash" : "bookmark"
                )
            }
        }
        #endif

        if !store.savedSetlists.isEmpty {
            Section {
                NavigationLink {
                    SavedSetlistsLibraryView()
                } label: {
                    LabeledContent("Saved Setlists", value: "\(store.savedSetlists.count)")
                }
            }
        }
    }

    #if !os(tvOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            EditButton()
        }
        #endif
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.setSaved(!isSaved, trackId: track.id)
            } label: {
                Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
            }
        }
        if isSaved, let setlist {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: store.exportText(for: setlist))
            }
        }
    }
    #endif

    private var analysisStyle: SCContentStyle {
        #if os(macOS)
        .mac
        #elseif os(tvOS)
        .tv
        #else
        .phone
        #endif
    }

    private var setlist: GeneratedSetlist? { store.setlist(for: track.id) }
    private var segments: [SetlistSegment] {
        setlist?.activeSegments ?? []
    }
    private var currentSegment: SetlistSegment? { setlist?.segment(at: currentPosition) }
    private var isSaved: Bool { setlist?.isSaved ?? false }
    private var isScanning: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_NOW_PLAYING_REVIEW"] == "setlistScanning" {
            return true
        }
        #endif
        return store.scanningTrackIds.contains(track.id)
    }

    private var progress: SetlistScanProgress? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_NOW_PLAYING_REVIEW"] == "setlistScanning" {
            return SetlistScanProgress(completed: 17, total: 64, positionSeconds: 1_118)
        }
        #endif
        return store.scanProgress[track.id]
    }

    private var downloadState: DownloadState {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_NOW_PLAYING_REVIEW"] == "setlistDownloading" {
            return .downloading(progress: 0.42)
        }
        #endif
        return downloads.state(for: track.id)
    }
    private var canScanAudio: Bool { localFileURL != nil || downloads.isLocallyAvailable(track) }

    @ViewBuilder
    private var scanStatus: some View {
        if isScanning {
            ProgressView(value: progress?.fraction) {
                Text("Identifying")
            } currentValueLabel: {
                Text(scanProgressLabel)
            }
        } else if isDownloading {
            DownloadFractionReader(trackId: track.id) { _ in
                ProgressView(value: downloadFraction) {
                    Text(downloadHeadline)
                } currentValueLabel: {
                    Text(downloadDetail)
                }
            }
            Button(role: .destructive) {
                shouldScanAfterDownload = false
                downloads.removeDownload(.track(track.id))
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else if case .paused = downloadState {
            LabeledContent("Download", value: "Paused")
            Button {
                shouldScanAfterDownload = true
                downloads.resume(trackId: track.id)
            } label: {
                Label("Resume Download", systemImage: "arrow.down.circle")
            }
        } else if case .failed(let reason) = downloadState {
            Label(reason, systemImage: "exclamationmark.triangle")
            Button(action: beginDownloadAndScan) {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
        } else if let error = store.scanErrors[track.id] {
            Label(error, systemImage: "exclamationmark.triangle")
            if canScanAudio {
                Button(action: beginAudioScan) {
                    Label("Retry Identify", systemImage: "arrow.clockwise")
                }
            }
        } else {
            LabeledContent("Coverage", value: scanCounts)

            if canScanAudio {
                Button(action: beginAudioScan) {
                    Label(
                        (setlist?.completedProbeCount ?? 0) > 0 ? "Identify Remaining" : "Identify Tracks",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                }
            } else {
                Button(action: beginDownloadAndScan) {
                    Label("Identify Tracks", systemImage: "waveform.badge.magnifyingglass")
                }
            }

            if let downloadScanMessage {
                Label(downloadScanMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isDownloading: Bool {
        switch downloadState {
        case .queued, .downloading: return true
        default: return false
        }
    }

    private var downloadFraction: Double? {
        switch downloadState {
        case .downloading(let progress), .paused(let progress): return progress
        default: return nil
        }
    }

    private var downloadHeadline: String {
        switch downloadState {
        case .queued: return "Waiting to Download"
        case .downloading: return "Downloading"
        default: return "Preparing"
        }
    }

    private var downloadDetail: String {
        guard let fraction = downloadFraction else { return "Identifying starts when the download finishes" }
        return "\(Int((fraction * 100).rounded()))% · Identifying starts when finished"
    }

    private var scanProgressLabel: String {
        guard let progress else { return scanCounts }
        let position = progress.positionSeconds.map { " · \(SetlistViewFormat.clock($0))" } ?? ""
        return "\(progress.completed) of \(progress.total)\(position) · \(segments.count) tracks"
    }

    private func beginDownloadAndScan() {
        downloadScanMessage = nil
        if let refusal = downloads.downloadRefusalReason(for: track) {
            downloadScanMessage = refusal.errorDescription ?? "This mix can’t be downloaded."
            return
        }
        shouldScanAfterDownload = true
        onDownload()
    }

    private func beginAudioScan() {
        shouldScanAfterDownload = false
        Task {
            let lease = await downloads.temporaryPlaintextFile(for: track)
            guard let fileURL = lease?.url ?? localFileURL else {
                downloadScanMessage = "The downloaded audio couldn’t be opened."
                return
            }
            await store.retryUnknowns(track: track, localFileURL: fileURL, comments: comments)
            lease?.release()
        }
    }

    private func handleDownloadState(_ state: DownloadState) {
        switch state {
        case .queued, .downloading:
            shouldScanAfterDownload = true
        case .downloaded:
            if shouldScanAfterDownload { beginAudioScan() }
        case .notDownloaded, .paused, .failed:
            break
        }
    }

    private var scanCounts: String {
        guard let setlist else { return "Not identified" }
        let matches = setlist.recognizedProbeCount
        let probes = setlist.completedProbeCount
        if probes == 0 {
            return segments.isEmpty
                ? "Not identified"
                : "\(segments.count) tracks · Not identified"
        }
        return "\(segments.count) tracks · \(matches) of \(probes) spots matched"
    }

    // MARK: - Rows

    @ViewBuilder
    private var segmentRows: some View {
        #if os(tvOS)
        ForEach(segments) { segment in
            segmentRow(segment)
        }
        #else
        ForEach(segments) { segment in
            segmentRow(segment)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        store.remove(segmentId: segment.id, trackId: track.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    Button { editingSegment = segment } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                .swipeActions(edge: .leading) {
                    if segment.soundCloudTrackId != nil {
                        Button { previewLinkedTrack(for: segment) } label: {
                            Label("Preview Track", systemImage: "headphones")
                        }
                        .tint(Color.scAccent)
                    } else {
                        Button { searchingSegment = segment } label: {
                            Label("Find", systemImage: "magnifyingglass")
                        }
                        .tint(Color.scAccent)
                    }
                }
        }
        .onDelete { offsets in
            for segment in offsets.map({ segments[$0] }) {
                store.remove(segmentId: segment.id, trackId: track.id)
            }
        }
        #endif
    }

    private func segmentRow(_ segment: SetlistSegment) -> some View {
        Button { previewInSet(segment) } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    if playingLinkedSegmentID == segment.id {
                        ProgressView()
                            .controlSize(.small)
                    } else if currentSegment?.id == segment.id {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.tint)
                    }
                    Text(segmentTimeRange(segment))
                        .monospacedDigit()
                }
            } label: {
                Text(segment.displayLabel)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(segmentDetail(segment))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .libraryRowPreviewShape()
        .contextMenu { segmentMenuItems(for: segment) }
        .accessibilityLabel(segment.displayLabel)
    }

    @ViewBuilder
    private func segmentMenuItems(for segment: SetlistSegment) -> some View {
        Button { previewInSet(segment) } label: {
            Label("Preview Here", systemImage: "play")
        }
        if segment.soundCloudTrackId != nil {
            Button { previewLinkedTrack(for: segment) } label: {
                Label("Preview Track", systemImage: "headphones")
            }
            Button { playlistSegment = segment } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
        Divider()
        Button { editingSegment = segment } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button { searchingSegment = segment } label: {
            Label(
                segment.soundCloudTrackId == nil ? "Find on SoundCloud" : "Change Link",
                systemImage: "magnifyingglass"
            )
        }
        Button(role: .destructive) {
            store.remove(segmentId: segment.id, trackId: track.id)
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func segmentDetail(_ segment: SetlistSegment) -> String {
        var parts = [segment.source.displayName]
        if segment.shazamId != nil, segment.source != .shazam { parts.append("Shazam") }
        if segment.soundCloudTrackId != nil { parts.append("Linked") }
        return parts.joined(separator: " · ")
    }

    private func segmentTimeRange(_ segment: SetlistSegment) -> String {
        guard let setlist else { return SetlistViewFormat.clock(segment.startSeconds) }
        return "\(SetlistViewFormat.clock(segment.startSeconds))–\(SetlistViewFormat.clock(setlist.endSeconds(for: segment)))"
    }

    private func previewInSet(_ segment: SetlistSegment) {
        #if canImport(AVFoundation) && !os(tvOS)
        preview.previewSet(
            track: track,
            at: segment.startSeconds,
            id: "set#\(segment.id)",
            label: segment.displayLabel
        )
        #else
        onSeek(segment.startSeconds)
        #endif
    }

    private func previewLinkedTrack(for segment: SetlistSegment) {
        guard let soundCloudTrackID = segment.soundCloudTrackId,
              playingLinkedSegmentID == nil else { return }
        playingLinkedSegmentID = segment.id
        Task { @MainActor in
            defer { playingLinkedSegmentID = nil }
            do {
                let linkedTrack = try await SoundCloudAPI.shared.getTrack(id: soundCloudTrackID)
                #if canImport(AVFoundation) && !os(tvOS)
                preview.previewSong(linkedTrack, id: "linked#\(segment.id)")
                #else
                onPlaySearchResult(linkedTrack)
                #endif
            } catch {
                segmentActionError = error.localizedDescription
            }
        }
    }

    private func addTrackAtCurrentPosition() {
        let position = min(max(0, currentPosition), max(track.duration, 0))
        editingSegment = SetlistSegment(
            id: "user#\(UUID().uuidString)",
            startSeconds: position,
            observedAtSeconds: position,
            artist: nil,
            title: "",
            version: nil,
            source: .user,
            confidence: 1,
            evidence: "Added manually",
            shazamId: nil,
            soundCloudTrackId: nil,
            isUserEdited: true,
            updatedAt: Date()
        )
    }
}

struct SavedSetlistsCount<Content: View>: View {
    @ObservedObject private var store = SetlistIntelligenceStore.shared
    @ViewBuilder var content: (Int) -> Content

    var body: some View {
        content(store.savedSetlists.count)
    }
}

struct SavedSetlistsLabel: View {
    let count: Int

    var body: some View {
        LabeledContent {
            Text("\(count)")
                .monospacedDigit()
        } label: {
            Label("Setlists", systemImage: "list.number")
        }
    }
}

struct SavedSetlistsLibraryView: View {
    @ObservedObject private var store = SetlistIntelligenceStore.shared
    @State private var tracks: [String: Track] = [:]

    var body: some View {
        List {
            ForEach(store.savedSetlists, id: \.trackId) { setlist in
                NavigationLink(value: SetlistRoute(trackId: setlist.trackId, track: tracks[setlist.trackId])) {
                    SavedSetlistRow(setlist: setlist, track: tracks[setlist.trackId])
                }
                #if !os(tvOS)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.setSaved(false, trackId: setlist.trackId)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                #endif
                .contextMenu {
                    Button(role: .destructive) {
                        store.setSaved(false, trackId: setlist.trackId)
                    } label: {
                        Label("Remove from Setlists", systemImage: "bookmark.slash")
                    }
                }
            }
        }
        .navigationTitle("Setlists")
        .overlay {
            if !store.isLoaded {
                ContentUnavailableView {
                    Label {
                        Text("Loading Setlists")
                    } icon: {
                        ProgressView()
                    }
                }
            } else if store.savedSetlists.isEmpty {
                ContentUnavailableView {
                    SoundingArtEmptyLabel(title: "No Saved Setlists", identity: "empty.setlists", motif: .crossfader)
                } description: {
                    Text("Open a mix's setlist while it plays and tap the bookmark to keep it here.")
                }
            }
        }
        .task(id: store.savedSetlists.map(\.trackId)) {
            let ids = store.savedSetlists.map(\.trackId).filter { tracks[$0] == nil }
            guard !ids.isEmpty else { return }
            let found = await SetlistTrackLookup.tracks(ids: ids)
            tracks.merge(found) { _, new in new }
        }
    }
}

private struct SavedSetlistRow: View {
    let setlist: GeneratedSetlist
    let track: Track?

    var body: some View {
        HStack(spacing: 12) {
            SetlistArtwork(url: track?.artworkURL, identity: setlist.trackId, size: SetlistMetrics.rowArtwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(SetlistText.normalized(setlist.trackTitle))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let artist = track?.user.displayName, !artist.isEmpty { parts.append(artist) }
        parts.append(SetlistViewFormat.trackCount(setlist.activeSegments.count))
        if setlist.duration > 0 { parts.append(SetlistViewFormat.length(setlist.duration)) }
        return parts.joined(separator: " · ")
    }
}

struct SetlistRoute: Hashable {
    let trackId: String
    var track: Track?

    init(trackId: String, track: Track? = nil) {
        self.trackId = trackId
        self.track = track
    }

    init(track: Track) {
        self.init(trackId: track.id, track: track)
    }

    static func == (lhs: SetlistRoute, rhs: SetlistRoute) -> Bool { lhs.trackId == rhs.trackId }

    func hash(into hasher: inout Hasher) { hasher.combine(trackId) }
}

struct SetlistPlaybackActions {
    var play: @MainActor (Track, [Track]) -> Void = { track, context in
        Task { await PlayerService.shared.play(track, in: context) }
    }
    var playSet: @MainActor (Track, TimeInterval) -> Void = { track, position in
        Task {
            if PlayerService.shared.currentTrack?.id != track.id {
                await PlayerService.shared.play(track, in: [track])
            }
            PlayerService.shared.seek(to: position)
        }
    }
    var position: @MainActor (Track) -> TimeInterval? = { track in
        PlayerService.shared.currentTrack?.id == track.id ? PlayerService.shared.currentTime : nil
    }
}

extension EnvironmentValues {
    @Entry var setlistPlaybackActions = SetlistPlaybackActions()
}

@MainActor
enum SetlistTrackLookup {
    static func tracks(ids: [String]) async -> [String: Track] {
        var seen = Set<String>()
        let wanted = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !wanted.isEmpty else { return [:] }
        var found: [String: Track] = [:]
        for id in wanted {
            if let track = DownloadManager.shared.cachedTrack(forTrackId: id) { found[id] = track }
        }
        let local = Set(wanted.filter { found[$0] == nil && LocalTrackFile.isLocalTrackID($0) })
        if !local.isEmpty {
            for track in LocalMusicLibrary.shared.allTracks where local.contains(track.id) {
                found[track.id] = track
            }
        }
        let remote = wanted.filter { found[$0] == nil && !LocalTrackFile.isLocalTrackID($0) }
        guard !remote.isEmpty else { return found }
        let cached = await LibraryDB.cachedTracks(ids: remote)
        found.merge(cached) { current, _ in current }
        let missing = remote.filter { found[$0] == nil }
        guard !missing.isEmpty, let fetched = try? await SoundCloudAPI.shared.getTracks(ids: missing) else { return found }
        for track in fetched { found[track.id] = track }
        return found
    }
}

struct SetlistPage: View {
    let route: SetlistRoute

    @Environment(\.setlistPlaybackActions) private var actions
    @ObservedObject private var store = SetlistIntelligenceStore.shared
    @State private var resolved: Track?
    @State private var linked: [String: Track] = [:]
    @State private var isResolving = true
    @State private var isEditing = false
    @State private var editingPosition: TimeInterval = 0

    init(route: SetlistRoute) {
        self.route = route
        _resolved = State(initialValue: route.track)
    }

    private var setlist: GeneratedSetlist? { store.setlist(for: route.trackId) }
    private var entries: [TracklistEntry] { setlist?.tracklist.entries ?? [] }
    private var setTrack: Track? { resolved ?? route.track }

    private var title: String {
        if let setlist { return SetlistText.normalized(setlist.trackTitle) }
        return setTrack?.title ?? "Setlist"
    }

    private var duration: TimeInterval {
        max(setlist?.duration ?? 0, setTrack?.duration ?? 0)
    }

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if !os(tvOS)
            .toolbar {
                if let setlist, !entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: store.exportText(for: setlist))
                    }
                }
            }
            #endif
            .task(id: route.trackId) { await resolve() }
            #if os(tvOS)
            .fullScreenCover(isPresented: $isEditing) { editor }
            #else
            .sheet(isPresented: $isEditing) { editor }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if !store.isLoaded || (setlist == nil && setTrack == nil && isResolving) {
            ContentUnavailableView {
                Label {
                    Text("Loading Setlist")
                } icon: {
                    ProgressView()
                }
            }
        } else if setlist == nil, setTrack == nil {
            ContentUnavailableView(
                "Setlist Not Available",
                systemImage: "list.number",
                description: Text("This setlist isn’t in your library any more.")
            )
        } else {
            List {
                Section {
                    header
                        #if !os(tvOS)
                        .listRowSeparator(.hidden)
                        #endif
                        .listRowBackground(Color.clear)
                }
                Section {
                    if entries.isEmpty {
                        emptyTracklist
                    } else {
                        ForEach(entries) { entry in
                            SetlistEntryRow(
                                entry: entry,
                                linkedTrack: entry.segment.soundCloudTrackId.flatMap { linked[$0] },
                                canPlayHere: setTrack != nil,
                                onPlayHere: { play(from: entry) },
                                onPlayTrack: { track in actions.play(track, [track]) }
                            )
                        }
                    }
                } header: {
                    if !entries.isEmpty {
                        Text("Tracklist")
                    }
                } footer: {
                    if !entries.isEmpty, !footer.isEmpty {
                        Text(footer)
                    }
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: SetlistMetrics.headerSpacing) {
                SetlistArtwork(url: heroArtworkURL, identity: route.trackId, size: SetlistMetrics.heroArtwork, variant: .hero)
                headerDetails(alignment: .leading)
                    .frame(minWidth: SetlistMetrics.headerTextMinimum, alignment: .leading)
                Spacer(minLength: 0)
            }
            VStack(alignment: .center, spacing: 16) {
                SetlistArtwork(url: heroArtworkURL, identity: route.trackId, size: SetlistMetrics.compactHeroArtwork, variant: .hero)
                headerDetails(alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
    }

    private var heroArtworkURL: URL? {
        setTrack?.largeArtworkURL ?? setTrack?.artworkURL
    }

    private func headerDetails(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
                .lineLimit(3)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            if let artist = setTrack?.user.displayName, !artist.isEmpty {
                Text(artist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Button {
                    if let setTrack { actions.play(setTrack, [setTrack]) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(setTrack == nil)
                if setTrack != nil {
                    Button {
                        openEditor()
                    } label: {
                        Label(
                            entries.isEmpty ? "Identify Tracks" : "Edit",
                            systemImage: entries.isEmpty ? "waveform.badge.magnifyingglass" : "pencil"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var emptyTracklist: some View {
        if isResolving, setlist == nil {
            ContentUnavailableView {
                Label {
                    Text("Loading Tracklist")
                } icon: {
                    ProgressView()
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Tracks Identified", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text(setTrack == nil
                    ? "Open this mix while it plays to identify its tracks."
                    : "Identify Tracks finds what’s playing with Shazam, helped by timestamps from the uploader and listeners.")
            } actions: {
                if setTrack != nil {
                    Button("Identify Tracks") { openEditor() }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let setTrack {
            SetlistEditorView(
                track: setTrack,
                currentPosition: editingPosition,
                comments: [],
                localFileURL: PlayerService.shared.localAudioURL(for: setTrack),
                onSeek: { position in actions.playSet(setTrack, position) },
                onDownload: { _ = DownloadManager.shared.download(track: setTrack, confirmed: true) },
                onPlaySearchResult: { result in actions.play(result, [result]) }
            )
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 680)
            #endif
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !entries.isEmpty {
            let unidentified = entries.filter { SetlistViewFormat.isUnidentified($0.segment) }.count
            parts.append(SetlistViewFormat.trackCount(entries.count))
            if unidentified > 0 { parts.append("\(unidentified) unidentified") }
        }
        if duration > 0 { parts.append(SetlistViewFormat.length(duration)) }
        return parts.joined(separator: " · ")
    }

    private var footer: String {
        let sources = Set(entries.map(\.segment.source))
        let ordered: [(SetlistSegmentSource, String)] = [
            (.shazam, "Shazam"),
            (.uploaderTracklist, "the uploader’s track list"),
            (.listenerComment, "listener comments"),
            (.user, "your edits"),
        ]
        let names = ordered.filter { sources.contains($0.0) }.map { $0.1 }
        guard let last = names.last else { return "" }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "From \(list). Choose a track to play the set from there."
    }

    private func openEditor() {
        editingPosition = setTrack.flatMap { actions.position($0) } ?? 0
        isEditing = true
    }

    private func play(from entry: TracklistEntry) {
        guard let setTrack else { return }
        actions.playSet(setTrack, entry.startSeconds)
    }

    private func resolve() async {
        await store.waitUntilLoaded()
        let linkedIDs = (setlist?.activeSegments ?? []).compactMap(\.soundCloudTrackId)
        let ids = (resolved == nil ? [route.trackId] : []) + linkedIDs.filter { linked[$0] == nil }
        guard !ids.isEmpty else {
            isResolving = false
            return
        }
        let found = await SetlistTrackLookup.tracks(ids: ids)
        if resolved == nil { resolved = found[route.trackId] }
        for id in linkedIDs {
            if let track = found[id] { linked[id] = track }
        }
        isResolving = false
    }
}

private struct SetlistEntryRow: View {
    let entry: TracklistEntry
    let linkedTrack: Track?
    let canPlayHere: Bool
    let onPlayHere: () -> Void
    let onPlayTrack: (Track) -> Void

    private var isUnidentified: Bool { SetlistViewFormat.isUnidentified(entry.segment) }

    private var title: String {
        guard !isUnidentified else { return "ID" }
        let base = SetlistText.normalized(entry.segment.title)
        guard let version = SetlistText.normalized(entry.segment.version) else { return base }
        return "\(base) (\(version))"
    }

    private var subtitle: String {
        if let artist = SetlistText.normalized(entry.segment.artist), !artist.isEmpty {
            return isUnidentified ? "\(artist) · Not identified" : artist
        }
        return isUnidentified ? "Not identified" : (linkedTrack?.user.displayName ?? "")
    }

    var body: some View {
        Button {
            if canPlayHere {
                onPlayHere()
            } else if let linkedTrack {
                onPlayTrack(linkedTrack)
            }
        } label: {
            HStack(spacing: 12) {
                Text(SetlistViewFormat.clock(entry.startSeconds))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: SetlistMetrics.timeColumn, alignment: .trailing)
                SetlistArtwork(
                    url: linkedTrack?.artworkURL,
                    identity: entry.id,
                    size: SetlistMetrics.rowArtwork,
                    isUnidentified: isUnidentified
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(isUnidentified ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if entry.durationSeconds > 0 {
                    Text(SetlistViewFormat.clock(entry.durationSeconds))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
        .disabled(!canPlayHere && linkedTrack == nil)
        .contextMenu {
            if canPlayHere {
                Button(action: onPlayHere) {
                    Label("Play Set from Here", systemImage: "play")
                }
            }
            if let linkedTrack {
                Button {
                    onPlayTrack(linkedTrack)
                } label: {
                    Label("Play Track", systemImage: "music.note")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SetlistViewFormat.clock(entry.startSeconds)), \(title), \(subtitle)")
        .accessibilityHint(canPlayHere ? "Plays the set from this track" : "")
    }
}

private struct SetlistArtwork: View {
    let url: URL?
    let identity: String
    let size: CGFloat
    var variant: ArtworkVariant = .thumbnail
    var isUnidentified = false

    var body: some View {
        SCArtworkResolver(url: url, variant: variant) { image in
            SCArtwork(image: image, identity: identity, style: SetlistMetrics.style)
        }
        .overlay {
            if isUnidentified, url == nil {
                Image(systemName: "questionmark")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private enum SetlistMetrics {
    static var style: SCContentStyle {
        #if os(macOS)
        .mac
        #elseif os(tvOS)
        .tv
        #else
        .phone
        #endif
    }

    static var heroArtwork: CGFloat {
        #if os(tvOS)
        300
        #elseif os(macOS)
        180
        #else
        160
        #endif
    }

    static var compactHeroArtwork: CGFloat {
        #if os(tvOS)
        300
        #else
        220
        #endif
    }

    static var rowArtwork: CGFloat {
        #if os(tvOS)
        80
        #elseif os(macOS)
        36
        #else
        44
        #endif
    }

    static var timeColumn: CGFloat {
        #if os(tvOS)
        110
        #else
        56
        #endif
    }

    static var headerSpacing: CGFloat {
        #if os(tvOS)
        48
        #else
        20
        #endif
    }

    static var headerTextMinimum: CGFloat {
        #if os(tvOS)
        600
        #else
        220
        #endif
    }
}

private struct SetlistSegmentEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SetlistSegment
    let onSave: (SetlistSegment) -> Void

    init(segment: SetlistSegment, onSave: @escaping (SetlistSegment) -> Void) {
        _draft = State(initialValue: segment)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Artist", text: Binding(
                        get: { draft.artist ?? "" },
                        set: { draft.artist = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Title", text: $draft.title)
                    TextField("Version", text: Binding(
                        get: { draft.version ?? "" },
                        set: { draft.version = $0.isEmpty ? nil : $0 }
                    ))
                }
                Section {
                    LabeledContent("Starts At") {
                        TextField("Seconds", value: $draft.startSeconds, format: .number)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(draft.title.isEmpty ? "New Track" : "Edit Track")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.startSeconds = max(0, draft.startSeconds)
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}

private struct SetlistSoundCloudSearchView: View {
    let segment: SetlistSegment
    let onLink: (Track) -> Void
    let onPlay: (Track) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchGeneration = 0

    init(segment: SetlistSegment, onLink: @escaping (Track) -> Void, onPlay: @escaping (Track) -> Void) {
        self.segment = segment
        self.onLink = onLink
        self.onPlay = onPlay
        _query = State(initialValue: segment.searchQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { result in
                    Button {
                        onLink(result)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            SCArtworkResolver(url: result.artworkURL, variant: .thumbnail) { image in
                                if let image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Image(systemName: "music.note")
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(.quaternary)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .lineLimit(1)
                                Text(result.user.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contextMenu {
                        Button { onPlay(result) } label: {
                            Label("Preview", systemImage: "headphones")
                        }
                    }
                    #if !os(tvOS)
                    .swipeActions(edge: .leading) {
                        Button { onPlay(result) } label: {
                            Label("Preview", systemImage: "headphones")
                        }
                        .tint(Color.scAccent)
                    }
                    #endif
                }
            }
            .overlay {
                if isSearching, results.isEmpty {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Artist and Title")
            .navigationTitle("Link Track")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 500, idealHeight: 580)
        #endif
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    @MainActor
    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        isSearching = true
        errorMessage = nil
        defer {
            if generation == searchGeneration { isSearching = false }
        }
        do {
            var found = try await SoundCloudAPI.shared.searchTracks(query: trimmed, limit: 30).collection

            let titleOnly = segment.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if found.isEmpty,
               !titleOnly.isEmpty,
               titleOnly.caseInsensitiveCompare(trimmed) != .orderedSame {
                found = try await SoundCloudAPI.shared.searchTracks(query: titleOnly, limit: 30).collection
            }

            guard generation == searchGeneration, !Task.isCancelled else { return }
            var seen = Set<String>()
            results = found.filter { seen.insert($0.id).inserted }
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct SetlistPlaylistPickerView: View {
    let soundCloudTrackID: String
    let trackLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlaylistSummary] = []
    @State private var isLoading = true
    @State private var addingToPlaylistID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(playlists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            LabeledContent {
                                if addingToPlaylistID == playlist.id {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            } label: {
                                Text(playlist.title)
                            }
                        }
                        .disabled(addingToPlaylistID != nil)
                    }
                } header: {
                    Text(trackLabel)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn’t Load Playlists",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else if playlists.isEmpty {
                    ContentUnavailableView("No Playlists", systemImage: "music.note.list")
                }
            }
            .navigationTitle("Add to Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .task { await loadPlaylists() }
    }

    @MainActor
    private func loadPlaylists() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            playlists = try await SoundCloudAPI.shared.getMyPlaylists().collection
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(to playlist: PlaylistSummary) {
        guard addingToPlaylistID == nil else { return }
        addingToPlaylistID = playlist.id
        Task { @MainActor in
            do {
                try await SoundCloudAPI.shared.addTrack(soundCloudTrackID, toPlaylist: playlist.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                addingToPlaylistID = nil
            }
        }
    }
}

private enum SetlistViewFormat {
    static func trackCount(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count) tracks"
    }

    static func length(_ seconds: TimeInterval) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .abbreviated))
    }

    static func isUnidentified(_ segment: SetlistSegment) -> Bool {
        let title = SetlistText.normalized(segment.title)
        guard !title.isEmpty else { return true }
        return title.range(
            of: #"(?i)^(unknown|unreleased|track\s*id|tune\s*id|song\s*id|id|i\.d\.|n/?a|\?+)(\s*[-–—]\s*(id|unknown|\?+))?$"#,
            options: .regularExpression
        ) != nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let secs = value % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
