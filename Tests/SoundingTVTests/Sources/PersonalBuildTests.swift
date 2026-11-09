#if SOUNDING_PERSONAL
import AVFoundation
import XCTest

final class PersonalCodeLockTests: XCTestCase {
    private static let vectorSetting = "00112233445566778899aabbccddeeff:d7043b0483ea284dc63a7e475e9ae5c0860c7242c58320517a76719952f69203"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PersonalCodeLockTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSharedVectorMatchesHashScript() throws {
        let digest = try XCTUnwrap(PersonalCodeDigest(setting: Self.vectorSetting))
        XCTAssertTrue(digest.matches("patch in"))
        XCTAssertTrue(digest.matches("  Patch In \n"))
        XCTAssertFalse(digest.matches("patch out"))
        XCTAssertFalse(digest.matches(""))
        XCTAssertEqual(digest.setting, Self.vectorSetting)
    }

    func testDigestRoundTripsAndSaltMatters() throws {
        let salt = Data((0 ..< 16).map { UInt8($0) })
        let digest = PersonalCodeDigest(code: "Crate Digger", salt: salt)
        let parsed = try XCTUnwrap(PersonalCodeDigest(setting: digest.setting))
        XCTAssertEqual(parsed, digest)
        XCTAssertTrue(parsed.matches("crate digger"))
        let otherSalt = PersonalCodeDigest(code: "Crate Digger", salt: Data(repeating: 7, count: 16))
        XCTAssertNotEqual(otherSalt.hash, digest.hash)
        XCTAssertFalse(digest.setting.contains("crate"))
    }

    func testMalformedSettingsAreRejected() {
        XCTAssertNil(PersonalCodeDigest(setting: ""))
        XCTAssertNil(PersonalCodeDigest(setting: "$(SOUNDING_PERSONAL_CODE_HASH)"))
        XCTAssertNil(PersonalCodeDigest(setting: "0011:abcd"))
        XCTAssertNil(PersonalCodeDigest(setting: "00112233445566778899aabbccddeeff"))
        XCTAssertNil(PersonalCodeDigest(setting: "zz112233445566778899aabbccddeeff:d7043b0483ea284dc63a7e475e9ae5c0860c7242c58320517a76719952f69203"))
        XCTAssertNil(PersonalCodeDigest(setting: "00112233445566778899aabbccddeeff:d7043b04"))
    }

    func testUnlockPersistsAndLockClears() throws {
        let lock = PersonalCodeLock(digest: PersonalCodeDigest(setting: Self.vectorSetting), defaults: defaults)
        XCTAssertTrue(lock.isConfigured)
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertFalse(lock.unlock(with: "wrong"))
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertTrue(lock.unlock(with: "PATCH IN"))
        XCTAssertTrue(lock.isUnlocked)

        let reopened = PersonalCodeLock(digest: PersonalCodeDigest(setting: Self.vectorSetting), defaults: defaults)
        XCTAssertTrue(reopened.isUnlocked)
        let stored = try XCTUnwrap(defaults.string(forKey: PersonalCodeLock.unlockedDefaultsKey))
        XCTAssertFalse(stored.localizedCaseInsensitiveContains("patch"))

        reopened.lock()
        XCTAssertFalse(lock.isUnlocked)
    }

    func testChangingTheCodeRelocks() {
        let old = PersonalCodeLock(digest: PersonalCodeDigest(setting: Self.vectorSetting), defaults: defaults)
        XCTAssertTrue(old.unlock(with: "patch in"))
        let rotated = PersonalCodeLock(digest: PersonalCodeDigest(code: "new code", salt: Data(repeating: 1, count: 16)), defaults: defaults)
        XCTAssertFalse(rotated.isUnlocked)
    }

    func testUnconfiguredBuildNeverUnlocks() {
        let lock = PersonalCodeLock(digest: nil, defaults: defaults)
        XCTAssertFalse(lock.isConfigured)
        XCTAssertFalse(lock.unlock(with: "patch in"))
        defaults.set("anything", forKey: PersonalCodeLock.unlockedDefaultsKey)
        XCTAssertFalse(lock.isUnlocked)
    }

    func testMarkerNameIsTheOneTheReleaseScriptLooksFor() {
        XCTAssertEqual(SoundingPersonalMarker.name, "SoundingPersonalMarker")
        XCTAssertEqual(PersonalCodeLock.infoPlistKey, "SoundingPersonalCodeHash")
        XCTAssertTrue(PersonalCodeLock.unlockedDefaultsKey.hasPrefix(SoundingPersonalMarker.name))
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var slept: [TimeInterval] = []

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { slept } }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            slept.append(seconds)
            current = current.addingTimeInterval(seconds)
        }
    }
}

private actor CallLog {
    private(set) var events: [String] = []
    private(set) var calls: [String: Int] = [:]

    func record(_ event: String) { events.append(event) }
    func call(_ key: String) { calls[key, default: 0] += 1 }
}

private struct FakeFetchError: Error {}

final class PersonalFetchQueueTests: XCTestCase {
    private func makeQueue(
        clock: FakeClock,
        policy: PersonalFetchPolicy = PersonalFetchPolicy(spacing: 10, jitterFraction: 0, failureBackoff: 60, maximumBackoff: 600, maximumConsecutiveFailures: 3),
        pausedUntil: @escaping PersonalFetchQueue.PausedUntil = { nil }
    ) -> PersonalFetchQueue {
        PersonalFetchQueue(
            policy: policy,
            now: { clock.now },
            sleep: { seconds in clock.sleep(seconds) },
            pausedUntil: pausedUntil,
            jitter: { 0 }
        )
    }

    func testRunsOneAtATimeWithSpacing() async throws {
        let clock = FakeClock()
        let queue = makeQueue(clock: clock)
        let log = CallLog()
        async let a = queue.file(for: "a") {
            await log.record("start a")
            try await Task.sleep(for: .milliseconds(30))
            await log.record("end a")
            return URL(fileURLWithPath: "/tmp/a.mp3")
        }
        try await Task.sleep(for: .milliseconds(5))
        async let b = queue.file(for: "b") {
            await log.record("start b")
            await log.record("end b")
            return URL(fileURLWithPath: "/tmp/b.mp3")
        }
        let results = try await [a, b]
        XCTAssertEqual(results.map(\.lastPathComponent), ["a.mp3", "b.mp3"])
        let events = await log.events
        XCTAssertEqual(events, ["start a", "end a", "start b", "end b"])
        XCTAssertEqual(clock.sleeps, [10])
    }

    func testCoalescesTheSameTrack() async throws {
        let clock = FakeClock()
        let queue = makeQueue(clock: clock)
        let log = CallLog()
        let operation: PersonalFetchQueue.Operation = {
            await log.call("a")
            try await Task.sleep(for: .milliseconds(30))
            return URL(fileURLWithPath: "/tmp/a.mp3")
        }
        async let first = queue.file(for: "a", operation: operation)
        try await Task.sleep(for: .milliseconds(5))
        async let second = queue.file(for: "a", operation: operation)
        let results = try await [first, second]
        XCTAssertEqual(results[0], results[1])
        let calls = await log.calls["a"]
        XCTAssertEqual(calls, 1)
    }

    func testBacksOffAndStopsAfterRepeatedFailures() async throws {
        let clock = FakeClock()
        let queue = makeQueue(clock: clock)
        for key in ["a", "b", "c"] {
            do {
                _ = try await queue.file(for: key) { throw FakeFetchError() }
                XCTFail("expected failure")
            } catch is FakeFetchError {
            }
        }
        XCTAssertEqual(clock.sleeps, [60, 120])
        do {
            _ = try await queue.file(for: "d") { URL(fileURLWithPath: "/tmp/d.mp3") }
            XCTFail("expected the queue to stop")
        } catch let error as PersonalFetchError {
            XCTAssertEqual(error, .stoppedAfterFailures(3))
        }
        let started = await queue.startedKeys
        XCTAssertEqual(started, ["a", "b", "c"])

        clock.sleep(600)
        let url = try await queue.file(for: "d") { URL(fileURLWithPath: "/tmp/d.mp3") }
        XCTAssertEqual(url.lastPathComponent, "d.mp3")
        let restarted = await queue.startedKeys
        XCTAssertEqual(restarted, ["a", "b", "c", "d"])
    }

    func testExplicitResetRetriesStraightAway() async throws {
        let clock = FakeClock()
        let queue = makeQueue(clock: clock, policy: PersonalFetchPolicy(spacing: 0, jitterFraction: 0, failureBackoff: 1, maximumBackoff: 600, maximumConsecutiveFailures: 1))
        _ = try? await queue.file(for: "a") { throw FakeFetchError() }
        await queue.resetFailures()
        let url = try await queue.file(for: "b") { URL(fileURLWithPath: "/tmp/b.mp3") }
        XCTAssertEqual(url.lastPathComponent, "b.mp3")
    }

    func testWaitsOutASoundCloudPause() async throws {
        let clock = FakeClock()
        let resume = clock.now.addingTimeInterval(900)
        let queue = makeQueue(clock: clock, pausedUntil: { clock.now < resume ? resume : nil })
        let url = try await queue.file(for: "a") { URL(fileURLWithPath: "/tmp/a.mp3") }
        XCTAssertEqual(url.lastPathComponent, "a.mp3")
        XCTAssertEqual(clock.sleeps, [900])
    }

    func testJitterStaysWithinTheSpread() async throws {
        let clock = FakeClock()
        let queue = PersonalFetchQueue(
            policy: PersonalFetchPolicy(spacing: 8, jitterFraction: 0.25),
            now: { clock.now },
            sleep: { clock.sleep($0) },
            jitter: { 5 }
        )
        _ = try await queue.file(for: "a") { URL(fileURLWithPath: "/tmp/a.mp3") }
        _ = try await queue.file(for: "b") { URL(fileURLWithPath: "/tmp/b.mp3") }
        XCTAssertEqual(clock.sleeps, [10])
    }
}

final class PersonalAudioTaggerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "PersonalAudioTaggerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func frames(in tag: Data) -> [String: Data] {
        let bytes = [UInt8](tag)
        var result: [String: Data] = [:]
        var offset = 10
        while offset + 10 <= bytes.count {
            let id = String(bytes: bytes[offset ..< offset + 4], encoding: .ascii) ?? ""
            let size = Int(bytes[offset + 4]) << 24 | Int(bytes[offset + 5]) << 16 | Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
            guard size > 0, offset + 10 + size <= bytes.count else { break }
            result[id] = Data(bytes[offset + 10 ..< offset + 10 + size])
            offset += 10 + size
        }
        return result
    }

    func testID3TagCarriesTitleArtistISRCAndArtwork() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])
        let tags = PersonalAudioTags(title: "Sunrise", artist: "Bicep", genre: "Electronic", isrc: "GBCFB2000001", year: 2020, artworkJPEG: jpeg)
        let tag = PersonalAudioTagger.id3v2Tag(tags)
        XCTAssertEqual(Array(tag.prefix(4)), Array("ID3".utf8) + [0x03])
        XCTAssertEqual(PersonalAudioTagger.existingID3v2Length(tag), tag.count)

        let found = frames(in: tag)
        XCTAssertEqual(found["TIT2"], Data([0x00]) + Data("Sunrise".utf8))
        XCTAssertEqual(found["TPE1"], Data([0x00]) + Data("Bicep".utf8))
        XCTAssertEqual(found["TSRC"], Data([0x00]) + Data("GBCFB2000001".utf8))
        XCTAssertEqual(found["TYER"], Data([0x00]) + Data("2020".utf8))
        XCTAssertNil(found["TALB"])
        let picture = try? XCTUnwrap(found["APIC"])
        XCTAssertEqual(picture?.suffix(jpeg.count), jpeg)
    }

    func testNonLatinTextUsesUTF16() {
        let tag = PersonalAudioTagger.id3v2Tag(PersonalAudioTags(title: "東京", artist: "Ø"))
        let found = frames(in: tag)
        XCTAssertEqual(found["TIT2"], Data([0x01, 0xFF, 0xFE, 0x71, 0x67, 0xAC, 0x4E]))
        XCTAssertEqual(found["TPE1"], Data([0x00, 0xD8]))
    }

    func testWriteMP3ReplacesExistingTagsAndKeepsAudio() throws {
        let audio = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let oldTag = PersonalAudioTagger.id3v2Tag(PersonalAudioTags(title: "Old", artist: "Old"))
        let source = scratch.appending(path: "in.mp3")
        try (oldTag + oldTag + audio).write(to: source)
        let destination = scratch.appending(path: "out.mp3")

        try PersonalAudioTagger.writeMP3(PersonalAudioTags(title: "New", artist: "Artist"), from: source, to: destination)

        let written = try Data(contentsOf: destination)
        let length = PersonalAudioTagger.existingID3v2Length(written)
        XCTAssertGreaterThan(length, 0)
        XCTAssertEqual(written.suffix(from: length), audio)
        XCTAssertEqual(frames(in: written.prefix(length))["TIT2"], Data([0x00]) + Data("New".utf8))
        XCTAssertEqual(PersonalAudioTagger.existingID3v2Length(written.suffix(from: length)), 0)
    }

    func testOutputFormats() {
        XCTAssertEqual(PersonalAudioTagger.outputExtension(forSource: "MP3"), "mp3")
        XCTAssertEqual(PersonalAudioTagger.outputExtension(forSource: "aac"), "m4a")
        XCTAssertEqual(PersonalAudioTagger.outputExtension(forSource: "m4a"), "m4a")
        XCTAssertEqual(PersonalAudioTagger.outputExtension(forSource: "flac"), "flac")
        XCTAssertNil(PersonalAudioTagger.outputExtension(forSource: "ts"))
        XCTAssertNil(PersonalAudioTagger.outputExtension(forSource: "opus"))
    }

    func testMPEG4MetadataItems() {
        let items = PersonalAudioTagger.mpeg4Metadata(PersonalAudioTags(title: "Glue", artist: "Bicep", artworkJPEG: Data([0xFF, 0xD8])))
        let identifiers = Set(items.compactMap(\.identifier))
        XCTAssertEqual(identifiers, [.iTunesMetadataSongName, .iTunesMetadataArtist, .iTunesMetadataCoverArt])
    }

    func testUnsupportedSourceIsRejected() async {
        let source = scratch.appending(path: "in.ts")
        try? Data([0x47]).write(to: source)
        do {
            try await PersonalAudioTagger.write(PersonalAudioTags(title: "a", artist: "b"), from: source, to: scratch.appending(path: "out.ts"))
            XCTFail("expected rejection")
        } catch let error as PersonalAudioTaggerError {
            XCTAssertEqual(error, .unsupportedFormat("ts"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
#endif
