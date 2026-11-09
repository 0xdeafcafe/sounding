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

    var body: some View {
        List {
            ForEach(store.savedSetlists, id: \.trackId) { setlist in
                NavigationLink {
                    SavedSetlistDetailView(setlist: setlist)
                } label: {
                    LabeledContent {
                        Text("\(setlist.activeSegments.count)")
                    } label: {
                        Text(setlist.trackTitle)
                    }
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
            }
        }
        .navigationTitle("Setlists")
        .overlay {
            if store.savedSetlists.isEmpty {
                ContentUnavailableView {
                    SoundingArtEmptyLabel(title: "No Saved Setlists", identity: "empty.setlists", motif: .crossfader)
                } description: {
                    Text("Open a mix's setlist while it plays and tap the bookmark to keep it here.")
                }
            }
        }
    }
}

private struct SavedSetlistDetailView: View {
    let setlist: GeneratedSetlist
    @ObservedObject private var store = SetlistIntelligenceStore.shared

    var body: some View {
        List {
            ForEach(setlist.activeSegments) { segment in
                LabeledContent {
                    Text("\(SetlistViewFormat.clock(segment.startSeconds))–\(SetlistViewFormat.clock(setlist.endSeconds(for: segment)))")
                        .monospacedDigit()
                } label: {
                    Text(segment.displayLabel)
                }
            }
        }
        .navigationTitle(setlist.trackTitle)
        #if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: store.exportText(for: setlist))
            }
        }
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
