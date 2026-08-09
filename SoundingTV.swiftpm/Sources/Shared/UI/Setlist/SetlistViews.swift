import Foundation
import SwiftUI

struct OnDecksIndicator: View {
    let identity: SetlistSegment?
    let isScanning: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var artworkColors = ArtworkColors.shared
    #endif

    var body: some View {
        #if os(tvOS)
        Button(action: action) {
            HStack(spacing: Space.snug) {
                Image(systemName: isScanning ? "waveform.badge.magnifyingglass" : "music.note.list")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(artworkColors.current.accent)
                    .symbolEffect(.pulse, isActive: isScanning && !reduceMotion)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tvOSDetail)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Color.scTextPrimary)
                        .lineLimit(1)
                    Text(tvOSContext)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.scTextTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: Space.snug)

                Text("Set list")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(focused ? Color.scTextPrimary : Color.scTextSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.scTextTertiary)
            }
            .padding(.horizontal, Space.snug)
            .frame(maxWidth: .infinity, minHeight: 72)
            .contentShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: Corner.control, style: .continuous),
                interactive: false
            )
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                .strokeBorder(Color.white.opacity(focused ? 0.28 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .scaleEffect(focused ? 1.025 : 1)
        .shadow(color: focused ? .black.opacity(0.32) : .clear, radius: 12, y: 5)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: focused)
        .accessibilityLabel(label)
        .accessibilityHint("Opens the detected set list")
        #else
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isScanning ? "waveform.badge.magnifyingglass" : "opticaldisc.fill")
                    .symbolEffect(.pulse, isActive: isScanning)
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(identity == nil ? "view" : "edit")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline.weight(.semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Opens the setlist we found")
        .scGlassCapsule()
        #endif
    }

    #if os(tvOS)
    private var tvOSDetail: String {
        if let identity { return identity.displayLabel }
        return isScanning ? "Identifying what is playing…" : "Nothing identified at this point"
    }

    private var tvOSContext: String {
        identity == nil ? "Detected set list" : "Playing now in this set"
    }
    #endif

    private var label: String {
        if let identity { return "Now in this set: \(identity.displayLabel)" }
        return isScanning ? "Setlist: identifying this track…" : "Setlist: track not identified"
    }
}

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
    @State private var discoveredLocalFileURL: URL?
    @State private var shouldScanAfterDownload = false
    @State private var downloadScanMessage: String?
    #if !SOUNDING_SHARE_EXTENSION
    @State private var trackAnalysis: TrackAnalysisSummary?
    #endif

    var body: some View {
        content
            .task(id: "\(track.id)#\(comments.count)") {
                store.seed(track: track, comments: comments)
            }
            .onChange(of: downloadState, initial: true) { _, state in
                handleDownloadState(state)
            }
            #if !SOUNDING_SHARE_EXTENSION
            .task(id: track.id) {
                trackAnalysis = await AnalysisLookup.summaries(for: [track])[track.id]
            }
            #endif
            .sheet(item: $editingSegment) { segment in
                SetlistSegmentEditView(segment: segment) { updated in
                    store.update(updated, trackId: track.id)
                }
            }
            .sheet(item: $searchingSegment) { segment in
                SetlistSoundCloudSearchView(
                    segment: segment,
                    onLink: { result in store.link(result, to: segment.id, trackId: track.id) },
                    onPlay: onPlaySearchResult
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvOSContent
        #else
        formContent
        #endif
    }

    private var formContent: some View {
        NavigationStack {
            List {
                Section {
                    scanStatus
                    #if !SOUNDING_SHARE_EXTENSION
                    if let trackAnalysis, !trackAnalysis.isEmpty {
                        #if os(macOS)
                        trackAnalysis.badgeRow(style: .mac)
                        #else
                        trackAnalysis.badgeRow(style: .phone)
                        #endif
                    }
                    #endif
                    if let currentSegment {
                        Button { onSeek(currentSegment.startSeconds) } label: {
                            LabeledContent("Now in this set", value: currentSegment.displayLabel)
                        }
                    }
                } header: {
                    Text("Audio scan")
                } footer: {
                    Text("Downloads this mix for offline playback, then checks sample points with Shazam. Uploader timestamps and useful listener IDs are included too. Progress is saved, so you can leave this screen.")
                }

                Section("Identified tracks") {
                    if segments.isEmpty {
                        ContentUnavailableView(
                            "Nothing Identified Yet",
                            systemImage: "waveform.badge.magnifyingglass",
                            description: Text("Start an audio scan above, or leave a synced Mac open to work on it there.")
                        )
                    } else {
                        ForEach(segments) { segment in
                            segmentRow(segment)
                        }
                    }
                }

                Section {
                    Button {
                        store.setSaved(!isSaved, trackId: track.id)
                    } label: {
                        Label(
                            isSaved ? "Remove Saved Setlist" : "Save Identified Setlist",
                            systemImage: isSaved ? "bookmark.slash" : "bookmark"
                        )
                    }

                    if isSaved, let setlist {
                        #if !os(tvOS)
                        ShareLink(item: store.exportText(for: setlist)) {
                            Label("Share or Export Setlist", systemImage: "square.and.arrow.up")
                        }
                        #else
                        Label("Identified setlist saved to Setlists", systemImage: "checkmark.circle.fill")
                        #endif
                    }
                } header: {
                    Text("Save this result")
                } footer: {
                    Text("Saves only the identified setlist in Setlists on your synced devices. It does not duplicate or download the original mix.")
                }

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
            .navigationTitle("Setlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var setlist: GeneratedSetlist? { store.setlist(for: track.id) }
    private var segments: [SetlistSegment] {
        (setlist?.segments ?? []).filter { !$0.isDeleted }.sorted { $0.startSeconds < $1.startSeconds }
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
    private var scanFileURL: URL? { discoveredLocalFileURL ?? localFileURL }

    @ViewBuilder
    private var scanStatus: some View {
        if isScanning {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text("Scanning downloaded audio")
                        Text(scanProgressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                }
            }
        } else if isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text(downloadHeadline)
                        Text(downloadDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let fraction = downloadFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
                Button(role: .destructive) {
                    shouldScanAfterDownload = false
                    downloads.cancel(trackId: track.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }
        } else if case .paused = downloadState {
            VStack(alignment: .leading, spacing: 6) {
                Label("Download paused", systemImage: "pause.circle")
                Button {
                    shouldScanAfterDownload = true
                    downloads.resume(trackId: track.id)
                } label: {
                    Label("Resume Download and Scan", systemImage: "arrow.down.circle")
                }
            }
        } else if case .failed(let reason) = downloadState {
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button(action: beginDownloadAndScan) {
                    Label("Retry Download and Scan", systemImage: "arrow.clockwise")
                }
            }
        } else if let error = store.scanErrors[track.id] {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if scanFileURL != nil {
                    Button(action: beginAudioScan) {
                        Label("Retry Audio Scan", systemImage: "arrow.clockwise")
                    }
                }
            }
        } else {
            LabeledContent("Coverage", value: scanCounts)

            if scanFileURL != nil {
                Button(action: beginAudioScan) {
                    Label(
                        (setlist?.completedProbeCount ?? 0) > 0 ? "Rescan Unmatched Spots" : "Scan Downloaded Audio",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                }
            } else {
                Button(action: beginDownloadAndScan) {
                    Label("Download Mix and Start Scan", systemImage: "arrow.down.circle")
                }
            }

            if let downloadScanMessage {
                Text(downloadScanMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
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
        case .queued: return "Waiting to download"
        case .downloading: return "Downloading mix for audio scan"
        default: return "Preparing audio scan"
        }
    }

    private var downloadDetail: String {
        guard let fraction = downloadFraction else { return "The scan will start automatically when it finishes." }
        return "\(Int((fraction * 100).rounded()))% · Scan starts automatically after download"
    }

    private var scanProgressLabel: String {
        guard let progress else { return scanCounts }
        let position = progress.positionSeconds.map { " · checking \(SetlistViewFormat.clock($0))" } ?? ""
        return "\(progress.completed) of \(progress.total) spots\(position) · \(segments.count) tracks found"
    }

    private func beginDownloadAndScan() {
        downloadScanMessage = nil
        if let refusal = downloads.downloadRefusalReason(for: track) {
            downloadScanMessage = refusal.errorDescription ?? "This mix cannot be downloaded."
            return
        }
        shouldScanAfterDownload = true
        onDownload()
    }

    private func beginAudioScan() {
        guard let fileURL = scanFileURL else {
            downloadScanMessage = "The downloaded audio could not be opened."
            return
        }
        shouldScanAfterDownload = false
        Task {
            await store.retryUnknowns(track: track, localFileURL: fileURL, comments: comments)
        }
    }

    private func handleDownloadState(_ state: DownloadState) {
        switch state {
        case .queued, .downloading:
            // If this sheet is open while the mix is downloading, its scan UI
            // promises that analysis follows. Preserve that promise even when
            // the transfer started elsewhere in the app.
            shouldScanAfterDownload = true
        case .downloaded:
            if discoveredLocalFileURL == nil {
                discoveredLocalFileURL = downloads.localFileURL(for: track)
            }
            if shouldScanAfterDownload { beginAudioScan() }
        case .notDownloaded, .paused, .failed:
            break
        }
    }

    private var scanCounts: String {
        guard let setlist else { return "Not scanned yet" }
        let matches = setlist.recognizedProbeCount
        let probes = setlist.completedProbeCount
        if probes == 0 {
            return segments.isEmpty
                ? "Audio not scanned"
                : "\(segments.count) listed tracks · Audio not scanned"
        }
        return "\(segments.count) tracks · \(matches)/\(probes) spots matched"
    }

    private func segmentRow(_ segment: SetlistSegment) -> some View {
        HStack(spacing: 12) {
            Button { onSeek(segment.startSeconds) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(segment.displayLabel)
                        .font(.body.weight(segment.startSeconds <= currentPosition ? .semibold : .regular))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(SetlistViewFormat.clock(segment.startSeconds))
                            .monospacedDigit()
                        Text(segment.source.displayName)
                        if segment.soundCloudTrackId != nil {
                            Label("Linked", systemImage: "link")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            segmentMenu(for: segment)
        }
    }

    private func segmentMenu(for segment: SetlistSegment) -> some View {
        Menu {
            Button { editingSegment = segment } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button { searchingSegment = segment } label: {
                Label("Search SoundCloud", systemImage: "magnifyingglass")
            }
            Button(role: .destructive) {
                store.remove(segmentId: segment.id, trackId: track.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .accessibilityLabel("Actions for \(segment.displayLabel)")
    }

    // MARK: - tvOS

    #if os(tvOS)
    @Namespace private var setlistGlass
    @FocusState private var libraryLinkFocused: Bool

    private var style: SCContentStyle { .tv }

    private var tvOSContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: style.spaceSection) {
                    tvOSHeader
                    tvOSIntelligenceCard
                    tvOSSetListCard

                    if isSaved, setlist != nil {
                        Label("Identified setlist saved to Setlists", systemImage: "checkmark.circle.fill")
                            .font(style.fontBody)
                            .foregroundStyle(style.success)
                    }

                    if !store.savedSetlists.isEmpty {
                        tvOSLibraryLink
                    }
                }
                .padding(.horizontal, style.spaceGutter * 2)
                .padding(.vertical, style.spaceSection)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.scBackground.ignoresSafeArea())
        }
    }

    private var tvOSHeader: some View {
        HStack(alignment: .top, spacing: style.spaceRoomy) {
            VStack(alignment: .leading, spacing: style.spaceTight) {
                Eyebrow(text: "Setlist")
                Text(track.title)
                    .font(style.fontTitle)
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(2)
                Text(track.user.displayName)
                    .font(style.fontHeadline)
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: style.spaceBase)

            GlassEffectContainer {
                HStack(spacing: style.spaceSnug) {
                    Button {
                        store.setSaved(!isSaved, trackId: track.id)
                    } label: {
                        GlassChip(
                            icon: isSaved ? "bookmark.fill" : "bookmark",
                            text: isSaved ? "Remove Saved Setlist" : "Save Setlist",
                            id: "save-toggle",
                            namespace: setlistGlass,
                            interactive: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button { dismiss() } label: {
                        GlassChip(
                            icon: "xmark",
                            text: "Done",
                            id: "done",
                            namespace: setlistGlass,
                            interactive: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var tvOSIntelligenceCard: some View {
        VStack(alignment: .leading, spacing: style.spaceBase) {
            Eyebrow(text: "Set Intelligence")

            if let trackAnalysis, !trackAnalysis.isEmpty {
                trackAnalysis.badgeRow(style: style)
            }

            tvOSScanStatus

            if let currentSegment {
                Button { onSeek(currentSegment.startSeconds) } label: {
                    HStack(spacing: style.spaceSnug) {
                        Label("Now in this set", systemImage: "opticaldisc.fill")
                            .font(style.fontBodyEmphasis)
                            .foregroundStyle(style.textPrimary)
                        Spacer(minLength: style.spaceSnug)
                        Text(currentSegment.displayLabel)
                            .font(style.fontBody)
                            .foregroundStyle(style.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, style.spaceSnug)
                    .padding(.vertical, style.spaceTight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous))
                }
                .buttonStyle(SetlistTVRowButtonStyle())
            }

            GlassEffectContainer {
                HStack(spacing: style.spaceSnug) {
                    if let localFileURL {
                        Button {
                            Task {
                                await store.retryUnknowns(
                                    track: track,
                                    localFileURL: localFileURL,
                                    comments: comments
                                )
                            }
                        } label: {
                            GlassChip(
                                icon: "arrow.clockwise",
                                text: "Retry Unknown Spots",
                                id: "retry-unknowns",
                                namespace: setlistGlass,
                                interactive: true
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isScanning)
                    } else {
                        Button(action: onDownload) {
                            GlassChip(
                                icon: "arrow.down.circle",
                                text: "Download Audio for Deep Scan",
                                id: "download-scan",
                                namespace: setlistGlass,
                                interactive: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("Uploader timestamps and the useful listener IDs get combined with native ShazamKit matches. Every position we check is saved and synced, so a long set picks up where you left it on another device.")
                .font(style.fontCaption)
                .foregroundStyle(style.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(style.spaceBase)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .focusSection()
    }

    @ViewBuilder
    private var tvOSScanStatus: some View {
        if isScanning {
            HStack(spacing: style.spaceSnug) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(style.textPrimary)
                VStack(alignment: .leading, spacing: style.spaceHair) {
                    Text("Scanning in the background")
                        .font(style.fontBodyEmphasis)
                        .foregroundStyle(style.textPrimary)
                    Text(scanCounts)
                        .font(style.fontCaption)
                        .foregroundStyle(style.textSecondary)
                }
            }
        } else if let error = store.scanErrors[track.id] {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(style.fontBody)
                .foregroundStyle(style.warning)
        } else {
            HStack {
                Text("Coverage")
                    .font(style.fontBody)
                    .foregroundStyle(style.textSecondary)
                Spacer()
                Text(scanCounts)
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(style.textPrimary)
            }
        }
    }

    private var tvOSSetListCard: some View {
        VStack(alignment: .leading, spacing: style.spaceBase) {
            Eyebrow(text: "Setlist")

            if segments.isEmpty {
                VStack(alignment: .leading, spacing: style.spaceTight) {
                    Label("Nothing Identified Yet", systemImage: "waveform.badge.magnifyingglass")
                        .font(style.fontBodyEmphasis)
                        .foregroundStyle(style.textPrimary)
                    Text("The deep scan runs on the Mac, so leave that app open. Or retry the audio you already have, here.")
                        .font(style.fontCaption)
                        .foregroundStyle(style.textSecondary)
                }
            } else {
                VStack(spacing: style.spaceTight) {
                    ForEach(segments) { segment in
                        tvOSSegmentRow(segment)
                    }
                }
            }
        }
        .padding(style.spaceBase)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .focusSection()
    }

    private func tvOSSegmentRow(_ segment: SetlistSegment) -> some View {
        HStack(spacing: style.spaceSnug) {
            Button { onSeek(segment.startSeconds) } label: {
                HStack(spacing: style.spaceSnug) {
                    Text(SetlistViewFormat.clock(segment.startSeconds))
                        .font(style.fontCaptionEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(style.accent)

                    VStack(alignment: .leading, spacing: style.spaceHair) {
                        Text(segment.displayLabel)
                            .font(style.fontBody.weight(segment.startSeconds <= currentPosition ? .semibold : .regular))
                            .foregroundStyle(style.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: style.spaceTight) {
                            Text(segment.source.displayName)
                            if segment.soundCloudTrackId != nil {
                                Label("Linked", systemImage: "link")
                            }
                        }
                        .font(style.fontCaption)
                        .foregroundStyle(style.textSecondary)
                    }

                    Spacer(minLength: style.spaceSnug)
                }
                .padding(.horizontal, style.spaceSnug)
                .padding(.vertical, style.spaceTight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .contentShape(RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous))
            }
            .buttonStyle(SetlistTVRowButtonStyle())

            segmentMenu(for: segment)
                .font(.system(size: 28, weight: .semibold))
        }
    }

    private var tvOSLibraryLink: some View {
        NavigationLink {
            SavedSetlistsLibraryView()
        } label: {
            HStack(spacing: style.spaceSnug) {
                Label("Saved Setlists", systemImage: "bookmark.fill")
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(style.textPrimary)
                Spacer(minLength: style.spaceSnug)
                Text("\(store.savedSetlists.count)")
                    .font(style.fontBody)
                    .foregroundStyle(style.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(style.textTertiary)
            }
            .padding(.horizontal, style.spaceSnug)
            .padding(.vertical, style.spaceTight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous))
        }
        .focused($libraryLinkFocused)
        .modifier(SetlistTVFocus(focused: libraryLinkFocused))
    }
    #endif
}

#if os(tvOS)

private struct SetlistTVFocus: ViewModifier {
    let focused: Bool
    var cornerRadius: CGFloat = Corner.control

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(focused ? 1.06 : 1.0)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.scAccent.opacity(focused ? 0.90 : 0), lineWidth: 4)
            }
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 24, y: 12)
            .animation(reduceMotion ? nil : Motion.focus, value: focused)
            .focusEffectDisabled()
    }
}

private struct SetlistTVRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Corner.control

    func makeBody(configuration: Configuration) -> some View {
        FocusedLabel(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct FocusedLabel: View {
        let configuration: Configuration
        let cornerRadius: CGFloat

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.85 : 1)
                .modifier(SetlistTVFocus(focused: isFocused, cornerRadius: cornerRadius))
        }
    }
}

#endif

private struct SavedSetlistsLibraryView: View {
    @ObservedObject private var store = SetlistIntelligenceStore.shared

    var body: some View {
        List(store.savedSetlists, id: \.trackId) { setlist in
            NavigationLink {
                SavedSetlistDetailView(setlist: setlist)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(setlist.trackTitle)
                    Text("\(setlist.segments.filter { !$0.isDeleted }.count) identified tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Saved Setlists")
    }
}

private struct SavedSetlistDetailView: View {
    let setlist: GeneratedSetlist
    @ObservedObject private var store = SetlistIntelligenceStore.shared

    var body: some View {
        List {
            ForEach(setlist.segments.filter { !$0.isDeleted }.sorted { $0.startSeconds < $1.startSeconds }) { segment in
                LabeledContent(
                    SetlistViewFormat.clock(segment.startSeconds),
                    value: segment.displayLabel
                )
            }
            #if !os(tvOS)
            ShareLink(item: store.exportText(for: setlist)) {
                Label("Share or Export", systemImage: "square.and.arrow.up")
            }
            #endif
        }
        .navigationTitle(setlist.trackTitle)
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
                TextField("Artist", text: Binding(
                    get: { draft.artist ?? "" },
                    set: { draft.artist = $0.isEmpty ? nil : $0 }
                ))
                TextField("Track title", text: $draft.title)
                TextField("Version / edit", text: Binding(
                    get: { draft.version ?? "" },
                    set: { draft.version = $0.isEmpty ? nil : $0 }
                ))
                LabeledContent("Starts at") {
                    TextField("Seconds", value: $draft.startSeconds, format: .number)
                        .multilineTextAlignment(.trailing)
                }
            }
            .navigationTitle("Edit Set Entry")
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

    init(segment: SetlistSegment, onLink: @escaping (Track) -> Void, onPlay: @escaping (Track) -> Void) {
        self.segment = segment
        self.onLink = onLink
        self.onPlay = onPlay
        _query = State(initialValue: segment.searchQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Artist and track", text: $query)
                            .onSubmit { search() }
                        Button("Search") { search() }
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    }
                }

                if isSearching {
                    ProgressView("Searching SoundCloud…")
                } else if let errorMessage {
                    ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section("Results") {
                        ForEach(results) { result in
                            HStack(spacing: 12) {
                                AsyncImage(url: result.artworkURL) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "music.note")
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(.quaternary)
                                    }
                                }
                                .frame(width: 46, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 7))

                                VStack(alignment: .leading) {
                                    Text(result.title).lineLimit(1)
                                    Text(result.user.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button { onPlay(result) } label: {
                                    Image(systemName: "play.fill")
                                }
                                .accessibilityLabel("Play this result")
                                Button("Link") {
                                    onLink(result)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search SoundCloud")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await performSearch() }
    }

    private func search() {
        Task { await performSearch() }
    }

    @MainActor
    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await SoundCloudAPI.shared.searchTracks(query: trimmed, limit: 20).collection
        } catch {
            results = []
            errorMessage = error.localizedDescription
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
