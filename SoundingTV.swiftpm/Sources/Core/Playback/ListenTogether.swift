import AVFoundation
import Combine
import CoreTransferable
import Foundation
import GroupActivities
import os

struct ListenTogetherActivity: GroupActivity {
    static let activityIdentifier = "red.forbes.sounding.listen-together"

    var starterToken: String
    var initial: ListenTogetherNowPlaying

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .listenTogether
        metadata.title = initial.track?.title ?? "Listen Together"
        metadata.subtitle = initial.track?.user.displayName
        metadata.fallbackURL = initial.track?.permalinkURL
        metadata.supportsContinuationOnTV = true
        return metadata
    }
}

#if !os(tvOS)
extension ListenTogetherActivity: Transferable {}

struct ListenTogetherShareItem: Transferable {
    let activity: ListenTogetherActivity
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        GroupActivityTransferRepresentation { item in item.activity }
        ProxyRepresentation(exporting: \.url)
    }
}
#endif

@MainActor
final class ListenTogether: ObservableObject {
    static let shared = ListenTogether()

    @Published private(set) var participantCount = 0
    @Published private(set) var isEligible = false
    @Published var isShowingSignInPrompt = false

    var isActive: Bool { participantCount > 0 }

    private let player: PlayerService
    private let credentials: SoundCloudCredentialSource
    private let starterToken = UUID().uuidString
    private let stateObserver = GroupStateObserver()
    private let coordinatorDelegate = ListenTogetherCoordinatorDelegate()
    private var isObserving = false
    private var machine: ListenTogetherMachine?
    private var session: GroupSession<ListenTogetherActivity>?
    private var messenger: GroupSessionMessenger?
    private var sessionTasks: [Task<Void, Never>] = []
    private var sessionCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()
    private var coordinatedPlayer: AVPlayer?
    private var applyingRemote = false
    private let log = Logger(subsystem: "red.forbes.sounding", category: "ListenTogether")

    init(player: PlayerService = .shared, credentials: SoundCloudCredentialSource = .shared) {
        self.player = player
        self.credentials = credentials
    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        stateObserver.$isEligibleForGroupSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isEligible = $0 }
            .store(in: &cancellables)
        credentials.$state
            .map(\.isAuthenticated)
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.dispatch(.signedIn) }
            .store(in: &cancellables)
        Task { [weak self] in
            for await session in ListenTogetherActivity.sessions() {
                self?.configure(session)
            }
        }
    }

    func makeActivity() -> ListenTogetherActivity? {
        guard let track = player.currentTrack else { return nil }
        let window = ListenTogetherCodec.window(player.queue, currentIndex: player.currentIndex, maxUpcoming: 0)
        let initial = ListenTogetherNowPlaying(
            stamp: ListenTogetherStamp(counter: 0, origin: ""),
            tracks: window.tracks.isEmpty ? [track] : window.tracks,
            currentIndex: 0,
            position: player.currentTime,
            isPlaying: player.isPlaying,
            sentAt: Date(),
            sourceTitle: player.queueSource?.title
        )
        return ListenTogetherActivity(starterToken: starterToken, initial: initial)
    }

    #if !os(tvOS)
    func shareItem() -> ListenTogetherShareItem? {
        guard let activity = makeActivity(), let url = activity.initial.track?.permalinkURL else { return nil }
        return ListenTogetherShareItem(activity: activity, url: url)
    }
    #endif

    func start() async {
        guard let activity = makeActivity() else { return }
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do {
                _ = try await activity.activate()
            } catch {
                log.error("SharePlay activation failed: \(error.localizedDescription, privacy: .public)")
            }
        case .activationDisabled, .cancelled:
            break
        @unknown default:
            break
        }
    }

    func leave() {
        session?.leave()
    }

    // MARK: - Session

    private func configure(_ session: GroupSession<ListenTogetherActivity>) {
        tearDown()
        self.session = session
        machine = ListenTogetherMachine(origin: session.localParticipant.id.uuidString)

        session.$state
            .sink { [weak self, weak session] state in
                guard let self, let session, self.session === session else { return }
                if case .invalidated = state {
                    self.dispatch(.sessionEnded)
                    self.tearDown()
                }
            }
            .store(in: &sessionCancellables)

        session.$activeParticipants
            .sink { [weak self] participants in
                self?.dispatch(.participantsChanged(participants.map(\.id.uuidString)))
            }
            .store(in: &sessionCancellables)

        dispatch(.sessionArrived(signedIn: credentials.isAuthenticated))
    }

    private func tearDown() {
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = []
        sessionCancellables.removeAll()
        coordinatedPlayer = nil
        messenger = nil
        session = nil
        machine = nil
        participantCount = 0
        isShowingSignInPrompt = false
    }

    private func dispatch(_ event: ListenTogetherMachine.Event) {
        guard var machine else { return }
        let effects = machine.handle(event)
        self.machine = machine
        participantCount = machine.participantCount
        effects.forEach(perform)
    }

    private func perform(_ effect: ListenTogetherMachine.Effect) {
        switch effect {
        case .promptSignIn:
            isShowingSignInPrompt = true
        case .join:
            isShowingSignInPrompt = false
            join()
        case .suspendMixing:
            player.setMixingSuspendedForGroupSession(true)
        case .resumeMixing:
            player.setMixingSuspendedForGroupSession(false)
        case .send(let message, let recipient):
            send(message, to: recipient)
        case .play(let nowPlaying, let position):
            Task { await apply(nowPlaying, position: position) }
        case .applyTransport(let position, let isPlaying):
            applyTransport(position: position, isPlaying: isPlaying)
        }
    }

    private func join() {
        guard let session else { return }
        let messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        self.messenger = messenger
        session.join()

        sessionTasks.append(Task { [weak self] in
            for await (data, _) in messenger.messages(of: Data.self) {
                guard let message = try? ListenTogetherCodec.decode(data) else { continue }
                self?.dispatch(.received(message))
            }
        })

        coordinate(player.avPlayer)
        player.avPlayerDidChange
            .sink { [weak self] in self?.coordinate($0) }
            .store(in: &sessionCancellables)

        observeLocalPlayback()

        let activity = session.activity
        if activity.starterToken == starterToken {
            reportLocalTrack()
        } else {
            sessionTasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.machine?.current == nil else { return }
                self.dispatch(.received(.nowPlaying(activity.initial)))
            })
        }
    }

    private func coordinate(_ avPlayer: AVPlayer?) {
        guard let session, let avPlayer, coordinatedPlayer !== avPlayer else { return }
        coordinatedPlayer = avPlayer
        coordinatorDelegate.setTrackID(player.currentTrack?.id)
        avPlayer.playbackCoordinator.delegate = coordinatorDelegate
        avPlayer.playbackCoordinator.coordinateWithSession(session)
    }

    private var isCoordinated: Bool {
        guard let coordinatedPlayer else { return false }
        return coordinatedPlayer === player.avPlayer && !player.isMixEngineLive
    }

    private func observeLocalPlayback() {
        player.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .handleEvents(receiveOutput: { [coordinatorDelegate] in coordinatorDelegate.setTrackID($0) })
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reportLocalTrack() }
            .store(in: &sessionCancellables)

        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.reportLocalTransport() }
            .store(in: &sessionCancellables)

        player.seekEvents
            .sink { [weak self] _ in self?.reportLocalTransport() }
            .store(in: &sessionCancellables)
    }

    private func reportLocalTrack() {
        guard !applyingRemote, player.queue.indices.contains(player.currentIndex) else { return }
        dispatch(.localTrackChanged(
            tracks: player.queue,
            currentIndex: player.currentIndex,
            position: player.currentTime,
            isPlaying: player.isPlaying || player.playbackRequested,
            sourceTitle: player.queueSource?.title
        ))
    }

    private func reportLocalTransport() {
        guard !applyingRemote, let trackID = player.currentTrack?.id else { return }
        dispatch(.localTransport(trackID: trackID, position: player.currentTime, isPlaying: player.isPlaying))
    }

    private func send(_ message: ListenTogetherMessage, to recipient: String?) {
        guard let messenger, let session else { return }
        let data: Data?
        if case .nowPlaying(let nowPlaying) = message {
            data = ListenTogetherCodec.fitting(nowPlaying)
        } else {
            data = try? ListenTogetherCodec.encode(message)
        }
        guard let data else { return }
        let participants: Participants
        if let recipient {
            guard let participant = session.activeParticipants.first(where: { $0.id.uuidString == recipient }) else { return }
            participants = .only(participant)
        } else {
            participants = .all
        }
        messenger.send(data, to: participants) { [log] error in
            if let error { log.error("SharePlay send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Applying the group's state

    private func apply(_ nowPlaying: ListenTogetherNowPlaying, position: TimeInterval) async {
        guard let track = nowPlaying.track else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        if player.currentTrack?.id != track.id {
            let source = nowPlaying.sourceTitle.map { PlaybackQueueSource(id: nil, kind: .other, title: $0) }
            await player.play(track, in: nowPlaying.tracks, source: source)
        }
        guard !isCoordinated else { return }
        if abs(player.currentTime - position) > ListenTogetherMachine.seekTolerance {
            player.seek(to: position, expectedTrackID: track.id, intent: .correction)
        }
        if nowPlaying.isPlaying != player.isPlaying {
            nowPlaying.isPlaying ? player.play() : player.pause()
        }
    }

    private func applyTransport(position: TimeInterval, isPlaying: Bool) {
        guard !isCoordinated else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        if abs(player.currentTime - position) > ListenTogetherMachine.seekTolerance {
            player.seek(to: position, expectedTrackID: player.currentTrack?.id, intent: .correction)
        }
        if isPlaying != player.isPlaying {
            isPlaying ? player.play() : player.pause()
        }
    }
}

final class ListenTogetherCoordinatorDelegate: NSObject, AVPlayerPlaybackCoordinatorDelegate, Sendable {
    private let trackID = OSAllocatedUnfairLock(initialState: "")

    func setTrackID(_ id: String?) {
        trackID.withLock { $0 = id ?? "" }
    }

    func playbackCoordinator(_ coordinator: AVPlayerPlaybackCoordinator, identifierFor playerItem: AVPlayerItem) -> String {
        trackID.withLock { $0 }
    }
}
