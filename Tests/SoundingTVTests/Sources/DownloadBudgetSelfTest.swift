import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG
enum DownloadBudgetSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[DownloadBudgetTest] \(status)"] + lines.map { "[DownloadBudgetTest]   \($0)" }
                + failures.map { "[DownloadBudgetTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()
        let now = Date()

        func expect(_ name: String, _ entries: [DownloadBudgetPolicy.Entry], maxBytes: Int64, evicts expected: [String]) {
            let got = DownloadBudgetPolicy.victims(entries: entries, maxBytes: maxBytes)
            if got == expected {
                report.lines.append("\(name) → evicts \(expected)")
            } else {
                report.failures.append("\(name): expected \(expected), got \(got)")
            }
        }

        expect("under budget, nothing evicted", [
            .init(id: "a", bytes: 100, lastPlayedAt: now, isPinned: false)
        ], maxBytes: 1_000, evicts: [])

        expect("over budget, least-recently-played goes first", [
            .init(id: "old", bytes: 400, lastPlayedAt: now.addingTimeInterval(-3600), isPinned: false),
            .init(id: "new", bytes: 400, lastPlayedAt: now, isPinned: false)
        ], maxBytes: 500, evicts: ["old"])

        expect("pinned survives even when oldest", [
            .init(id: "pinned-old", bytes: 400, lastPlayedAt: now.addingTimeInterval(-7200), isPinned: true),
            .init(id: "predictive-new", bytes: 400, lastPlayedAt: now, isPinned: false)
        ], maxBytes: 500, evicts: ["predictive-new"])

        expect("all pinned and over budget: nothing evictable, budget stays exceeded", [
            .init(id: "a", bytes: 400, lastPlayedAt: now.addingTimeInterval(-7200), isPinned: true),
            .init(id: "b", bytes: 400, lastPlayedAt: now, isPinned: true)
        ], maxBytes: 100, evicts: [])

        expect("evicts multiple, stops as soon as it's under budget", [
            .init(id: "a", bytes: 300, lastPlayedAt: now.addingTimeInterval(-300), isPinned: false),
            .init(id: "b", bytes: 300, lastPlayedAt: now.addingTimeInterval(-200), isPinned: false),
            .init(id: "c", bytes: 300, lastPlayedAt: now.addingTimeInterval(-100), isPinned: false)
        ], maxBytes: 500, evicts: ["a", "b"])

        return report
    }
}
#endif

final class DownloadStoragePolicyTests: XCTestCase {
    private let fileManager = FileManager.default

    func testAccountDirectoriesAreIsolated() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }

        let first = DownloadStoragePolicy.accountDirectory(root: root, accountID: "account-a")
        let second = DownloadStoragePolicy.accountDirectory(root: root, accountID: "account-b")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Accounts")
        XCTAssertFalse(first.path.contains("account-a"), "Raw account IDs must not appear on disk")
    }

    func testLegacyFlatStorageMigratesIntoCurrentAccount() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let accountID = "migration-account"
        let legacyIndex = root.appendingPathComponent(
            DownloadStoragePolicy.legacyEncryptedIndexFileName(accountID: accountID)
        )
        let cachedAudio = root.appendingPathComponent("123.sctv")
        try Data("index".utf8).write(to: legacyIndex)
        try Data("audio".utf8).write(to: cachedAudio)

        DownloadStoragePolicy.migrateLegacyStorage(root: root, accountID: accountID)

        let accountDirectory = DownloadStoragePolicy.accountDirectory(root: root, accountID: accountID)
        XCTAssertTrue(fileManager.fileExists(
            atPath: accountDirectory.appendingPathComponent("index.vault").path
        ))
        XCTAssertTrue(fileManager.fileExists(
            atPath: accountDirectory.appendingPathComponent("123.sctv").path
        ))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyIndex.path))
        XCTAssertFalse(fileManager.fileExists(atPath: cachedAudio.path))
    }

    func testOrphanSweepRemovesOnlyOldInactiveTransferArtifacts() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let accountID = "cleanup-account"
        let accountDirectory = DownloadStoragePolicy.accountDirectory(root: root, accountID: accountID)
        let stagingDirectory = DownloadStoragePolicy.accountStagingDirectory(root: root, accountID: accountID)
        try fileManager.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let staleAssembly = accountDirectory.appendingPathComponent("111-assembled-stale.m4a")
        let activeAssembly = stagingDirectory.appendingPathComponent("222-assembled-active.m4a")
        let staleReplacement = accountDirectory.appendingPathComponent("333.replacement.stale.sctv")
        let freshAssembly = stagingDirectory.appendingPathComponent("444-assembled-fresh.m4a")
        let canonicalDownload = accountDirectory.appendingPathComponent("111.sctv")
        for file in [staleAssembly, activeAssembly, staleReplacement, freshAssembly, canonicalDownload] {
            try Data("test".utf8).write(to: file)
        }

        let now = Date()
        let staleDate = now.addingTimeInterval(-DownloadStoragePolicy.orphanGracePeriod - 1)
        for file in [staleAssembly, activeAssembly, staleReplacement] {
            try fileManager.setAttributes([.modificationDate: staleDate], ofItemAtPath: file.path)
        }

        let result = DownloadStoragePolicy.sweepTemporaryArtifacts(
            in: [accountDirectory, stagingDirectory],
            activeTrackIDs: ["222"],
            now: now
        )

        XCTAssertEqual(result.files, 2)
        XCTAssertFalse(fileManager.fileExists(atPath: staleAssembly.path))
        XCTAssertFalse(fileManager.fileExists(atPath: staleReplacement.path))
        XCTAssertTrue(fileManager.fileExists(atPath: activeAssembly.path))
        XCTAssertTrue(fileManager.fileExists(atPath: freshAssembly.path))
        XCTAssertTrue(fileManager.fileExists(atPath: canonicalDownload.path))
    }

    func testPurgingOneAccountDoesNotTouchAnother() throws {
        let root = temporaryRoot()
        let decryptedRoot = temporaryRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: decryptedRoot)
        }

        let first = DownloadStoragePolicy.accountDirectory(root: root, accountID: "account-a")
        let second = DownloadStoragePolicy.accountDirectory(root: root, accountID: "account-b")
        let firstDecrypted = DownloadStoragePolicy.decryptedAccountDirectory(
            root: decryptedRoot, accountID: "account-a"
        )
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: firstDecrypted, withIntermediateDirectories: true)

        DownloadStoragePolicy.purgeAccountStorage(
            downloadsRoot: root,
            decryptedRoot: decryptedRoot,
            accountID: "account-a"
        )

        XCTAssertFalse(fileManager.fileExists(atPath: first.path))
        XCTAssertFalse(fileManager.fileExists(atPath: firstDecrypted.path))
        XCTAssertTrue(fileManager.fileExists(atPath: second.path))
    }

    func testFixedChunkLayoutComputesOffsetsWithoutScanning() throws {
        let record = VaultChunkLayout.fullRecordLength
        XCTAssertEqual(record, 4 + 12 + 1_048_576 + 16)

        let empty = try XCTUnwrap(VaultChunkLayout.fixed(encryptedLength: 8))
        XCTAssertEqual(empty.chunkCount, 0)
        XCTAssertEqual(empty.plaintextLength, 0)
        XCTAssertNil(empty.chunkIndex(containing: 0))

        let exact = try XCTUnwrap(VaultChunkLayout.fixed(encryptedLength: 8 + 2 * record))
        XCTAssertEqual(exact.chunkCount, 2)
        XCTAssertEqual(exact.plaintextLength, 2 * 1_048_576)
        XCTAssertEqual(exact.chunk(at: 1).sealedLength, 1_048_576 + 28)

        let tailPlaintext: Int64 = 1_234
        let partial = try XCTUnwrap(VaultChunkLayout.fixed(encryptedLength: 8 + 2 * record + 4 + 28 + tailPlaintext))
        XCTAssertTrue(partial.isFixed)
        XCTAssertEqual(partial.chunkCount, 3)
        XCTAssertEqual(partial.plaintextLength, 2 * 1_048_576 + tailPlaintext)
        XCTAssertEqual(partial.chunkIndex(containing: 0), 0)
        XCTAssertEqual(partial.chunkIndex(containing: 1_048_575), 0)
        XCTAssertEqual(partial.chunkIndex(containing: 1_048_576), 1)
        XCTAssertEqual(partial.chunkIndex(containing: 2 * 1_048_576 + tailPlaintext - 1), 2)
        XCTAssertNil(partial.chunkIndex(containing: 2 * 1_048_576 + tailPlaintext))
        XCTAssertNil(partial.chunkIndex(containing: -1))

        let last = partial.chunk(at: 2)
        XCTAssertEqual(last.fileOffset, 8 + 2 * record)
        XCTAssertEqual(last.plaintextOffset, 2 * 1_048_576)
        XCTAssertEqual(Int64(last.plaintextLength), tailPlaintext)
        XCTAssertEqual(partial.chunk(at: 1).fileOffset, 8 + record)
        XCTAssertEqual(partial.chunkIndices(coveringOffset: 1_048_570, length: 20), 0...1)
        XCTAssertEqual(partial.chunkIndices(coveringOffset: 2 * 1_048_576 + 5, length: 10_000), 2...2)

        XCTAssertNil(VaultChunkLayout.fixed(encryptedLength: 4))
        XCTAssertNil(VaultChunkLayout.fixed(encryptedLength: 8 + 4 + 28))
    }

    func testEncryptedReaderSeeksAcrossChunkBoundaries() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let plaintext = Data((0..<(2 * 1_048_576 + 524_301)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let source = root.appendingPathComponent("source.m4a")
        let encrypted = root.appendingPathComponent("track.sctv")
        try plaintext.write(to: source)
        let key = SymmetricKey(size: .bits256)
        try DownloadVault.encryptFile(at: source, to: encrypted, using: key)

        let encryptedLength = try XCTUnwrap(
            (try fileManager.attributesOfItem(atPath: encrypted.path)[.size] as? NSNumber)?.int64Value
        )
        XCTAssertEqual(encryptedLength, 8 + 2 * VaultChunkLayout.fullRecordLength + 4 + 28 + 524_301)

        let reader = try EncryptedAudioReader(fileURL: encrypted, key: key)
        XCTAssertTrue(reader.layout.isFixed)
        XCTAssertEqual(reader.length, Int64(plaintext.count))

        let probes: [(Int64, Int)] = [
            (0, 2),
            (1_048_576 - 10, 20),
            (1_048_576, 1_048_576),
            (2 * 1_048_576 - 1, 3),
            (Int64(plaintext.count) - 7, 7),
            (Int64(plaintext.count) - 7, 100),
            (777_777, 1_600_000),
        ]
        for (offset, length) in probes {
            let expectedEnd = min(plaintext.count, Int(offset) + length)
            XCTAssertEqual(
                try reader.read(offset: offset, length: length),
                plaintext.subdata(in: Int(offset)..<expectedEnd),
                "offset \(offset) length \(length)"
            )
        }
        XCTAssertTrue(try reader.read(offset: Int64(plaintext.count), length: 10).isEmpty)

        let roundTrip = root.appendingPathComponent("roundtrip.m4a")
        try DownloadVault.decryptFile(at: encrypted, to: roundTrip, using: key)
        XCTAssertEqual(try Data(contentsOf: roundTrip), plaintext)

        let wrongReader = try EncryptedAudioReader(fileURL: encrypted, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try wrongReader.read(offset: 0, length: 1))
    }

    func testVariableLengthChunksFallBackToCachedIndex() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let key = SymmetricKey(size: .bits256)
        let pieces = [Data(repeating: 1, count: 1_000), Data(repeating: 2, count: 300_000), Data(repeating: 3, count: 3)]
        var file = DownloadVault.magic
        for piece in pieces {
            let sealed = try XCTUnwrap(try AES.GCM.seal(piece, using: key).combined)
            file.append(DownloadVault.encodedLength(sealed.count))
            file.append(sealed)
        }
        let url = root.appendingPathComponent("variable.sctv")
        try file.write(to: url)

        let reader = try EncryptedAudioReader(fileURL: url, key: key)
        XCTAssertFalse(reader.layout.isFixed)
        XCTAssertEqual(reader.layout.chunkCount, 3)
        XCTAssertEqual(reader.length, 301_003)
        XCTAssertEqual(reader.layout.chunkIndex(containing: 999), 0)
        XCTAssertEqual(reader.layout.chunkIndex(containing: 1_000), 1)
        XCTAssertEqual(reader.layout.chunkIndex(containing: 301_000), 2)
        let joined = pieces.reduce(Data(), +)
        XCTAssertEqual(try reader.read(offset: 990, length: 20), joined.subdata(in: 990..<1_010))
        XCTAssertEqual(try reader.read(offset: 300_990, length: 50), joined.subdata(in: 300_990..<301_003))

        let again = try EncryptedAudioReader(fileURL: url, key: key)
        XCTAssertEqual(again.layout, reader.layout)
    }

    @MainActor
    func testVaultAssetPlaysAndSeeksWithoutPlaintextOnDisk() async throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("tone.m4a")
        let sampleRate = 44_100.0
        let seconds = 150.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let frames: AVAudioFrameCount = 44_100
            var phase = 0.0
            for _ in 0..<Int(seconds) {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                for frame in 0..<Int(frames) {
                    let value = Float(sin(phase) * 0.2)
                    phase += 2 * .pi * 440 / sampleRate
                    for channel in 0..<Int(format.channelCount) {
                        buffer.floatChannelData![channel][frame] = value
                    }
                }
                try file.write(from: buffer)
            }
        }

        let key = SymmetricKey(size: .bits256)
        let encrypted = root.appendingPathComponent("tone.sctv")
        try DownloadVault.encryptFile(at: source, to: encrypted, using: key)
        let plaintextLength = try XCTUnwrap((try fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value)
        try fileManager.removeItem(at: source)
        XCTAssertGreaterThan(plaintextLength, Int64(DownloadVault.chunkSize), "The fixture must span several chunks")

        let reader = try EncryptedAudioReader(fileURL: encrypted, key: key)
        XCTAssertEqual(reader.length, plaintextLength)
        let asset = VaultPlaybackAsset.make(reader: reader, trackID: "fixture", fileExtension: "m4a")
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, seconds, accuracy: 1)

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        let readyDeadline = Date().addingTimeInterval(15)
        while item.status == .unknown, Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))

        player.play()
        let seekTarget = CMTime(seconds: 120, preferredTimescale: 600)
        let finished = await player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(finished)
        try await Task.sleep(for: .seconds(2))
        let position = player.currentTime().seconds
        XCTAssertGreaterThanOrEqual(position, 119.5)
        XCTAssertLessThan(position, 130)
        player.pause()

        let leftovers = try fileManager.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftovers, ["tone.sctv"], "Playback must not write a decrypted copy")
    }

    func testSetlistSourceReleaseDeletesOnlyTemporaryPlaintext() throws {
        let container = DownloadStoragePolicy.temporaryPlaintextRoot()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let leased = container.appendingPathComponent("1.m4a")
        try Data([1]).write(to: leased)

        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let deckFile = root.appendingPathComponent("deck.caf")
        try Data([2]).write(to: deckFile)

        SetlistAudioSources.release(SetlistLocalAudioSource(fileURL: leased))
        SetlistAudioSources.release(SetlistLocalAudioSource(fileURL: deckFile))

        XCTAssertFalse(fileManager.fileExists(atPath: container.path))
        XCTAssertTrue(fileManager.fileExists(atPath: deckFile.path))
    }

    private func makePlaintextLease(key: String) throws -> URL {
        let container = DownloadStoragePolicy.temporaryPlaintextRoot()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let file = container.appendingPathComponent("\(key).m4a")
        try Data([1, 2, 3]).write(to: file)
        TemporaryPlaintextLeases.shared.register(file, key: key)
        return file
    }

    func testPlaintextLeaseSurvivesUntilTheLastHolderReleases() throws {
        let leases = TemporaryPlaintextLeases.shared
        let file = try makePlaintextLease(key: "lease-\(UUID().uuidString)")
        let lease = TemporaryPlaintextFile(url: file)

        XCTAssertTrue(lease.retain())
        XCTAssertEqual(leases.holderCount(file), 2)

        lease.release()
        XCTAssertTrue(fileManager.fileExists(atPath: file.path))
        XCTAssertEqual(leases.holderCount(file), 1)

        SetlistAudioSources.release(SetlistLocalAudioSource(fileURL: file))
        XCTAssertFalse(fileManager.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertEqual(leases.holderCount(file), 0)
        XCTAssertFalse(lease.retain())
    }

    func testPlaintextCopiesAreSharedPerTrack() throws {
        let leases = TemporaryPlaintextLeases.shared
        let key = "shared-\(UUID().uuidString)"
        let file = try makePlaintextLease(key: key)

        XCTAssertTrue(leases.hasLiveCopy(key: key))
        XCTAssertEqual(leases.retainExisting(key: key), file)
        XCTAssertEqual(leases.holderCount(file), 2)

        leases.release(file)
        leases.release(file)
        XCTAssertFalse(leases.hasLiveCopy(key: key))
        XCTAssertNil(leases.retainExisting(key: key))
    }

    func testDeletedPlaintextIsNeverHandedOutAgain() throws {
        let leases = TemporaryPlaintextLeases.shared
        let key = "purged-\(UUID().uuidString)"
        let file = try makePlaintextLease(key: key)
        try fileManager.removeItem(at: file.deletingLastPathComponent())

        XCTAssertFalse(leases.hasLiveCopy(key: key))
        XCTAssertNil(leases.retainExisting(key: key))
    }

    @MainActor
    func testAnalysisFreeSpaceCountsTheTemporaryCopy() {
        let reserve = AutomaticAnalysisEligibility.storageReserveBytes
        XCTAssertEqual(AutomaticAnalysisEligibility.requiredFreeBytes(temporaryCopyBytes: 0), reserve)
        XCTAssertEqual(AutomaticAnalysisEligibility.requiredFreeBytes(temporaryCopyBytes: 150_000_000), reserve + 150_000_000)
        XCTAssertEqual(AutomaticAnalysisEligibility.requiredFreeBytes(temporaryCopyBytes: -5), reserve)
    }

    func testCollectionSyncAttachesNewMembersAndRespectsExclusions() {
        let entries = [
            "a": entry("a", collections: ["p"], downloaded: true),
            "b": entry("b", collections: ["p"], downloaded: true),
            "c": entry("c", explicit: true, collections: ["p"], downloaded: true),
            "x": entry("x", collections: ["other"], downloaded: true),
        ]
        let additive = DownloadCollectionSync.plan(
            collectionID: "p",
            memberIDs: ["a", "d", "e", "d", "x"],
            excluded: ["e"],
            entries: entries,
            authoritative: false
        )
        XCTAssertEqual(additive.attach, ["d", "x"])
        XCTAssertTrue(additive.detach.isEmpty, "Partial pages must never remove tracks")

        let authoritative = DownloadCollectionSync.plan(
            collectionID: "p",
            memberIDs: ["a", "d", "e"],
            excluded: ["e", "gone"],
            entries: entries,
            authoritative: true
        )
        XCTAssertEqual(authoritative.attach, ["d"])
        XCTAssertEqual(authoritative.detach, ["b", "c"])
        XCTAssertEqual(authoritative.prunedExclusions, ["e"])
    }

    func testRemovingOneCollectionTrackExcludesItFromEveryCollectionItBelongsTo() {
        let collections = [
            "likes": DownloadedCollectionRecord(id: "likes", kind: .likes, title: "Likes"),
            "p": DownloadedCollectionRecord(id: "p", kind: .playlist, title: "P", excludedTrackIDs: ["z"]),
            "q": DownloadedCollectionRecord(id: "q", kind: .playlist, title: "Q"),
        ]
        let updated = DownloadCollectionSync.exclusionsAfterRemoving(
            trackID: "t",
            from: collections,
            memberOf: ["likes", "p", "not-downloaded"]
        )
        XCTAssertEqual(updated["likes"]?.excludedTrackIDs, ["t"])
        XCTAssertEqual(updated["p"]?.excludedTrackIDs, ["z", "t"])
        XCTAssertEqual(updated["q"]?.excludedTrackIDs, [])
        XCTAssertNil(updated["not-downloaded"])

        let afterwards = DownloadCollectionSync.plan(
            collectionID: "p",
            memberIDs: ["t", "u"],
            excluded: updated["p"]?.excludedTrackIDs ?? [],
            entries: [:],
            authoritative: true
        )
        XCTAssertEqual(afterwards.attach, ["u"])
    }

    func testMigrationKeepsCollectionsOnlyWhereFilesExist() {
        var entries = [
            "liked-file": entry("liked-file", collections: ["likes"], downloaded: true),
            "liked-queued": entry("liked-queued", collections: ["likes"], downloaded: false),
            "playlist-queued": entry("playlist-queued", collections: ["p"], downloaded: false),
            "shared": entry("shared", collections: ["p", "likes"], downloaded: false),
            "explicit-in-p": entry("explicit-in-p", explicit: true, collections: ["p"], downloaded: false),
            "predictive-file": entry("predictive-file", downloaded: true),
            "predictive-queued": entry("predictive-queued", downloaded: false),
            "explicit-file": entry("explicit-file", explicit: true, downloaded: true),
        ]
        var collections: [String: DownloadedCollectionRecord] = [:]
        let outcome = DownloadModelMigration.migrate(
            entries: &entries,
            collections: &collections,
            legacyCollectionIDs: ["likes", "p"]
        )

        XCTAssertEqual(outcome.keptCollectionIDs, ["likes"])
        XCTAssertEqual(outcome.droppedCollectionIDs, ["p"])
        XCTAssertEqual(Set(collections.keys), ["likes"])
        XCTAssertEqual(collections["likes"]?.kind, .likes)
        XCTAssertEqual(outcome.removedTrackIDs, ["playlist-queued", "predictive-queued"])
        XCTAssertEqual(outcome.promotedToExplicit, ["predictive-file"])
        XCTAssertEqual(entries["shared"]?.collectionIDs, ["likes"])
        XCTAssertEqual(entries["explicit-in-p"]?.collectionIDs, [])
        XCTAssertEqual(entries["explicit-in-p"]?.isExplicit, true)
        XCTAssertNotNil(entries["liked-queued"])
        XCTAssertNotNil(entries["explicit-file"])
        XCTAssertTrue(entries.values.allSatisfy(\.isRetained))
    }

    func testMigrationWithoutLegacyFlagsDropsAutomaticQueues() {
        var entries = [
            "liked-file": entry("liked-file", collections: ["likes"], downloaded: true),
            "liked-queued": entry("liked-queued", collections: ["likes"], downloaded: false),
        ]
        var collections: [String: DownloadedCollectionRecord] = [:]
        let outcome = DownloadModelMigration.migrate(entries: &entries, collections: &collections, legacyCollectionIDs: [])
        XCTAssertTrue(collections.isEmpty)
        XCTAssertEqual(outcome.removedTrackIDs, ["liked-queued"])
        XCTAssertEqual(entries["liked-file"]?.isExplicit, true, "Downloaded audio is never deleted by migration")
    }

    func testLegacyAutomaticDownloadsFlagIsReadButNeverWrittenBack() throws {
        let legacy = Data(#"{"qualityCeiling":"high","automaticDownloads":true,"djMode":"normal"}"#.utf8)
        let policy = try JSONDecoder().decode(CollectionPolicy.self, from: legacy)
        XCTAssertTrue(policy.legacyAutomaticDownloads)
        XCTAssertEqual(policy.qualityCeiling, .high)

        let encoded = try JSONEncoder().encode(policy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["automaticDownloads"])
        let reread = try JSONDecoder().decode(CollectionPolicy.self, from: encoded)
        XCTAssertFalse(reread.legacyAutomaticDownloads)
        XCTAssertEqual(reread, policy)
    }

    func testDownloadEntryDecodesLegacyIndexKeys() throws {
        let legacy = entry("1", explicit: false, collections: ["likes"], downloaded: true)
        let data = try JSONEncoder().encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["isPinned"])
        XCTAssertNotNil(object["pinningCollectionIds"])
        let decoded = try JSONDecoder().decode(DownloadEntry.self, from: data)
        XCTAssertEqual(decoded.collectionIDs, ["likes"])
        XCTAssertFalse(decoded.isExplicit)
    }

    func testOptimiseStorageRemovesLeastRecentlyPlayedAboveTheMinimum() {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        let gb: Int64 = 1_000_000_000
        let candidates = [
            OptimiseStoragePolicy.Candidate(id: "oldest", bytes: gb, lastPlayedAt: now.addingTimeInterval(-30 * day)),
            OptimiseStoragePolicy.Candidate(id: "old", bytes: gb, lastPlayedAt: now.addingTimeInterval(-20 * day)),
            OptimiseStoragePolicy.Candidate(id: "week", bytes: gb, lastPlayedAt: now.addingTimeInterval(-7 * day)),
            OptimiseStoragePolicy.Candidate(id: "today", bytes: gb, lastPlayedAt: now.addingTimeInterval(-3600)),
        ]

        XCTAssertEqual(OptimiseStoragePolicy.victims(
            candidates: candidates, availableBytes: 50 * gb, minimumKeptBytes: 0, now: now
        ), [], "Nothing is removed while space is plentiful")

        XCTAssertEqual(OptimiseStoragePolicy.victims(
            candidates: candidates, availableBytes: gb, minimumKeptBytes: 0, now: now,
            lowSpaceThreshold: 2 * gb, targetFree: 3 * gb
        ), ["oldest", "old"])

        XCTAssertEqual(OptimiseStoragePolicy.victims(
            candidates: candidates, availableBytes: 0, minimumKeptBytes: 0, now: now,
            lowSpaceThreshold: 2 * gb, targetFree: 10 * gb
        ), ["oldest", "old", "week"], "Recently played downloads are protected")

        XCTAssertEqual(OptimiseStoragePolicy.victims(
            candidates: candidates, availableBytes: 0, minimumKeptBytes: 3 * gb, now: now,
            lowSpaceThreshold: 2 * gb, targetFree: 10 * gb
        ), ["oldest"], "The chosen minimum is always kept")

        XCTAssertFalse(OptimiseStoragePolicy.admitsNewTransfers(availableBytes: 100_000_000))
        XCTAssertTrue(OptimiseStoragePolicy.admitsNewTransfers(availableBytes: 5 * gb))
        XCTAssertTrue(OptimiseStoragePolicy.admitsNewTransfers(availableBytes: nil))
    }

    func testLargeOrCellularRequestsNeedConfirmation() {
        let small = DownloadSizeEstimate(bytes: 50_000_000, trackCount: 10, isOnCellular: false)
        XCTAssertNil(small.confirmationReason)
        let large = DownloadSizeEstimate(bytes: 1_000_000_001, trackCount: 300, isOnCellular: false)
        XCTAssertEqual(large.confirmationReason, .large)
        let cellular = DownloadSizeEstimate(bytes: 5_000_000, trackCount: 1, isOnCellular: true)
        XCTAssertEqual(cellular.confirmationReason, .cellular)
        let nothing = DownloadSizeEstimate(bytes: 0, trackCount: 0, isOnCellular: true)
        XCTAssertFalse(nothing.requiresConfirmation)
    }

    private func entry(
        _ id: String,
        explicit: Bool = false,
        collections: Set<String> = [],
        downloaded: Bool
    ) -> DownloadEntry {
        DownloadEntry(
            track: Self.fixtureTrack(id: id),
            isExplicit: explicit,
            collectionIDs: collections,
            fileName: downloaded ? "\(id).sctv" : nil,
            fileSize: downloaded ? 1_000 : 0,
            encryptionAccountID: downloaded ? "account" : nil
        )
    }

    private static func fixtureTrack(id: String) -> Track {
        let numeric = Int(id.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % 900_000) + 1
        let json = """
        {
            "id": \(numeric),
            "title": "\(id)",
            "permalink_url": "https://soundcloud.com/example/\(numeric)",
            "created_at": "2024-09-01T12:00:00Z",
            "user": {
                "id": 1,
                "username": "example",
                "permalink": "example",
                "permalink_url": "https://soundcloud.com/example"
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/example/\(numeric)/stream",
                        "duration": 200000,
                        "quality": "hq",
                        "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                        "preset": "aac_256k"
                    }
                ]
            }
        }
        """
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    private func temporaryRoot() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("SoundingDownloadStorageTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
