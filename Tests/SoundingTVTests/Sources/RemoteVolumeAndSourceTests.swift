import XCTest
@testable import SoundingTV

final class RemoteVolumeAndSourceTests: XCTestCase {
    private let credentials = SessionCredentials.generate()!

    private func roundTrip(_ message: TokenTransferMessage) throws -> TokenTransferMessage {
        var framer = MessageFramer()
        framer.append(try message.framed())
        return try XCTUnwrap(try framer.next())
    }

    private func strippingKeys(_ keys: [String], under payloadKey: String, of message: TokenTransferMessage) throws -> TokenTransferMessage {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: message.encode()) as? [String: Any])
        var payload = try XCTUnwrap(object[payloadKey] as? [String: Any])
        for key in keys { payload.removeValue(forKey: key) }
        object[payloadKey] = payload
        return try TokenTransferMessage.decode(from: JSONSerialization.data(withJSONObject: object))
    }

    private func payloadKey(of message: TokenTransferMessage, containing field: String) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: message.encode()) as? [String: Any])
        return try XCTUnwrap(object.first { ($0.value as? [String: Any])?[field] != nil }?.key)
    }

    private func queueState(sourceTitle: String?, sourceKind: String? = "playlist") -> QueueStatePayload {
        QueueStatePayload.create(
            tracks: [QueueTrack(id: "1", title: "One", artist: "A", artworkURL: nil, duration: 200)],
            currentIndex: 0,
            isPlaying: true,
            revision: 4,
            sourceTitle: sourceTitle,
            sourceKind: sourceKind,
            sessionId: credentials.sessionId,
            secret: credentials.secret
        )
    }

    private func playbackState(volume: Double?) -> PlaybackStatePayload {
        PlaybackStatePayload.create(
            isPlaying: true,
            positionSeconds: 12,
            durationSeconds: 300,
            trackId: "1",
            title: "One",
            artist: "A",
            artworkURL: nil,
            isDJEngineLive: false,
            volume: volume,
            revision: 3,
            sessionId: credentials.sessionId,
            secret: credentials.secret
        )
    }

    // MARK: - Companion

    func testQueueStateCarriesItsSourceAndStillVerifies() throws {
        let message = TokenTransferMessage.queueState(sessionId: credentials.sessionId, queue: queueState(sourceTitle: "Late Night Drive"))
        let queue = try XCTUnwrap(try roundTrip(message).queue)

        XCTAssertEqual(queue.sourceTitle, "Late Night Drive")
        XCTAssertEqual(queue.sourceKind, "playlist")
        XCTAssertTrue(queue.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testQueueStateFromAnOlderTVDecodesWithoutASource() throws {
        let message = TokenTransferMessage.queueState(sessionId: credentials.sessionId, queue: queueState(sourceTitle: "Mix"))
        let key = try payloadKey(of: message, containing: "sourceTitle")
        let legacy = try strippingKeys(["sourceTitle", "sourceKind"], under: key, of: message)
        let queue = try XCTUnwrap(legacy.queue)

        XCTAssertNil(queue.sourceTitle)
        XCTAssertNil(queue.sourceKind)
        XCTAssertTrue(queue.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testQueueStateCarriesThePlayingNextCountAndStillVerifies() throws {
        let payload = QueueStatePayload.create(
            tracks: (1...4).map { QueueTrack(id: "\($0)", title: "T\($0)", artist: "A", artworkURL: nil, duration: 200) },
            currentIndex: 0, isPlaying: true, revision: 5, playingNextCount: 2,
            sessionId: credentials.sessionId, secret: credentials.secret
        )
        let message = TokenTransferMessage.queueState(sessionId: credentials.sessionId, queue: payload)
        let queue = try XCTUnwrap(try roundTrip(message).queue)
        XCTAssertEqual(queue.playingNextCount, 2)
        XCTAssertTrue(queue.verify(sessionId: credentials.sessionId, secret: credentials.secret))

        let key = try payloadKey(of: message, containing: "playingNextCount")
        let legacy = try XCTUnwrap(try strippingKeys(["playingNextCount"], under: key, of: message).queue)
        XCTAssertNil(legacy.playingNextCount)
        XCTAssertTrue(legacy.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testRemotePlayingNextCountFollowsThePresentedTrack() {
        let tracks = (1...6).map { QueueTrack(id: "\($0)", title: "T\($0)", artist: "A", artworkURL: nil, duration: 200) }
        XCTAssertEqual(RemoteQueueProjection.playingNextCount(2, tracks: tracks, currentIndex: 1, presentedTrackId: "2"), 2)
        XCTAssertEqual(RemoteQueueProjection.playingNextCount(2, tracks: tracks, currentIndex: 1, presentedTrackId: "3"), 1)
        XCTAssertEqual(RemoteQueueProjection.playingNextCount(1, tracks: tracks, currentIndex: 1, presentedTrackId: "4"), 0)
        XCTAssertEqual(RemoteQueueProjection.playingNextCount(2, tracks: tracks, currentIndex: 1, presentedTrackId: "1"), 0)

        let layout = UpNextLayout.make(upcomingCount: 4, playingNextCount: 2, autoMixOn: true)
        XCTAssertEqual(layout.playingNext, 0..<2)
        XCTAssertNil(layout.autoMixPick)
        XCTAssertEqual(layout.continuePlaying, 2..<4)
        XCTAssertEqual(UpNextLayout.make(upcomingCount: 4, playingNextCount: 0, autoMixOn: true).autoMixPick, 0)
    }

    func testEmptySourceTitlesAreDropped() {
        let queue = queueState(sourceTitle: "", sourceKind: "album")
        XCTAssertNil(queue.sourceTitle)
        XCTAssertNil(queue.sourceKind)
    }

    func testQueueLoadCarriesTheSourceToTheTV() throws {
        let signer = CompanionCommandSigner(sessionId: credentials.sessionId, secret: credentials.secret)
        let message = signer.load(
            trackIds: ["1", "2", "3"], startIndex: 1, positionSeconds: 40, autoplay: true,
            sourceTitle: "Wavelength", sourceKind: "album"
        )
        let load = try XCTUnwrap(try roundTrip(message).queueLoad)

        XCTAssertEqual(load.sourceTitle, "Wavelength")
        XCTAssertEqual(load.sourceKind, "album")
        XCTAssertTrue(load.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testPlaybackStateCarriesVolumeAndStillVerifies() throws {
        let message = TokenTransferMessage.playbackState(sessionId: credentials.sessionId, playback: playbackState(volume: 0.4))
        let playback = try XCTUnwrap(try roundTrip(message).playback)

        XCTAssertEqual(try XCTUnwrap(playback.effectiveVolume), 0.4, accuracy: 0.0001)
        XCTAssertTrue(playback.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testPlaybackStateVolumeIsClamped() {
        XCTAssertEqual(playbackState(volume: 1.7).effectiveVolume, 1)
        XCTAssertEqual(playbackState(volume: -0.2).effectiveVolume, 0)
        XCTAssertNil(playbackState(volume: nil).effectiveVolume)
    }

    func testPlaybackStateFromAnOlderTVHasNoVolume() throws {
        let message = TokenTransferMessage.playbackState(sessionId: credentials.sessionId, playback: playbackState(volume: 0.5))
        let key = try payloadKey(of: message, containing: "volume")
        let legacy = try strippingKeys(["volume"], under: key, of: message)
        let playback = try XCTUnwrap(legacy.playback)

        XCTAssertNil(playback.effectiveVolume)
        XCTAssertTrue(playback.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testVolumeIsASignedContinuousControl() throws {
        XCTAssertTrue(MessageType.transportVolume.isControlCommand)
        XCTAssertTrue(MessageType.transportVolume.isContinuousControl)
        XCTAssertFalse(MessageType.transportVolume.isQueueCommand)

        let signer = CompanionCommandSigner(sessionId: credentials.sessionId, secret: credentials.secret)
        let message = signer.control(.transportVolume, value: 0.35, sequence: 9)
        let decoded = try roundTrip(message)
        let control = try XCTUnwrap(decoded.control)

        XCTAssertEqual(decoded.type, .transportVolume)
        XCTAssertEqual(control.value, 0.35, accuracy: 0.0001)
        XCTAssertTrue(control.verify(type: .transportVolume, sessionId: credentials.sessionId, secret: credentials.secret))
        XCTAssertFalse(control.verify(type: .transportSeek, sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testVolumeSequenceGateDropsStaleCrownTurns() {
        var gate = SequenceGate()
        XCTAssertTrue(gate.admit(3, type: .transportVolume, deck: .none))
        XCTAssertFalse(gate.admit(2, type: .transportVolume, deck: .none))
        XCTAssertTrue(gate.admit(4, type: .transportVolume, deck: .none))
        XCTAssertTrue(gate.admit(1, type: .djCrossfader, deck: .none))
    }

    // MARK: - Watch link

    private func encodedJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try XCTUnwrap(WatchLinkCodec.encode(value))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try XCTUnwrap(WatchLinkCodec.decode(type, from: JSONSerialization.data(withJSONObject: object)))
    }

    private var namedNowPlaying: WatchNowPlaying {
        var value = WatchNowPlaying.idle
        value.trackId = "1"
        value.output = .tv
        value.outputId = "linked.living"
        value.outputName = "Living Room"
        value.outputs = [
            WatchOutputOption(id: WatchOutputOption.thisPhoneID, name: "iPhone", deviceClass: .phone),
            WatchOutputOption(id: "linked.living", name: "Living Room", deviceClass: .tv),
            WatchOutputOption(id: "linked.bedroom", name: "Bedroom", deviceClass: .tv, isAvailable: false),
        ]
        value.volume = 0.6
        return value
    }

    func testWatchNowPlayingRoundTripsNamedOutputsAndVolume() throws {
        let original = namedNowPlaying
        let decoded = try XCTUnwrap(WatchLinkCodec.decode(WatchNowPlaying.self, from: XCTUnwrap(WatchLinkCodec.encode(original))))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.displayOutputName, "Living Room")
        XCTAssertTrue(decoded.isRemoteOutput)
        XCTAssertEqual(decoded.outputOptions.map(\.name), ["iPhone", "Living Room", "Bedroom"])
        XCTAssertEqual(decoded.outputOptions.filter(decoded.isSelected).map(\.id), ["linked.living"])
        XCTAssertEqual(decoded.clampedVolume, 0.6)
    }

    func testTwoTVsOfTheSameClassAreToldApartByID() {
        var value = namedNowPlaying
        value.outputId = "linked.bedroom"
        value.outputName = "Bedroom"
        XCTAssertEqual(value.outputOptions.filter(value.isSelected).map(\.name), ["Bedroom"])
    }

    func testWatchNowPlayingFromAnOlderPhoneFallsBackToDeviceClasses() throws {
        var object = try encodedJSON(namedNowPlaying)
        for key in ["outputId", "outputName", "outputs", "volume"] { object.removeValue(forKey: key) }
        let legacy = try decodeJSON(WatchNowPlaying.self, object)

        XCTAssertNil(legacy.clampedVolume)
        XCTAssertEqual(legacy.displayOutputName, DeviceClass.tv.displayName)
        XCTAssertTrue(legacy.isRemoteOutput)
        XCTAssertEqual(legacy.outputOptions.map(\.deviceClass), [.phone, .tv])
        XCTAssertEqual(legacy.outputOptions.filter(legacy.isSelected).map(\.deviceClass), [.tv])
    }

    func testLocalOutputIsNotRemote() {
        var value = namedNowPlaying
        value.output = .phone
        value.outputId = WatchOutputOption.thisPhoneID
        XCTAssertFalse(value.isRemoteOutput)
        XCTAssertEqual(WatchOutputOption.thisPhoneID, OutputDevice.localID)
    }

    func testWatchCommandsCarryVolumeAndOutputID() throws {
        let volume = WatchCommand(kind: .volume, volume: 0.25)
        let decodedVolume = try XCTUnwrap(WatchLinkCodec.payload(WatchCommand.self, from: WatchLinkCodec.message(.volume, volume)))
        XCTAssertEqual(decodedVolume.kind, .volume)
        XCTAssertEqual(decodedVolume.volume, 0.25)

        let output = WatchCommand(kind: .output, output: .tv, outputId: "linked.bedroom")
        let message = WatchLinkCodec.message(.output, output)
        XCTAssertEqual(WatchLinkCodec.kind(of: message), .output)
        let decodedOutput = try XCTUnwrap(WatchLinkCodec.payload(WatchCommand.self, from: message))
        XCTAssertEqual(decodedOutput.outputId, "linked.bedroom")
        XCTAssertEqual(decodedOutput.output, .tv)
    }

    func testWatchQueueSnapshotCarriesItsSource() throws {
        let snapshot = WatchQueueSnapshot(
            items: [WatchQueueItem(index: 1, trackId: "q1", title: "Next", artist: "A", artworkURL: nil)],
            updatedAtMillis: 5,
            sourceTitle: "Likes"
        )
        let decoded = try XCTUnwrap(WatchLinkCodec.decode(WatchQueueSnapshot.self, from: XCTUnwrap(WatchLinkCodec.encode(snapshot))))
        XCTAssertEqual(decoded, snapshot)

        var object = try encodedJSON(snapshot)
        object.removeValue(forKey: "sourceTitle")
        XCTAssertNil(try decodeJSON(WatchQueueSnapshot.self, object).sourceTitle)
    }

    func testPendingWatchVolumeSettlesOnEchoOrAfterTheHold() {
        let start = Date()
        XCTAssertFalse(WatchVolumeThrottle.settles(pending: 0.5, reported: 0.8, since: start, now: start.addingTimeInterval(0.5)))
        XCTAssertFalse(WatchVolumeThrottle.settles(pending: 0.5, reported: nil, since: start, now: start.addingTimeInterval(0.5)))
        XCTAssertTrue(WatchVolumeThrottle.settles(pending: 0.5, reported: 0.51, since: start, now: start.addingTimeInterval(0.5)))
        XCTAssertTrue(WatchVolumeThrottle.settles(pending: 0.5, reported: 0.8, since: start, now: start.addingTimeInterval(WatchVolumeThrottle.holdLimit)))
    }

    // MARK: - Player

    @MainActor
    func testAppVolumeIsClampedAndRemembered() throws {
        XCTAssertEqual(PlayerService.clampedVolume(1.4), 1)
        XCTAssertEqual(PlayerService.clampedVolume(-1), 0)
        XCTAssertEqual(PlayerService.clampedVolume(.nan), 1)

        let suite = "RemoteVolumeAndSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PlayerService.storedVolume(defaults), 1)
        defaults.set(0.3, forKey: PlayerService.volumeDefaultsKey)
        XCTAssertEqual(PlayerService.storedVolume(defaults), 0.3)
        defaults.set(7, forKey: PlayerService.volumeDefaultsKey)
        XCTAssertEqual(PlayerService.storedVolume(defaults), 1)
    }

    @MainActor
    func testQueueSourceDirectoryResolvesLikesAndNotedCollections() throws {
        PlaybackQueueSourceDirectory.reset()
        defer { PlaybackQueueSourceDirectory.reset() }

        XCTAssertEqual(PlaybackQueueSourceDirectory.source(for: CollectionPolicyID.likedTracks), .likes)
        XCTAssertNil(PlaybackQueueSourceDirectory.source(for: nil))

        let album = try XCTUnwrap(VisualFixtures.albums.first)
        let playlist = try XCTUnwrap(VisualFixtures.playlists.first)
        XCTAssertNil(PlaybackQueueSourceDirectory.source(for: album.id))

        PlaybackQueueSourceDirectory.note(album)
        PlaybackQueueSourceDirectory.note(playlist)
        XCTAssertEqual(PlaybackQueueSourceDirectory.source(for: album.id), PlaybackQueueSource(id: album.id, kind: .album, title: album.title))
        XCTAssertEqual(PlaybackQueueSourceDirectory.source(for: playlist.id)?.kind, .playlist)

        PlaybackQueueSourceDirectory.note(PlaybackQueueSource(id: "empty", kind: .playlist, title: ""))
        XCTAssertNil(PlaybackQueueSourceDirectory.source(for: "empty"))
    }

    func testSavedSessionsWithoutASourceStillRestore() throws {
        let snapshot = PlaybackStateStore.Snapshot(
            trackIds: ["1"], currentIndex: 0, positionSeconds: 3, isShuffleEnabled: false,
            repeatMode: .off, collectionId: "42",
            queueSource: PlaybackQueueSource(id: "42", kind: .station, title: "Deep House Station"),
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackStateStore.Snapshot.self, from: data), snapshot)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "queueSource")
        let legacy = try JSONDecoder().decode(PlaybackStateStore.Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.queueSource)
        XCTAssertEqual(legacy.collectionId, "42")
    }
}
