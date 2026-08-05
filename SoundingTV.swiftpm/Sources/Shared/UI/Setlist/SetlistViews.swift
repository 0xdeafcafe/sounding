import Foundation
import SwiftUI

struct OnDecksIndicator: View {
    let identity: SetlistSegment?
    let isScanning: Bool
    let action: () -> Void

    var body: some View {
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
        .accessibilityHint("Opens the set list we found")
        #if os(iOS)
        .scGlassCapsule()
        #elseif os(tvOS)
        .liquidGlass(in: Capsule(), interactive: true)
        #endif
    }

    private var label: String {
        if let identity { return "On decks: \(identity.displayLabel)" }
        return isScanning ? "On decks: working this one out…" : "On decks: not identified"
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
    @State private var editingSegment: SetlistSegment?
    @State private var searchingSegment: SetlistSegment?
    #if !SOUNDING_SHARE_EXTENSION
    @State private var trackAnalysis: TrackAnalysisSummary?
    #endif

    var body: some View {
        content
            .task(id: "\(track.id)#\(comments.count)") {
                store.seed(track: track, comments: comments)
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
                            LabeledContent("On decks", value: currentSegment.displayLabel)
                        }
                    }
                } header: {
                    Text("Set Intelligence")
                } footer: {
                    Text("Uploader timestamps and the useful listener IDs get combined with native ShazamKit matches. Every position we check is saved and synced, so a long set picks up where you left it on another device.")
                }

                Section("Set list") {
                    if segments.isEmpty {
                        ContentUnavailableView(
                            "Nothing Identified Yet",
                            systemImage: "waveform.badge.magnifyingglass",
                            description: Text("The deep scan runs on the Mac, so leave that app open. Or retry the audio you already have, here.")
                        )
                    } else {
                        ForEach(segments) { segment in
                            segmentRow(segment)
                        }
                    }
                }

                if isSaved, let setlist {
                    Section("Saved Set List") {
                        #if os(tvOS)
                        Label("Saved to your synced library", systemImage: "checkmark.circle.fill")
                        #else
                        ShareLink(item: store.exportText(for: setlist)) {
                            Label("Share or Export Track List", systemImage: "square.and.arrow.up")
                        }
                        #endif
                    }
                }

                if !store.savedSetlists.isEmpty {
                    Section {
                        NavigationLink {
                            SavedSetlistsLibraryView()
                        } label: {
                            LabeledContent("Saved Set Lists", value: "\(store.savedSetlists.count)")
                        }
                    }
                }
            }
            .navigationTitle(track.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaved ? "Remove from Library" : "Save to Library") {
                        store.setSaved(!isSaved, trackId: track.id)
                    }
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
    private var isScanning: Bool { store.scanningTrackIds.contains(track.id) }

    @ViewBuilder
    private var scanStatus: some View {
        if isScanning {
            HStack {
                ProgressView()
                VStack(alignment: .leading) {
                    Text("Scanning in the background")
                    Text(scanCounts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let error = store.scanErrors[track.id] {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            LabeledContent("Coverage", value: scanCounts)
        }

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
                Label("Retry Unknown Spots", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning)
        } else {
            Button(action: onDownload) {
                Label("Download Audio for Deep Scan", systemImage: "arrow.down.circle")
            }
        }
    }

    private var scanCounts: String {
        guard let setlist else { return "Not scanned yet" }
        let matches = setlist.recognizedProbeCount
        let probes = setlist.completedProbeCount
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
                        Label("Saved to your synced library", systemImage: "checkmark.circle.fill")
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
                Eyebrow(text: "Set List")
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
                            text: isSaved ? "Remove from Library" : "Save to Library",
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
                        Label("On decks", systemImage: "opticaldisc.fill")
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
            Eyebrow(text: "Set List")

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
                Label("Saved Set Lists", systemImage: "bookmark.fill")
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
        .navigationTitle("Saved Set Lists")
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
