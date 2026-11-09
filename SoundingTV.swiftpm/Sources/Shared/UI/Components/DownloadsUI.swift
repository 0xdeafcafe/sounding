import SwiftUI

// MARK: - Request prompts

@MainActor
final class DownloadRequestPrompter: ObservableObject {
    struct Confirmation: Identifiable {
        let id = UUID()
        let estimate: DownloadSizeEstimate
        let confirm: @MainActor () async -> DownloadRequestResult
    }

    @Published var confirmation: Confirmation?
    @Published var refusal: DownloadError?

    private let presentsPrompts: Bool

    init(presentsPrompts: Bool = true) {
        self.presentsPrompts = presentsPrompts
    }

    static let fallback = DownloadRequestPrompter(presentsPrompts: false)

    func request(_ perform: @escaping @MainActor (_ confirmed: Bool) async -> DownloadRequestResult) {
        Task { await handle(await perform(false), retry: perform) }
    }

    func confirmPending() {
        guard let pending = confirmation else { return }
        confirmation = nil
        Task { await handle(await pending.confirm(), retry: nil) }
    }

    private func handle(
        _ result: DownloadRequestResult,
        retry: (@MainActor (_ confirmed: Bool) async -> DownloadRequestResult)?
    ) async {
        switch result {
        case .queued:
            break
        case .needsConfirmation(let estimate):
            guard let retry else { return }
            if presentsPrompts {
                confirmation = Confirmation(estimate: estimate) { await retry(true) }
            } else {
                await handle(await retry(true), retry: nil)
            }
        case .refused(let error):
            refusal = error
        }
    }
}

private struct DownloadRequestPrompterKey: EnvironmentKey {
    static var defaultValue: DownloadRequestPrompter {
        MainActor.assumeIsolated { DownloadRequestPrompter.fallback }
    }
}

extension EnvironmentValues {
    var downloadPrompter: DownloadRequestPrompter {
        get { self[DownloadRequestPrompterKey.self] }
        set { self[DownloadRequestPrompterKey.self] = newValue }
    }
}

typealias DownloadedTrackPlayer = @MainActor (_ track: Track, _ context: [Track]) -> Void

private struct DownloadedTrackPlayerKey: EnvironmentKey {
    static var defaultValue: DownloadedTrackPlayer {
        { track, context in Task { await PlayerService.shared.play(track, in: context) } }
    }
}

extension EnvironmentValues {
    var downloadedTrackPlayer: DownloadedTrackPlayer {
        get { self[DownloadedTrackPlayerKey.self] }
        set { self[DownloadedTrackPlayerKey.self] = newValue }
    }
}

extension DownloadSizeEstimate {
    var sizeLabel: String { DownloadsFormat.bytes(bytes) }

    var confirmationTitle: String {
        switch confirmationReason {
        case .cellular: return "Download over cellular?"
        case .large, .none: return "Download \(sizeLabel)?"
        }
    }

    var confirmationMessage: String {
        let tracks = DownloadsFormat.trackCount(trackCount)
        switch confirmationReason {
        case .cellular: return "\(tracks), \(sizeLabel)."
        case .large, .none: return tracks + "."
        }
    }
}

private struct DownloadRequestPromptsHost: ViewModifier {
    @StateObject private var prompter = DownloadRequestPrompter()

    func body(content: Content) -> some View {
        content.downloadRequestPrompts(prompter)
    }
}

private struct DownloadRequestPromptsModifier: ViewModifier {
    @ObservedObject var prompter: DownloadRequestPrompter

    func body(content: Content) -> some View {
        content
            .environment(\.downloadPrompter, prompter)
            .confirmationDialog(
                prompter.confirmation?.estimate.confirmationTitle ?? "",
                isPresented: Binding(
                    get: { prompter.confirmation != nil },
                    set: { if !$0 { prompter.confirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: prompter.confirmation
            ) { _ in
                Button("Download") { prompter.confirmPending() }
                Button("Cancel", role: .cancel) { prompter.confirmation = nil }
            } message: { confirmation in
                Text(confirmation.estimate.confirmationMessage)
            }
            .alert(
                "Can't Download",
                isPresented: Binding(
                    get: { prompter.refusal != nil },
                    set: { if !$0 { prompter.refusal = nil } }
                ),
                presenting: prompter.refusal
            ) { error in
                if case .entitlement(let denial) = error, denial.offersSubscription {
                    SoundCloudSubscribeButton()
                }
                Button("OK", role: .cancel) { prompter.refusal = nil }
            } message: { error in
                Text(error.errorDescription ?? "This track can't be downloaded.")
            }
    }
}

enum SoundCloudTrackMark: Equatable, Sendable {
    case goPlus
    case preview

    var title: String {
        switch self {
        case .goPlus: "Go+"
        case .preview: "Preview"
        }
    }

    var spokenLabel: String {
        switch self {
        case .goPlus: "SoundCloud Go+"
        case .preview: "Preview"
        }
    }

    @MainActor
    static func of(_ track: Track, showsPreview: Bool) -> SoundCloudTrackMark? {
        guard !track.isLocal else { return nil }
        if showsPreview, SubscriptionService.shared.playsAsPreview(track) { return .preview }
        return track.requiresGoPlus ? .goPlus : nil
    }
}

struct SoundCloudTrackBadge: View {
    let mark: SoundCloudTrackMark?
    var color: Color? = nil

    init(mark: SoundCloudTrackMark?, color: Color? = nil) {
        self.mark = mark
        self.color = color
    }

    init(track: Track, showsPreview: Bool = true) {
        mark = SoundCloudTrackMark.of(track, showsPreview: showsPreview)
    }

    private var style: AnyShapeStyle {
        color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }

    var body: some View {
        if let mark {
            Text(mark.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(style)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(style, lineWidth: 1)
                }
                .fixedSize()
                .accessibilityLabel(mark.spokenLabel)
        }
    }
}

struct SoundCloudPreviewNowPlayingLine: View {
    @ObservedObject private var player = PlayerService.shared
    var trackID: String? = nil

    var body: some View {
        if let track = player.currentTrack, trackID == nil || trackID == track.id {
            if player.isPlayingSoundCloudPreview {
                let seconds = Int(player.duration > 0 ? player.duration : track.previewDuration)
                Text(String(format: "Preview \u{00B7} %d:%02d", seconds / 60, seconds % 60))
                    .lineLimit(1)
            } else if track.requiresGoPlus {
                SoundCloudTrackBadge(mark: .goPlus)
            }
        }
    }
}

struct SoundCloudSubscribeButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if !os(tvOS)
        Button("Subscribe in SoundCloud") { openURL(SoundCloudEntitlements.subscribeURL) }
        #endif
    }
}

private struct SoundCloudEntitlementAlert: ViewModifier {
    @ObservedObject private var player = PlayerService.shared

    func body(content: Content) -> some View {
        content.alert(
            player.entitlementPrompt?.alertTitle ?? "",
            isPresented: Binding(
                get: { player.entitlementPrompt != nil },
                set: { if !$0 { player.entitlementPrompt = nil } }
            ),
            presenting: player.entitlementPrompt
        ) { denial in
            if denial.offersSubscription { SoundCloudSubscribeButton() }
            Button("OK", role: .cancel) { player.entitlementPrompt = nil }
        } message: { denial in
            Text(denial.errorDescription ?? "")
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_FIXTURE_ENTITLEMENT_PROMPT"] == "1" else { return }
            try? await Task.sleep(for: .seconds(1))
            player.entitlementPrompt = SubscriptionService.shared.denial(for: .playback)
        }
        #endif
    }
}

extension SoundCloudEntitlementError {
    var alertTitle: String {
        switch self {
        case .signedOut: return "Not Signed In"
        case .planUnconfirmed: return "Can\u{2019}t Play"
        case .ownMusicOnly: return "Can\u{2019}t Export Track"
        case .needsGo, .needsGoPlus: return "Subscription Needed"
        case .previewOnly: return "Preview Ended"
        }
    }
}

extension View {
    func soundCloudEntitlementAlert() -> some View {
        modifier(SoundCloudEntitlementAlert())
    }
}

extension View {
    func downloadRequestPrompts() -> some View {
        modifier(DownloadRequestPromptsHost())
    }

    func downloadRequestPrompts(_ prompter: DownloadRequestPrompter) -> some View {
        modifier(DownloadRequestPromptsModifier(prompter: prompter))
    }
}

// MARK: - Formatting

enum DownloadsFormat {
    static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func trackCount(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count) tracks"
    }

    static func minimumStorage(_ bytes: Int64) -> String {
        bytes == 0 ? "None" : Self.bytes(bytes)
    }

    static func collectionDetail(_ item: DownloadedCollectionItem, waitingReason: String?) -> String {
        switch item.state {
        case .downloaded:
            return "\(trackCount(item.trackCount)) · \(bytes(item.bytes))"
        case .downloading(let completed, let total):
            return "Downloading \(completed) of \(total)"
        case .waiting(let completed, let total):
            return "\(waitingReason ?? "Waiting") · \(completed) of \(total)"
        case .failed(let completed, let total):
            return "Download failed · \(completed) of \(total)"
        }
    }

    static func trackDetail(_ item: DownloadedTrackItem, waitingReason: String?) -> String {
        switch item.state {
        case .downloaded: return bytes(item.bytes)
        case .downloading: return "Downloading"
        case .queued: return waitingReason ?? "Waiting"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .notDownloaded: return ""
        }
    }

    static var deviceCapacityBytes: Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }
}

extension DownloadManager {
    var downloadedSummary: String {
        let count = entries.values.filter(\.isDownloaded).count
        return count == 0 ? "None" : DownloadsFormat.trackCount(count)
    }
}

@MainActor
final class CacheUsageModel: ObservableObject {
    @Published private(set) var usage: CacheUsage?
    @Published private(set) var isClearing = false

    func refresh() async {
        usage = await CacheUsage.measure()
    }

    func clearArtwork() {
        clear { await CacheUsage.clearArtwork() }
    }

    func clearCaches() {
        clear { await CacheUsage.clearCaches() }
    }

    private func clear(_ work: @escaping @Sendable @MainActor () async -> Void) {
        isClearing = true
        Task {
            await work()
            await refresh()
            isClearing = false
        }
    }
}

// MARK: - Downloaded Music

struct DownloadedMusicView: View {
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        let library = downloads.library
        Group {
            if library.isEmpty {
                ContentUnavailableView {
                    SoundingArtEmptyLabel(title: "No Downloads", identity: "empty.downloads", motif: .jack)
                } description: {
                    Text("Music you download appears here.")
                }
                .remoteFocusTarget()
            } else {
                List {
                    if !library.playlists.isEmpty {
                        Section("Playlists") {
                            ForEach(library.playlists) { item in
                                DownloadedCollectionRow(item: item)
                            }
                        }
                    }
                    if let likes = library.likes {
                        Section("Likes") {
                            DownloadedCollectionRow(item: likes)
                        }
                    }
                    if !library.songs.isEmpty {
                        Section("Tracks") {
                            ForEach(library.songs) { item in
                                DownloadedTrackRow(item: item, context: library.songs)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloaded Music")
    }
}

struct DownloadedCollectionView: View {
    let collectionID: String
    let title: String
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var showingRemoveConfirmation = false

    init(collectionID: String, title: String) {
        self.collectionID = collectionID
        self.title = title
    }

    var body: some View {
        let tracks = downloads.tracks(inDownloadedCollection: collectionID)
        let excluded = downloads.collections[collectionID]?.excludedTrackIDs.count ?? 0
        List {
            Section {
                ForEach(tracks) { item in
                    DownloadedTrackRow(item: item, context: tracks)
                }
            } footer: {
                if excluded > 0 {
                    Text("\(DownloadsFormat.trackCount(excluded)) removed.")
                }
            }
            Section {
                Button("Remove Download", role: .destructive) {
                    showingRemoveConfirmation = true
                }
            }
        }
        .navigationTitle(title)
        .downloadedListStyle()
        .confirmationDialog("Remove Download", isPresented: $showingRemoveConfirmation) {
            Button("Remove Download", role: .destructive) {
                downloads.removeDownload(.collection(collectionID))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(title) will no longer stay downloaded.")
        }
    }
}

private extension View {
    func downloadedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        self
        #endif
    }
}

private struct DownloadedCollectionRow: View {
    let item: DownloadedCollectionItem
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        link
            .libraryRowPreviewShape()
            .contextMenu {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    downloads.removeDownload(.collection(item.id))
                }
            }
            #if os(iOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    downloads.removeDownload(.collection(item.id))
                }
            }
            #endif
    }

    @ViewBuilder
    private var link: some View {
        #if os(tvOS)
        NavigationLink(value: DownloadedCollectionRoute(id: item.id, title: item.title)) { label }
        #else
        NavigationLink { DownloadedCollectionView(collectionID: item.id, title: item.title) } label: { label }
        #endif
    }

    private var label: some View {
        DownloadedRowLabel(
            artworkURL: item.artworkURL,
            identity: item.id,
            icon: item.kind == .likes ? "heart.fill" : "music.note.list",
            title: item.title,
            detail: DownloadsFormat.collectionDetail(item, waitingReason: downloads.waitingReason)
        )
    }
}

struct DownloadedCollectionRoute: Hashable {
    let id: String
    let title: String
}

private struct DownloadedTrackRow: View {
    let item: DownloadedTrackItem
    let context: [DownloadedTrackItem]
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.downloadedTrackPlayer) private var playTrack

    private var isPlayable: Bool {
        if case .downloaded = item.state { return true }
        return false
    }

    private func play() {
        playTrack(item.track, context.filter { track in
            if case .downloaded = track.state { return true }
            return false
        }.map(\.track))
    }

    var body: some View {
        row
            .libraryRowPreviewShape()
            .contextMenu {
                if case .paused = item.state {
                    Button("Resume", systemImage: "arrow.down.circle") {
                        downloads.resume(trackId: item.id)
                    }
                }
                if case .failed = item.state {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        downloads.resume(trackId: item.id)
                    }
                }
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    downloads.removeDownload(.track(item.id))
                }
            }
            #if os(iOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    downloads.removeDownload(.track(item.id))
                }
            }
            #endif
    }

    @ViewBuilder
    private var row: some View {
        #if os(tvOS)
        Button(action: play) { label }
            .disabled(!isPlayable)
        #else
        Button(action: play) { label }
            .buttonStyle(.plain)
            .disabled(!isPlayable)
        #endif
    }

    private var label: some View {
        LabeledContent {
            trailing
        } label: {
            DownloadedRowLabel(
                artworkURL: item.track.artworkURL,
                identity: item.track.id,
                icon: "music.note",
                title: item.track.title,
                detail: item.track.user.displayName
            )
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .downloading:
            DownloadFractionReader(trackId: item.id) { fraction in
                Text("\(Int(fraction * 100))%").monospacedDigit()
            }
        default:
            Text(DownloadsFormat.trackDetail(item, waitingReason: downloads.waitingReason))
        }
    }
}

private struct DownloadedRowLabel: View {
    let artworkURL: URL?
    let identity: String
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Self.spacing) {
            SCArtworkResolver(url: artworkURL, variant: .thumbnail) { image in
                ZStack {
                    if let image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.08)
                        Image(systemName: icon)
                            .font(.system(size: Self.artworkSize * 0.36))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: Self.artworkSize * 0.14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail)
                    .font(Self.detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private static var artworkSize: CGFloat {
        #if os(tvOS)
        return 72
        #elseif os(macOS)
        return 36
        #else
        return 48
        #endif
    }

    private static var spacing: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 12
        #endif
    }

    private static var detailFont: Font {
        #if os(macOS)
        return .caption
        #else
        return .footnote
        #endif
    }
}

enum MenuPreviewMetrics {
    static let tileCorner: CGFloat = 22
    static let tileInset: CGFloat = 8
    static let rowCorner: CGFloat = 14
}

extension View {
    @ViewBuilder
    func libraryTilePreviewShape(cornerRadius: CGFloat = MenuPreviewMetrics.tileCorner, inset: CGFloat = MenuPreviewMetrics.tileInset) -> some View {
        #if os(iOS)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .padding(inset)
            .contentShape(.contextMenuPreview, shape)
            .contentShape(.hoverEffect, shape)
            .padding(-inset)
        #else
        self
        #endif
    }

    @ViewBuilder
    func libraryCardPreviewShape(cornerRadius: CGFloat = MenuPreviewMetrics.tileCorner) -> some View {
        libraryTilePreviewShape(cornerRadius: cornerRadius, inset: 0)
    }

    @ViewBuilder
    func libraryRowPreviewShape(cornerRadius: CGFloat = MenuPreviewMetrics.rowCorner, horizontalInset: CGFloat = 0) -> some View {
        #if os(iOS)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .padding(.horizontal, horizontalInset)
            .contentShape(.contextMenuPreview, shape)
            .contentShape(.hoverEffect, shape)
            .padding(.horizontal, -horizontalInset)
        #else
        self
        #endif
    }

    @ViewBuilder
    func libraryCirclePreviewShape() -> some View {
        #if os(iOS)
        self
            .contentShape(.contextMenuPreview, Circle())
            .contentShape(.hoverEffect, Circle())
        #else
        self
        #endif
    }
}
