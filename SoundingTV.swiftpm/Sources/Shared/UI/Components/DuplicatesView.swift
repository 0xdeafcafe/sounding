import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DuplicatesView: View {
    @ObservedObject private var store = LibraryDuplicates.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var pendingUnlike: Track?
    @State private var unlikeFailed = false

    var body: some View {
        content
            .navigationTitle("Duplicates")
            .task { store.checkNow() }
            .confirmationDialog(
                pendingUnlike.map { "Unlike “\($0.title)” on SoundCloud?" } ?? "",
                isPresented: Binding(get: { pendingUnlike != nil }, set: { if !$0 { pendingUnlike = nil } }),
                titleVisibility: .visible,
                presenting: pendingUnlike
            ) { track in
                Button("Unlike", role: .destructive) {
                    Task {
                        let unliked = await store.unlike(track)
                        unlikeFailed = !unliked
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It leaves your likes on SoundCloud and on every device.")
            }
            .alert("Couldn’t Unlike", isPresented: $unlikeFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
    }

    @ViewBuilder
    private var content: some View {
        let hidden = store.hiddenTracks
        if store.groups.isEmpty && hidden.isEmpty {
            if store.isChecking || !store.hasChecked {
                ContentUnavailableView {
                    Label {
                        Text("Checking for Duplicates")
                    } icon: {
                        ProgressView()
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Duplicates",
                    systemImage: "checkmark.circle",
                    description: Text("Tracks that are in your library more than once appear here.")
                )
            }
        } else {
            List {
                ForEach(store.groups) { group in
                    Section {
                        ForEach(group.members) { member in
                            DuplicateTrackRow(
                                candidate: member,
                                isSuggested: member.id == group.keeperID,
                                keep: { store.keep(member.id, in: group) },
                                unlike: unlikeAction(for: member)
                            )
                        }
                        groupActions(group)
                    } header: {
                        DuplicateGroupHeader(group: group)
                    }
                }
                if !hidden.isEmpty {
                    Section {
                        ForEach(hidden) { track in
                            HiddenDuplicateRow(track: track) { store.unhide(track.id) }
                        }
                    } header: {
                        Text("Hidden")
                    } footer: {
                        Text("Hidden tracks stay in their folders and in your SoundCloud likes.")
                    }
                }
            }
            .duplicatesListStyle()
        }
    }

    @ViewBuilder
    private func groupActions(_ group: DuplicateGroup) -> some View {
        #if os(tvOS)
        Button("Hide Others") { store.hideOthers(in: group) }
        Button("Not Duplicates") { store.notDuplicates(group) }
        #else
        HStack(spacing: 10) {
            Button("Hide Others") { store.hideOthers(in: group) }
                .buttonStyle(.borderedProminent)
            Button("Not Duplicates") { store.notDuplicates(group) }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        #endif
    }

    private func unlikeAction(for member: DuplicateCandidate) -> (() -> Void)? {
        guard !member.source.isLocal, credentials.showsSoundCloudLibrary, let track = store.track(member.id) else { return nil }
        return { pendingUnlike = track }
    }
}

private struct DuplicateGroupHeader: View {
    let group: DuplicateGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.keeper.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(confidence)
        }
    }

    private var confidence: String {
        switch group.confidence {
        case .sameFile: "Same File"
        case .likely: "Likely"
        case .possible: "Possible"
        }
    }
}

private struct DuplicateTrackRow: View {
    let candidate: DuplicateCandidate
    let isSuggested: Bool
    let keep: () -> Void
    let unlike: (() -> Void)?

    var body: some View {
        #if os(tvOS)
        Button(action: keep) {
            HStack(spacing: 24) {
                DuplicateTrackInfo(candidate: candidate, isSuggested: isSuggested)
                Spacer(minLength: 0)
                Text("Keep")
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu { unlikeItem }
        #else
        HStack(spacing: 12) {
            DuplicateTrackInfo(candidate: candidate, isSuggested: isSuggested)
            Spacer(minLength: 8)
            Button("Keep", action: keep)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Keep \(candidate.title)")
        }
        .contextMenu { unlikeItem }
        #endif
    }

    @ViewBuilder
    private var unlikeItem: some View {
        if let unlike {
            Button("Unlike on SoundCloud…", systemImage: "heart.slash", role: .destructive, action: unlike)
        }
    }
}

private struct DuplicateTrackInfo: View {
    let candidate: DuplicateCandidate
    let isSuggested: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(candidate.title)
                    .lineLimit(1)
                if isSuggested {
                    Text("Suggested")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            Text(candidate.artist)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: DuplicateFormat.symbol(candidate.source))
                    .accessibilityHidden(true)
                Text(DuplicateFormat.details(candidate))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HiddenDuplicateRow: View {
    let track: Track
    let show: () -> Void

    var body: some View {
        #if os(tvOS)
        Button(action: show) {
            HStack(spacing: 24) {
                label
                Spacer(minLength: 0)
                Text("Show")
                    .foregroundStyle(.secondary)
            }
        }
        #else
        HStack(spacing: 12) {
            label
            Spacer(minLength: 8)
            Button("Show", action: show)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Show \(track.title) in Library")
        }
        #endif
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .lineLimit(1)
            Text(track.user.displayName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

enum DuplicateFormat {
    static func symbol(_ source: DuplicateCandidate.Source) -> String {
        switch source {
        case .localFile, .localLossless: "folder"
        case .downloaded: "arrow.down.circle"
        case .stream, .preview: "cloud"
        }
    }

    static func sourceLabel(_ source: DuplicateCandidate.Source) -> String {
        switch source {
        case .localFile, .localLossless: "Your Files"
        case .downloaded: "Downloaded"
        case .stream: "SoundCloud"
        case .preview: "SoundCloud Preview"
        }
    }

    static func details(_ candidate: DuplicateCandidate) -> String {
        var parts = [sourceLabel(candidate.source)]
        if let format = candidate.format {
            parts.append(format)
        } else if candidate.bitrate > 0 {
            parts.append("\(candidate.bitrate) kbps")
        }
        if candidate.duration > 0 {
            let seconds = Int(candidate.duration.rounded())
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        if let bpm = candidate.bpm, bpm > 0 { parts.append("\(Int(bpm.rounded())) BPM") }
        if let key = candidate.key { parts.append(key.label) }
        if candidate.hasCues { parts.append("Cues") }
        return parts.joined(separator: " · ")
    }

    static func summary(_ count: Int) -> String {
        count == 1 ? "1 possible duplicate" : "\(count) possible duplicates"
    }
}

struct DuplicatesSummaryLabel: View {
    let count: Int

    var body: some View {
        Label {
            Text(DuplicateFormat.summary(count))
        } icon: {
            Image(systemName: "square.on.square")
                .foregroundStyle(.tint)
        }
    }
}

struct DuplicatesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DuplicatesView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(Color.scAccent)
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 460, idealHeight: 640)
        #endif
    }
}

@MainActor
final class DuplicatesPresenter: ObservableObject {
    static let shared = DuplicatesPresenter()

    @Published var isPresented = false

    private var pending: Task<Void, Never>?

    func present() {
        LibraryDuplicates.shared.start()
        guard !isPresented else { return }
        #if os(macOS)
        pending?.cancel()
        pending = Task { [weak self] in
            while Self.mainWindowHasSheet {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard let self, !self.isPresented else { return }
            self.isPresented = true
        }
        #else
        isPresented = true
        #endif
    }

    #if os(macOS)
    private static var mainWindowHasSheet: Bool {
        NSApp.windows.contains { window in
            window.identifier?.rawValue.hasPrefix("main") == true && window.attachedSheet != nil
        }
    }
    #endif
}

struct DuplicatesPresentation: ViewModifier {
    @ObservedObject private var presenter = DuplicatesPresenter.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presenter.isPresented) { DuplicatesSheet() }
    }
}

struct DuplicateImportPrompt: ViewModifier {
    let folderIDs: Set<String>

    @ObservedObject private var store = LibraryDuplicates.shared
    @State private var reviewing = false

    func body(content: Content) -> some View {
        content
            .background {
                Color.clear
                    .alert(
                        notice?.title ?? "",
                        isPresented: Binding(get: { notice != nil }, set: { if !$0 { store.importNotice = nil } }),
                        presenting: notice
                    ) { _ in
                        Button("Review") {
                            store.importNotice = nil
                            review()
                        }
                        Button("Not Now", role: .cancel) { store.importNotice = nil }
                    } message: { notice in
                        Text(notice.message)
                    }
            }
            #if !os(macOS)
            .sheet(isPresented: $reviewing) { DuplicatesSheet() }
            #endif
    }

    private func review() {
        #if os(macOS)
        DuplicatesPresenter.shared.present()
        #else
        reviewing = true
        #endif
    }

    private var notice: DuplicateImportNotice? {
        guard let notice = store.importNotice, folderIDs.contains(notice.folderID) else { return nil }
        return notice
    }
}

private struct DuplicatesListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listStyle(.insetGrouped)
        #elseif os(macOS)
        content.listStyle(.inset)
        #else
        content
        #endif
    }
}

extension View {
    func duplicatesPresentation() -> some View {
        modifier(DuplicatesPresentation())
    }

    func duplicateImportPrompt(folderIDs: Set<String>) -> some View {
        modifier(DuplicateImportPrompt(folderIDs: folderIDs))
    }

    fileprivate func duplicatesListStyle() -> some View {
        modifier(DuplicatesListStyle())
    }
}
