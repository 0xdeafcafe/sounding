import Foundation
import Network
import Combine
import SwiftUI

/// Backward-compatible alias for the shared SoundCloud credential source in the
/// Share extension.
typealias ShareCredentialSource = SoundCloudCredentialSource

@MainActor
final class ShareTVClient {

    enum SendError: LocalizedError {
        case notPaired
        case discoveryFailed(String)
        case connectionFailed(String)
        case rejected(String)
        case timedOut
        case trackNotInQueue

        var errorDescription: String? {
            switch self {
            case .notPaired:
                return "This iPhone isn't linked to an Apple TV yet. Open SoundingCloud on the Apple TV and follow the sign-in screen there."
            case .discoveryFailed(let message):
                return "Couldn't search the network: \(message)"
            case .connectionFailed(let message):
                return "Lost the connection to the Apple TV: \(message)"
            case .rejected(let message):
                return message
            case .timedOut:
                return "Your Apple TV didn't respond in time. Make sure it's awake and on the same Wi-Fi."
            case .trackNotInQueue:
                return "Couldn't confirm the track landed in the queue."
            }
        }
    }

    private nonisolated(unsafe) var browser: NWBrowser?
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var timeoutTask: Task<Void, Never>?

    private var framer = MessageFramer()
    private var continuation: CheckedContinuation<QueueStatePayload, Error>?

    private var baselineRevision = -1

    private var sessionId: String?
    private var secret: Data?

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        timeoutTask?.cancel()
        browser?.cancel()
        connection?.cancel()
    }

    func connect(timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        guard let link = LinkedCompanionStore.load(), let secret = link.secret else {
            throw SendError.notPaired
        }
        sessionId = link.sessionId
        self.secret = secret

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            armTimeout(timeout)
            startDiscovery(sessionId: link.sessionId, secret: secret)
        }
    }

    func add(trackId: String, toIndex: Int = -1, timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        try await sendQueueCommand(.queueAdd, fromIndex: -1, toIndex: toIndex, trackId: trackId, timeout: timeout)
    }

    func replace(trackId: String, timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        try await sendQueueCommand(.queueReplace, fromIndex: -1, toIndex: -1, trackId: trackId, timeout: timeout)
    }

    func jump(to trackId: String, in queue: QueueStatePayload, timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        guard let index = queue.tracks.lastIndex(where: { $0.id == trackId }) else {
            throw SendError.trackNotInQueue
        }
        return try await sendQueueCommand(.queueJump, fromIndex: index, toIndex: -1, trackId: trackId, timeout: timeout)
    }

    func disconnect() {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
    }

    private func sendQueueCommand(
        _ type: MessageType, fromIndex: Int, toIndex: Int, trackId: String, timeout: Duration
    ) async throws -> QueueStatePayload {
        guard let connection, let sessionId, let secret else {
            throw SendError.connectionFailed("Not connected")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            armTimeout(timeout)

            let command = QueueCommandPayload.create(
                type: type, fromIndex: fromIndex, toIndex: toIndex, trackId: trackId,
                revision: max(0, baselineRevision),
                sessionId: sessionId, secret: secret
            )

            guard let data = try? TokenTransferMessage
                .queueCommand(type, sessionId: sessionId, command: command)
                .framed()
            else {
                finish(.failure(SendError.connectionFailed("Failed to encode command")))
                return
            }

            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.finish(.failure(SendError.connectionFailed(error.localizedDescription)))
                }
            })
        }
    }

    private func armTimeout(_ timeout: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(SendError.timedOut))
        }
    }

    private func startDiscovery(sessionId: String, secret: Data) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let newBrowser = NWBrowser(
            for: .bonjour(type: BonjourConstants.serviceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )

        let prefix = String(sessionId.prefix(8))

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    guard name.hasPrefix(BonjourConstants.companionServiceName), name.contains(prefix) else { continue }

                    self.browser?.cancel()
                    self.browser = nil
                    self.openConnection(to: result.endpoint, sessionId: sessionId, secret: secret)
                    return
                }
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard case .failed(let error) = state else { return }
                self?.finish(.failure(SendError.discoveryFailed(error.localizedDescription)))
            }
        }

        browser = newBrowser
        newBrowser.start(queue: .main)
    }

    private func openConnection(to endpoint: NWEndpoint, sessionId: String, secret: Data) {
        framer = MessageFramer()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false

        let newConnection = NWConnection(to: endpoint, using: parameters)
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, newConnection === self.connection else { return }
                switch state {
                case .ready:
                    self.receive(on: newConnection)
                case .failed(let error):
                    self.connection = nil
                    self.finish(.failure(SendError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    self.connection = nil
                default:
                    break
                }
            }
        }

        connection = newConnection
        newConnection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }

                if let error {
                    self.connection = nil
                    self.finish(.failure(SendError.connectionFailed(error.localizedDescription)))
                    return
                }

                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let message = try? self.framer.next() {
                        self.handle(message)
                    }
                }

                if isComplete {
                    self.connection = nil
                    self.finish(.failure(SendError.connectionFailed("The Apple TV closed the connection.")))
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func handle(_ message: TokenTransferMessage) {
        guard let sessionId, message.sessionId == sessionId, let secret else { return }

        switch message.type {
        case .error:
            finish(.failure(SendError.rejected(message.error ?? "The Apple TV rejected the command.")))

        case .queueState:
            guard let queue = message.queue,
                  queue.verify(sessionId: sessionId, secret: secret) else {
                return // Unsigned or forged — silently drop.
            }
            guard queue.revision > baselineRevision else { return }
            baselineRevision = queue.revision
            finish(.success(queue))

        default:
            break // `playback_state`, `dj_state` — legitimate traffic this client isn't waiting for.
        }
    }

    private func finish(_ result: Result<QueueStatePayload, Error>) {
        guard let continuation else { return } // No pending call — ignore.
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class ShareViewModel: ObservableObject {

    struct Progress: Equatable {
        var label: String
        var completed: Int?
        var total: Int?

        var fraction: Double? {
            guard let completed, let total, total > 1 else { return nil }
            return min(1, max(0, Double(completed) / Double(total)))
        }

        static func step(_ label: String) -> Progress {
            Progress(label: label, completed: nil, total: nil)
        }
    }

    enum State {
        case extractingURL
        case notASoundCloudURL
        case notSignedIn
        case resolving
        case resolveFailed(String)
        case resolved(SoundCloudAPI.ResolvedItem)
        case working(Progress)
        case succeeded(String)
        case failed(String)
    }

    static let maxBatchTracks = 100

    @Published private(set) var state: State = .extractingURL
    @Published private(set) var isBusy = false

    private var sourceURL: URL?
    private(set) var lastResolvedItem: SoundCloudAPI.ResolvedItem?
    private let client = ShareTVClient()

    func begin(with url: URL?) async {
        guard let url, Self.isSoundCloudHost(url) else {
            state = .notASoundCloudURL
            return
        }
        sourceURL = url

        guard let session = DeviceSessionStore.load(), session.isUsable else {
            state = .notSignedIn
            return
        }

        state = .resolving
        do {
            let resolved = try await SoundCloudAPI.shared.resolve(url: url)
            lastResolvedItem = resolved
            state = .resolved(resolved)
        } catch APIError.notFound {
            state = .resolveFailed("Couldn't find that link. It may be private, deleted, or region-locked.")
        } catch APIError.unauthorized {
            state = .notSignedIn
        } catch {
            state = .resolveFailed(Self.describe(error))
        }
    }

    func retry() {
        if let lastResolvedItem {
            state = .resolved(lastResolvedItem)
        } else {
            Task { await begin(with: sourceURL) }
        }
    }

    static func isSoundCloudHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "soundcloud.com" || host.hasSuffix(".soundcloud.com")
    }

    enum QueueAction {
        case playNext
        case addToEnd
        case playNow
        case replace
    }

    func perform(_ action: QueueAction, on item: SoundCloudAPI.ResolvedItem) async {
        switch item {
        case .track(let track):
            await run(itemLabel: track.title, action: action) { return [track.id] }
        case .playlist(let playlist):
            await run(itemLabel: playlist.title, action: action) { try await Self.trackIds(forPlaylist: playlist) }
        case .user(let user):
            await run(itemLabel: user.displayName, action: action) { try await Self.trackIds(forUser: user) }
        }
    }

    private static func trackIds(forPlaylist playlist: Playlist) async throws -> [String] {
        let full = try await SoundCloudAPI.shared.getPlaylist(id: playlist.id)
        return Array((full.tracks ?? []).prefix(maxBatchTracks)).map(\.id)
    }

    private static func trackIds(forUser user: User) async throws -> [String] {
        let page = try await SoundCloudAPI.shared.getUserTracks(userId: user.id, limit: maxBatchTracks)
        return page.collection.map(\.id)
    }

    private func run(itemLabel: String, action: QueueAction, resolveTrackIds: @escaping () async throws -> [String]) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        var addedCount = 0
        var totalCount = 0
        do {
            state = .working(.step("Loading tracks…"))
            let trackIds = try await resolveTrackIds()
            totalCount = trackIds.count
            guard !trackIds.isEmpty else {
                state = .failed("Couldn't find any tracks to queue.")
                return
            }

            state = .working(.step("Finding your Apple TV…"))
            var queue = try await client.connect()

            switch action {
            case .addToEnd:
                for (index, trackId) in trackIds.enumerated() {
                    state = .working(Self.progress("Adding", index: index, count: trackIds.count))
                    queue = try await client.add(trackId: trackId, toIndex: -1)
                    addedCount += 1
                }

            case .playNext:
                let base = queue.currentIndex + 1
                for (index, trackId) in trackIds.enumerated() {
                    state = .working(Self.progress("Queueing", index: index, count: trackIds.count))
                    queue = try await client.add(trackId: trackId, toIndex: base + index)
                    addedCount += 1
                }

            case .playNow:
                for (index, trackId) in trackIds.enumerated() {
                    state = .working(Self.progress("Adding", index: index, count: trackIds.count))
                    queue = try await client.add(trackId: trackId, toIndex: -1)
                    addedCount += 1
                }
                if let firstId = trackIds.first {
                    state = .working(.step("Starting playback…"))
                    queue = try await client.jump(to: firstId, in: queue)
                }

            case .replace:
                guard let firstId = trackIds.first else { break }
                state = .working(.step(trackIds.count > 1 ? "Replacing queue…" : "Replacing queue and playing…"))
                queue = try await client.replace(trackId: firstId)
                addedCount += 1
                for (index, trackId) in trackIds.dropFirst().enumerated() {
                    state = .working(Self.progress("Adding", index: index + 1, count: trackIds.count))
                    queue = try await client.add(trackId: trackId, toIndex: -1)
                    addedCount += 1
                }
            }

            client.disconnect()
            state = .succeeded(successMessage(action: action, count: trackIds.count, itemLabel: itemLabel))
        } catch {
            client.disconnect()
            let base = Self.describe(error)
            state = .failed(
                addedCount > 0 && addedCount < totalCount
                    ? "Added \(addedCount) of \(totalCount) tracks, then: \(base)"
                    : base
            )
        }
    }

    private static func progress(_ verb: String, index: Int, count: Int) -> Progress {
        guard count > 1 else { return .step("\(verb) to queue…") }
        return Progress(label: "\(verb) \(index + 1) of \(count)…", completed: index, total: count)
    }

    private func successMessage(action: QueueAction, count: Int, itemLabel: String) -> String {
        switch action {
        case .playNow:
            return "Playing “\(itemLabel)” on your Apple TV."
        case .replace:
            return "Queue replaced. Playing “\(itemLabel)” on your Apple TV now."
        case .playNext:
            return count > 1
                ? "“\(itemLabel)” (\(count) tracks) will play next on your Apple TV."
                : "“\(itemLabel)” will play next on your Apple TV."
        case .addToEnd:
            return count > 1
                ? "Added \(count) tracks from “\(itemLabel)” to the end of your Apple TV's queue."
                : "Added “\(itemLabel)” to the end of your Apple TV's queue."
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct ShareRootView: View {
    @ObservedObject var viewModel: ShareViewModel
    let onFinish: () -> Void

    private static let cachingImageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 10 * 1024 * 1024)
        return URLSession(configuration: configuration)
    }()

    var body: some View {
        Group {
            if #available(iOS 27.0, *) {
                makeBody()
                    .asyncImageURLSession(Self.cachingImageSession)
            } else {
                makeBody()
            }
        }
    }

    @ViewBuilder
    private func makeBody() -> some View {
        NavigationStack {
            ZStack {
                Color.scBackgroundGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("Send to Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onFinish)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.scAccent)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .extractingURL, .resolving:
            LoadingStateView(message: "Looking that up…")

        case .notASoundCloudURL:
            MessageStateView(
                systemImage: "link.badge.plus",
                title: "Not a SoundCloud Link",
                message: "Share a track, playlist, or profile link from SoundCloud, Safari, or Messages.",
                actionTitle: "Done",
                action: onFinish
            )

        case .notSignedIn:
            MessageStateView(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Not Signed In",
                message: "Open SoundingCloud on this iPhone, sign in, then share again.",
                actionTitle: "Done",
                action: onFinish
            )

        case .resolveFailed(let message):
            MessageStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't Load This",
                message: message,
                actionTitle: "Try Again",
                action: { viewModel.retry() }
            )

        case .resolved(let item):
            ResolvedItemView(item: item, viewModel: viewModel)

        case .working(let progress):
            if let item = viewModel.lastResolvedItem {
                SendingView(item: item, progress: progress)
            } else {
                LoadingStateView(message: progress.label, fraction: progress.fraction)
            }

        case .succeeded(let message):
            MessageStateView(systemImage: "checkmark.circle.fill", title: "Sent", message: message, tint: .scSuccess)
                .task { // Auto-dismiss rather than making the user tap Cancel after the fact.
                    try? await Task.sleep(for: .seconds(1.6))
                    onFinish()
                }

        case .failed(let message):
            MessageStateView(
                systemImage: "wifi.exclamationmark",
                title: "Couldn't Send",
                message: message,
                tint: .scDestructive,
                actionTitle: "Try Again",
                action: { viewModel.retry() }
            )
        }
    }
}

private struct SendingView: View {
    let item: SoundCloudAPI.ResolvedItem
    let progress: ShareViewModel.Progress

    var body: some View {
        VStack(spacing: Spacing.xl) {
            ItemPreviewCard(item: item)

            VStack(spacing: Spacing.sm) {
                if let fraction = progress.fraction {
                    SwiftUI.ProgressView(value: fraction)
                        .tint(.scAccent)
                } else {
                    SwiftUI.ProgressView()
                        .tint(.scAccent)
                }

                Text(progress.label)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
    }
}

private struct LoadingStateView: View {
    let message: String
    var fraction: Double?

    var body: some View {
        VStack(spacing: Spacing.md) {
            if let fraction {
                SwiftUI.ProgressView(value: fraction)
                    .tint(.scAccent)
                    .frame(maxWidth: 240)
            } else {
                SwiftUI.ProgressView().tint(.scAccent)
            }
            Text(message)
                .font(.scSubhead)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var tint: Color = .scAccent
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(tint)
            Text(title)
                .font(.scTitle2)
            Text(message)
                .font(.scBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.scAccent)
                    .foregroundStyle(Color.scAccentOn)
                    .controlSize(.large)
                    .padding(.top, Spacing.sm)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ItemPreview {
    let artworkURL: URL?
    let title: String
    let subtitle: String
    let kindLabel: String
    let isCircularArtwork: Bool

    init(_ item: SoundCloudAPI.ResolvedItem) {
        switch item {
        case .track(let track):
            artworkURL = track.artworkURL
            title = track.title
            subtitle = "\(track.user.displayName) · \(track.formattedDuration)"
            kindLabel = "Track"
            isCircularArtwork = false
        case .playlist(let playlist):
            artworkURL = playlist.artworkURL
            title = playlist.title
            subtitle = "\(playlist.user.displayName) · \(playlist.trackCount) tracks"
            kindLabel = playlist.isAlbum ? "Album" : "Playlist"
            isCircularArtwork = false
        case .user(let user):
            artworkURL = user.avatarURL
            title = user.displayName
            subtitle = "@\(user.permalink) · \(user.formattedTracks) tracks"
            kindLabel = "Profile"
            isCircularArtwork = true
        }
    }
}

private func shareThumbnailURL(_ url: URL?) -> URL? {
    guard let url else { return nil }
    return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t200x200")) ?? url
}

private struct ItemPreviewCard: View {
    let item: SoundCloudAPI.ResolvedItem

    var body: some View {
        let info = ItemPreview(item)
        return VStack(spacing: Spacing.sm) {
            AsyncImage(url: shareThumbnailURL(info.artworkURL)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Color.primary.opacity(0.08)
                        Image(systemName: info.isCircularArtwork ? "person.fill" : "music.note")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(
                info.isCircularArtwork
                    ? AnyShape(Circle())
                    : AnyShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            )
            .padding(.bottom, Spacing.xs)

            Text(info.kindLabel.uppercased())
                .font(.scCaption)
                .foregroundStyle(Color.scAccent)
                .kerning(1.2)
            Text(info.title)
                .font(.scTitle)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(info.subtitle)
                .font(.scSubhead)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .scCard(cornerRadius: Radius.xl, padding: Spacing.lg)
    }
}

private struct ResolvedItemView: View {
    let item: SoundCloudAPI.ResolvedItem
    @ObservedObject var viewModel: ShareViewModel

    @State private var isConfirmingReplace = false

    private var batchCount: Int? {
        switch item {
        case .track: return nil
        case .playlist(let playlist): return playlist.trackCount
        case .user(let user): return user.trackCount
        }
    }

    private var itemLabel: String {
        switch item {
        case .track(let track): return track.title
        case .playlist(let playlist): return playlist.title
        case .user(let user): return user.displayName
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                preview
                actions
            }
            .padding(Spacing.lg)
        }
        .disabled(viewModel.isBusy)
        .confirmationDialog(
            "Replace Queue?",
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace & Play", role: .destructive) {
                Task { await viewModel.perform(.replace, on: item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(replaceConfirmationMessage)
        }
    }

    private var replaceConfirmationMessage: String {
        let subject: String
        if let count = batchCount {
            let described = count > ShareViewModel.maxBatchTracks
                ? "the first \(ShareViewModel.maxBatchTracks)"
                : "all \(count)"
            subject = "\(described) tracks from “\(itemLabel)”"
        } else {
            subject = "“\(itemLabel)”"
        }
        return "This clears everything queued on your Apple TV and plays \(subject) instead. It can't be undone."
    }

    private var preview: some View { ItemPreviewCard(item: item) }

    private var actions: some View {
        VStack(spacing: Spacing.sm) {
            ActionButton(title: addToEndLabel, systemImage: "text.badge.plus", style: .prominent) {
                Task { await viewModel.perform(.addToEnd, on: item) }
            }
            ActionButton(title: playNextLabel, systemImage: "arrow.turn.down.right", style: .secondary) {
                Task { await viewModel.perform(.playNext, on: item) }
            }
            ActionButton(title: "Play Now on Apple TV", systemImage: "play.fill", style: .secondary) {
                Task { await viewModel.perform(.playNow, on: item) }
            }
            ActionButton(title: replaceLabel, systemImage: "arrow.triangle.2.circlepath", style: .destructive) {
                isConfirmingReplace = true
            }
            .padding(.top, Spacing.xs)
        }
        .disabled(batchCount == 0)
    }

    private var addToEndLabel: String {
        guard let count = batchCount else { return "Add to End of Queue" }
        return count > ShareViewModel.maxBatchTracks
            ? "Add First \(ShareViewModel.maxBatchTracks) to End of Queue"
            : "Add All (\(count)) to End of Queue"
    }

    private var playNextLabel: String {
        guard let count = batchCount else { return "Play Next" }
        return count > ShareViewModel.maxBatchTracks
            ? "Play First \(ShareViewModel.maxBatchTracks) Next"
            : "Play All (\(count)) Next"
    }

    private var replaceLabel: String {
        guard let count = batchCount else { return "Replace Queue" }
        return count > ShareViewModel.maxBatchTracks
            ? "Replace Queue with First \(ShareViewModel.maxBatchTracks)"
            : "Replace Queue with All (\(count))"
    }
}

private struct ActionButton: View {
    enum Style { case prominent, secondary, destructive }

    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.scHeadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .foregroundStyle(foreground)
        .controlSize(.large)
    }

    private var tint: Color {
        switch style {
        case .prominent: return .scAccent
        case .secondary: return Color.primary.opacity(0.12)
        case .destructive: return .scDestructive
        }
    }

    private var foreground: Color {
        switch style {
        case .prominent:   return .scAccentOn
        case .destructive: return .scDestructiveOn
        case .secondary:   return .primary
        }
    }
}
