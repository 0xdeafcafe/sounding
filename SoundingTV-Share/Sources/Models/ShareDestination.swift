import Foundation
import Network
import Combine
import SwiftUI

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
                return "Link this \(DeviceClass.current.displayName) to your Apple TV in Sounding first."
            case .discoveryFailed(let message):
                return "Couldn't find your Apple TV. \(message)"
            case .connectionFailed(let message):
                return "Lost connection to your Apple TV. \(message)"
            case .rejected(let message):
                return message
            case .timedOut:
                return "Your Apple TV didn't respond. Make sure it's on and on the same Wi-Fi."
            case .trackNotInQueue:
                return "Couldn't confirm it was added."
            }
        }
    }

    private nonisolated(unsafe) var browser: NWBrowser?
    private nonisolated(unsafe) var timeoutTask: Task<Void, Never>?
    private var channel: CompanionChannel?

    private var continuation: CheckedContinuation<QueueStatePayload, Error>?

    private var baselineRevision = -1

    private var signer: CompanionCommandSigner?

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        timeoutTask?.cancel()
        browser?.cancel()
    }

    func connect(timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        guard let link = LinkedCompanionStore.load(), let secret = link.secret else {
            throw SendError.notPaired
        }
        signer = CompanionCommandSigner(sessionId: link.sessionId, secret: secret)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            armTimeout(timeout)
            startDiscovery(sessionId: link.sessionId, secret: secret)
        }
    }

    func add(trackId: String, toIndex: Int = -1, timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        try await send(timeout: timeout) { $0.queue(.queueAdd, toIndex: toIndex, trackId: trackId, revision: $1) }
    }

    func replace(trackId: String, timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        try await send(timeout: timeout) { $0.queue(.queueReplace, trackId: trackId, revision: $1) }
    }

    func load(trackIds: [String], timeout: Duration = .seconds(15)) async throws -> QueueStatePayload {
        try await send(timeout: timeout) { signer, _ in
            signer.load(trackIds: trackIds, startIndex: 0, positionSeconds: 0, autoplay: true)
        }
    }

    func nextState(timeout: Duration = .seconds(15)) async throws -> QueueStatePayload {
        guard channel != nil else { throw SendError.connectionFailed("Not connected") }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            armTimeout(timeout)
        }
    }

    func jump(to trackId: String, in queue: QueueStatePayload, timeout: Duration = .seconds(8)) async throws -> QueueStatePayload {
        guard let index = queue.tracks.lastIndex(where: { $0.id == trackId }) else {
            throw SendError.trackNotInQueue
        }
        return try await send(timeout: timeout) {
            $0.queue(.queueJump, fromIndex: index, trackId: trackId, revision: $1)
        }
    }

    func disconnect() {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        channel?.cancel()
        channel = nil
    }

    private func send(
        timeout: Duration,
        _ build: @escaping (CompanionCommandSigner, Int) -> TokenTransferMessage
    ) async throws -> QueueStatePayload {
        guard let channel, let signer else {
            throw SendError.connectionFailed("Not connected")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            armTimeout(timeout)
            channel.send(build(signer, baselineRevision)) { [weak self] error in
                guard let error else { return }
                self?.finish(.failure(SendError.connectionFailed(error.localizedDescription)))
            }
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
        let newBrowser = CompanionEndpoint.makeBrowser(serviceType: BuildFlavor.current.bonjourServiceType)

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.channel == nil else { return }
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint,
                          CompanionEndpoint.isCompanionService(name, sessionId: sessionId) else { continue }

                    self.browser?.cancel()
                    self.browser = nil
                    self.openChannel(to: result.endpoint, sessionId: sessionId, secret: secret)
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

    private func openChannel(to endpoint: NWEndpoint, sessionId: String, secret: Data) {
        let newChannel = CompanionChannel(to: endpoint, sessionId: sessionId, secret: secret, keepalive: false)
        channel = newChannel
        newChannel.start(
            onEvent: { [weak self, weak newChannel] event in
                guard let self, let newChannel, self.channel === newChannel else { return }
                switch event {
                case .ready, .waiting:
                    break
                case .failed(let reason):
                    self.channel = nil
                    self.finish(.failure(SendError.connectionFailed(reason)))
                case .closed:
                    self.channel = nil
                    self.finish(.failure(SendError.connectionFailed("Your Apple TV closed the connection.")))
                }
            },
            onMessage: { [weak self] message in
                self?.handle(message, sessionId: sessionId, secret: secret)
            }
        )
    }

    private func handle(_ message: TokenTransferMessage, sessionId: String, secret: Data) {
        guard message.sessionId == sessionId else { return }

        switch message.type {
        case .error:
            finish(.failure(SendError.rejected(message.error ?? "The Apple TV rejected the command.")))

        case .queueState:
            guard let queue = message.queue,
                  queue.verify(sessionId: sessionId, secret: secret),
                  queue.revision > baselineRevision else { return }
            baselineRevision = queue.revision
            finish(.success(queue))

        default:
            break
        }
    }

    private func finish(_ result: Result<QueueStatePayload, Error>) {
        guard let continuation else { return }
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
        case unresolved(URL)
        case working(Progress)
        case succeeded(String)
        case failed(String)
    }

    typealias Handoff = @MainActor (URL, QueueAction) -> Bool

    static let maxBatchTracks = 100

    @Published private(set) var state: State = .extractingURL
    @Published private(set) var isBusy = false

    private var sourceURL: URL?
    private(set) var lastResolvedItem: SoundCloudAPI.ResolvedItem?
    private let client = ShareTVClient()
    private let handoff: Handoff?

    init(handoff: Handoff? = nil) {
        self.handoff = handoff
    }

    var handsOffToApp: Bool { handoff != nil }

    func begin(with url: URL?) async {
        guard let url, Self.isSoundCloudHost(url) else {
            state = .notASoundCloudURL
            return
        }
        sourceURL = url

        guard let session = DeviceSessionStore.load(), session.isUsable else {
            state = handsOffToApp ? .unresolved(url) : .notSignedIn
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
            state = handsOffToApp ? .unresolved(url) : .notSignedIn
        } catch {
            state = handsOffToApp ? .unresolved(url) : .resolveFailed(Self.describe(error))
        }
    }

    func retry() {
        if let lastResolvedItem {
            state = .resolved(lastResolvedItem)
        } else {
            Task { await begin(with: sourceURL) }
        }
    }

    func handOff(_ action: QueueAction) {
        guard let handoff, let sourceURL else { return }
        state = handoff(sourceURL, action)
            ? .succeeded("Opening in Sounding.")
            : .failed("Couldn't open Sounding.")
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
        guard !handsOffToApp else {
            handOff(action)
            return
        }
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
                do {
                    var loaded = try await client.load(trackIds: trackIds)
                    while loaded.tracks.first?.id != firstId {
                        loaded = try await client.nextState()
                    }
                    queue = loaded
                    addedCount = trackIds.count
                    break
                } catch ShareTVClient.SendError.rejected(_) {
                    Log.link.info("[ShareTVClient] Apple TV doesn't load whole queues; replacing track by track")
                }
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
            if #available(iOS 27.0, macOS 27.0, *) {
                makeBody()
                    .asyncImageURLSession(Self.cachingImageSession)
            } else {
                makeBody()
            }
        }
        .tint(.scAccent)
    }

    @ViewBuilder
    private func makeBody() -> some View {
        NavigationStack {
            content
                .navigationTitle(viewModel.handsOffToApp ? "Play in Sounding" : "Send to Apple TV")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onFinish)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .extractingURL, .resolving:
            ProgressView("Loading…")

        case .notASoundCloudURL:
            MessageStateView(
                systemImage: "link",
                title: "Not a SoundCloud Link",
                message: "Share a SoundCloud track, playlist or profile.",
                actionTitle: "Done",
                action: onFinish
            )

        case .notSignedIn:
            MessageStateView(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Not Signed In",
                message: "Sign in to Sounding, then share again.",
                actionTitle: "Done",
                action: onFinish
            )

        case .resolveFailed(let message):
            MessageStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn’t Load",
                message: message,
                actionTitle: "Try Again",
                action: { viewModel.retry() }
            )

        case .resolved(let item):
            ResolvedItemView(item: item, viewModel: viewModel)

        case .unresolved(let url):
            UnresolvedLinkView(url: url, viewModel: viewModel)

        case .working(let progress):
            if let item = viewModel.lastResolvedItem {
                SendingView(item: item, progress: progress)
            } else {
                ProgressView(value: progress.fraction) {
                    Text(progress.label)
                }
                .padding()
            }

        case .succeeded(let message):
            MessageStateView(systemImage: "checkmark.circle", title: "Sent", message: message)
                .task {
                    try? await Task.sleep(for: .seconds(1.6))
                    onFinish()
                }

        case .failed(let message):
            MessageStateView(
                systemImage: "wifi.exclamationmark",
                title: "Couldn’t Send",
                message: message,
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
        Form {
            Section {
                ItemHeaderRow(item: item)
            }
            Section {
                ProgressView(value: progress.fraction) {
                    Text(progress.label)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MessageStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
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
            kindLabel = user.kindLabel
            isCircularArtwork = true
        }
    }
}

private func shareThumbnailURL(_ url: URL?) -> URL? {
    guard let url else { return nil }
    return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t200x200")) ?? url
}

private struct ItemHeaderRow: View {
    let item: SoundCloudAPI.ResolvedItem

    var body: some View {
        let info = ItemPreview(item)
        return HStack(spacing: 12) {
            AsyncImage(url: shareThumbnailURL(info.artworkURL)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Rectangle().fill(.fill.quaternary)
                        Image(systemName: info.isCircularArtwork ? "person.fill" : "music.note")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(
                info.isCircularArtwork
                    ? AnyShape(Circle())
                    : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(info.kindLabel) · \(info.subtitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
        Form {
            Section {
                ItemHeaderRow(item: item)
            }

            QueueActionsSection(footer: batchFooter) { action in
                Task { await viewModel.perform(action, on: item) }
            }
            .disabled(batchCount == 0)

            if !viewModel.handsOffToApp {
                Section {
                    Button(role: .destructive) {
                        isConfirmingReplace = true
                    } label: {
                        Label("Replace Queue", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(batchCount == 0)
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.isBusy)
        .confirmationDialog(
            "Replace Queue?",
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace and Play", role: .destructive) {
                Task { await viewModel.perform(.replace, on: item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(replaceConfirmationMessage)
        }
    }

    private var batchFooter: String? {
        guard let count = batchCount else { return nil }
        if count > ShareViewModel.maxBatchTracks {
            return "The first \(ShareViewModel.maxBatchTracks) of \(count) tracks are sent."
        }
        return count == 1 ? "1 track." : "\(count) tracks."
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
        return "Clears the Apple TV queue and plays \(subject)."
    }
}

private struct QueueActionsSection: View {
    var footer: String?
    let perform: (ShareViewModel.QueueAction) -> Void

    var body: some View {
        Section {
            Button {
                perform(.playNow)
            } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button {
                perform(.playNext)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                perform(.addToEnd)
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

private struct UnresolvedLinkView: View {
    let url: URL
    @ObservedObject var viewModel: ShareViewModel

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(2)
                        Text("SoundCloud")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "link")
                }
            }

            QueueActionsSection { action in
                viewModel.handOff(action)
            }
        }
        .formStyle(.grouped)
    }

    private var title: String {
        let path = url.pathComponents.filter { $0 != "/" }
        return path.last?.replacingOccurrences(of: "-", with: " ") ?? url.absoluteString
    }
}

@MainActor
enum ShareItemExtractor {
    static func soundCloudCandidateURL(in items: [NSExtensionItem]) async -> URL? {
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let url = await loadURL(from: provider) {
                    return url
                }
            }
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: NSURL.self),
           let url = await urlObject(from: provider) {
            return url
        }

        if provider.canLoadObject(ofClass: NSString.self),
           let text = await stringObject(from: provider) {
            return firstURL(in: text)
        }

        return nil
    }

    private static func urlObject(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                let url = (object as? NSURL).map { $0 as URL }
                continuation.resume(returning: url)
            }
        }
    }

    private static func stringObject(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                let string = (object as? NSString).map { $0 as String }
                continuation.resume(returning: string)
            }
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let urls = detector.matches(in: text, range: range).compactMap(\.url)
        return urls.first { ShareViewModel.isSoundCloudHost($0) } ?? urls.first
    }
}
