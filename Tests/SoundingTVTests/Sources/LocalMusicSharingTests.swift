import CloudKit
import Foundation
import Network
import XCTest
@testable import SoundingTV

final class LocalMusicSharingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sessionId = "LOCALMUSICTESTSESSION"
    private let secret = Data((0..<32).map { UInt8($0) })

    // MARK: - Grants

    func testGrantProofVerifiesOnlyWithTheSameGrant() throws {
        let grant = LocalMusicGrant.issue(now: now)
        let other = LocalMusicGrant.issue(now: now)
        let credential = try XCTUnwrap(grant.credential)
        let forged = try XCTUnwrap(PeerContentAccountCredential.grant(id: grant.id, key: other.key))

        let proof = PeerContentAccountProof.make(
            requestId: "r1", trackId: "local/audio/-1", offset: 0, length: 64, credential: credential, now: now
        )
        XCTAssertTrue(credential.isGrant)
        XCTAssertEqual(PeerContentAccountCredential.grantId(fromAccountId: proof.accountId), grant.id)
        XCTAssertTrue(proof.isValid(requestId: "r1", trackId: "local/audio/-1", offset: 0, length: 64, credential: credential, now: now))
        XCTAssertFalse(proof.isValid(requestId: "r1", trackId: "local/audio/-1", offset: 0, length: 64, credential: forged, now: now))
        XCTAssertFalse(proof.isValid(requestId: "r1", trackId: "local/audio/-2", offset: 0, length: 64, credential: credential, now: now))
        XCTAssertFalse(proof.isValid(requestId: "r1", trackId: "local/audio/-1", offset: 1, length: 64, credential: credential, now: now))
    }

    func testGrantExpires() {
        let grant = LocalMusicGrant.issue(now: now)
        XCTAssertTrue(grant.isValid(at: now.addingTimeInterval(LocalMusicGrant.lifetime - 1)))
        XCTAssertFalse(grant.isValid(at: now.addingTimeInterval(LocalMusicGrant.lifetime)))
        XCTAssertNil(PeerContentAccountCredential.grant(id: "", key: grant.key))
        XCTAssertNil(PeerContentAccountCredential.grant(id: "x", key: Data([1, 2, 3])))
        XCTAssertNil(PeerContentAccountCredential.grantId(fromAccountId: "grant:"))
        XCTAssertNil(PeerContentAccountCredential.grantId(fromAccountId: "account-a"))
    }

    @MainActor
    func testHostHonoursOnlyLiveGrantsItIssued() throws {
        let host = LocalMusicShareHost()
        let offer = host.offer(now: now)
        XCTAssertNotNil(host.credential(forGrantId: offer.grant.id, now: now))
        XCTAssertNil(host.credential(forGrantId: offer.grant.id, now: now.addingTimeInterval(LocalMusicGrant.lifetime + 1)))
        XCTAssertNil(host.credential(forGrantId: UUID().uuidString, now: now))
        for _ in 0..<LocalMusicShareHost.maximumGrants { _ = host.offer(now: now.addingTimeInterval(1)) }
        XCTAssertNil(host.credential(forGrantId: offer.grant.id, now: now), "oldest grant is retired")
        let latest = host.offer(now: now)
        host.revokeAll()
        XCTAssertNil(host.credential(forGrantId: latest.grant.id, now: now))
    }

    // MARK: - Offer payload

    func testOfferPayloadIsSignedWithTheLinkSecret() throws {
        let offer = LocalMusicOffer(
            contentDeviceId: "device", name: "Studio Mac", deviceClass: .mac,
            grant: .issue(now: now), catalogRevision: "abc", trackCount: 3, servesInBackground: true
        )
        let body = try XCTUnwrap(offer.encoded())
        let payload = LocalMusicOfferPayload.create(body: body, sessionId: sessionId, secret: secret, now: now)
        XCTAssertTrue(payload.verify(sessionId: sessionId, secret: secret))
        XCTAssertFalse(payload.verify(sessionId: "other", secret: secret))
        XCTAssertFalse(payload.verify(sessionId: sessionId, secret: Data(repeating: 9, count: 32)))
        let tampered = LocalMusicOfferPayload(body: body + Data([0]), issuedAtMillis: payload.issuedAtMillis, nonce: payload.nonce, signature: payload.signature)
        XCTAssertFalse(tampered.verify(sessionId: sessionId, secret: secret))
        XCTAssertTrue(payload.isFresh(now: now))
        XCTAssertFalse(payload.isFresh(now: now.addingTimeInterval(BonjourConstants.commandFreshnessWindow + 1)))
        XCTAssertEqual(LocalMusicOffer.decode(payload.body), offer)

        let message = TokenTransferMessage.localMusicOffer(sessionId: sessionId, payload: payload)
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.type, .localMusicOffer)
        XCTAssertEqual(decoded.localMusicOffer, payload)
    }

    func testResourcePaths() {
        for resource in [LocalMusicResource.catalog, .audio("-12"), .artwork("-12"), .analysis("-12")] {
            XCTAssertEqual(LocalMusicResource(path: resource.path), resource)
        }
        for junk in ["catalog", "local", "local/audio", "local/audio/", "local/audio/-1/extra", "local/other/-1", "-12345"] {
            XCTAssertNil(LocalMusicResource(path: junk), junk)
        }
    }

    @MainActor
    func testRemoteTrackMapsBackToItsDevice() throws {
        let entry = LocalMusicCatalogTrack(
            id: "-42", title: "Open Water", artist: "Low Sun", album: nil, genre: "Techno", duration: 300,
            modifiedAt: now, fileExtension: "flac", fileSize: 1, hasArtwork: false
        )
        let device = RemoteLocalMusic.Device(
            id: "device-a", sessionId: "s", name: "Studio Mac", deviceClass: .mac, servesInBackground: true, catalog: nil
        )
        let track = try XCTUnwrap(RemoteLocalMusic.makeTrack(entry, device: device))
        let file = try XCTUnwrap(track.localFile)
        XCTAssertEqual(track.id, "-42")
        XCTAssertTrue(track.isLocal)
        XCTAssertNotNil(track.streamURL)
        XCTAssertEqual(track.duration, 300)
        XCTAssertTrue(RemoteLocalMusic.isRemote(file))
        XCTAssertEqual(RemoteLocalMusic.deviceId(of: file), "device-a")
        XCTAssertEqual(RemoteLocalMusic.audioURL(for: file)?.lastPathComponent, "-42.flac")
        XCTAssertFalse(RemoteLocalMusic.isRemote(LocalTrackFile(folderID: "folder", relativePath: "a.mp3")))
        XCTAssertEqual(device.sourceLabel, "On Studio Mac")
    }

    func testCloudRecordRoundTrip() throws {
        let track = LocalMusicCatalogTrack(
            id: "-99", title: "Late Bus", artist: "Juno Vale", album: "Night", genre: "Breaks", duration: 297,
            modifiedAt: now, fileExtension: "m4a", fileSize: 8_000_000, hasArtwork: false,
            bpm: 128, keyWheelPosition: 8, keyMode: 0
        )
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let record = LocalMusicCloudSchema.record(for: track, audio: audio, artwork: nil, deviceId: "device-a", deviceName: "Studio Mac")
        XCTAssertEqual(record.recordType, "LocalTrackAsset")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "LocalMusic")
        XCTAssertEqual(record.recordID.recordName, "track-99")
        XCTAssertNotNil(record[LocalMusicCloudSchema.Field.audio] as? CKAsset)
        XCTAssertEqual(LocalMusicCloudSchema.catalogTrack(from: record), track)
    }

    // MARK: - Range serving

    @MainActor
    func testServesRangesToAGrantHolderOnly() async throws {
        let audio = Data((0..<(5 * 1024 * 1024 + 321)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let grant = LocalMusicGrant.issue()
        let expired = LocalMusicGrant.issue()
        let source = LocalMusicDataSource(audio)
        let server = PeerContentServer(resolveFile: { _ in source }, accountCredential: { nil })
        server.serveGrants(
            credential: { $0 == grant.id ? grant.credential : nil },
            resolve: { path in LocalMusicResource(path: path) == .audio("-7") ? source : nil }
        )
        try server.start(sessionId: sessionId, secret: secret)
        defer { server.stop() }
        let port = try await waitForPort(server)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        let client = PeerContentClient(accountCredential: try XCTUnwrap(grant.credential))
        try await client.connect(to: endpoint, sessionId: sessionId, secret: secret, timeout: 5)
        defer { client.disconnect() }

        let path = LocalMusicResource.audio("-7").path
        let range = try await client.fetchRange(trackId: path, offset: 1_000, length: 4_096, timeout: 5)
        XCTAssertEqual(range.totalLength, Int64(audio.count))
        XCTAssertEqual(range.data, audio.subdata(in: 1_000..<5_096))

        let tail = try await client.fetchRange(trackId: path, offset: Int64(audio.count - 10), length: 4_096, timeout: 5)
        XCTAssertEqual(tail.data, audio.suffix(10))

        let past = try await client.fetchRange(trackId: path, offset: Int64(audio.count + 5), length: 16, timeout: 5)
        XCTAssertTrue(past.data.isEmpty)

        let whole = try await LocalMusicTransfer.fetchData(path, using: client)
        XCTAssertEqual(whole, audio)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: file) }
        try await LocalMusicTransfer.fetchFile(path, using: client, to: file)
        XCTAssertEqual(try Data(contentsOf: file), audio)

        await assertFails(.notFound) {
            _ = try await client.fetchRange(trackId: LocalMusicResource.audio("-8").path, offset: 0, length: 16, timeout: 5)
        }

        let stale = PeerContentClient(accountCredential: try XCTUnwrap(expired.credential))
        try await stale.connect(to: endpoint, sessionId: sessionId, secret: secret, timeout: 5)
        defer { stale.disconnect() }
        await assertFails(.notEntitled) {
            _ = try await stale.fetchRange(trackId: path, offset: 0, length: 16, timeout: 5)
        }

        let forged = PeerContentClient(accountCredential: try XCTUnwrap(PeerContentAccountCredential.grant(id: grant.id, key: expired.key)))
        try await forged.connect(to: endpoint, sessionId: sessionId, secret: secret, timeout: 5)
        defer { forged.disconnect() }
        await assertFails(.notEntitled) {
            _ = try await forged.fetchRange(trackId: path, offset: 0, length: 16, timeout: 5)
        }

        let account = PeerContentClient(accountCredential: try XCTUnwrap(PeerContentAccountCredential.derive(accountId: "a", accessToken: "t")))
        try await account.connect(to: endpoint, sessionId: sessionId, secret: secret, timeout: 5)
        defer { account.disconnect() }
        await assertFails(.notEntitled) {
            _ = try await account.fetchRange(trackId: path, offset: 0, length: 16, timeout: 5)
        }
    }

    @MainActor
    func testRefusesAConnectionWithoutTheLinkSecret() async throws {
        let grant = LocalMusicGrant.issue()
        let server = PeerContentServer(resolveFile: { _ in nil }, accountCredential: { nil })
        server.serveGrants(credential: { _ in grant.credential }, resolve: { _ in LocalMusicDataSource(Data([1])) })
        try server.start(sessionId: sessionId, secret: secret)
        defer { server.stop() }
        let port = try await waitForPort(server)
        let client = PeerContentClient(accountCredential: try XCTUnwrap(grant.credential))
        defer { client.disconnect() }
        do {
            try await client.connect(
                to: .hostPort(host: "127.0.0.1", port: port), sessionId: sessionId,
                secret: Data(repeating: 7, count: 32), timeout: 3
            )
            _ = try await client.fetchRange(trackId: LocalMusicResource.catalog.path, offset: 0, length: 1, timeout: 3)
            XCTFail("an unlinked device read content")
        } catch {}
    }

    // MARK: - Helpers

    @MainActor
    private func waitForPort(_ server: PeerContentServer) async throws -> NWEndpoint.Port {
        for _ in 0..<60 {
            if let port = server.boundPort, port.rawValue != 0 { return port }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("listener did not bind")
    }

    @MainActor
    private func assertFails(_ expected: PeerContentError, _ body: () async throws -> Void, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected)", line: line)
        } catch let error as PeerContentError {
            XCTAssertEqual(error, expected, line: line)
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
    }
}
