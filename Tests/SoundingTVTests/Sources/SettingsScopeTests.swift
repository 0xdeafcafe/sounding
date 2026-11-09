import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class SettingsScopeTests: XCTestCase {
    private final class Clock {
        var millis: Int64 = 4_000_000_000_000
        func advance(_ delta: Int64 = 1_000) { millis += delta }
        var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
    }

    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "red.forbes.sounding.tests.settings.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeStore(_ defaults: UserDefaults, writer: String, clock: Clock) -> SettingsStore {
        SettingsStore(defaults: defaults, vault: .unsealed, writerId: writer, now: { clock.date })
    }

    private func payload(_ data: Data?) throws -> SettingsSyncPayload {
        try JSONDecoder().decode(SettingsSyncPayload.self, from: XCTUnwrap(data))
    }

    private let search = RecentSearchEntry(query: "okari", avatarURL: nil, subtitle: "Artist")

    func testPerKeyLastWriterWins() throws {
        let clock = Clock()
        let phone = makeStore(makeDefaults(), writer: "phone", clock: clock)
        let tv = makeStore(makeDefaults(), writer: "tv", clock: clock)

        phone.setStreamingQualityCeiling(.maximum)
        clock.advance()
        tv.setDJBlend(.long)
        clock.advance()
        phone.setDJBlend(.short)
        clock.advance()
        tv.setStreamingQualityCeiling(.efficient)

        let fromPhone = try XCTUnwrap(phone.exportSyncPayload(scope: .appleID))
        let fromTV = try XCTUnwrap(tv.exportSyncPayload(scope: .appleID))
        tv.merge(fromPhone)
        phone.merge(fromTV)

        XCTAssertEqual(tv.streamingQualityCeiling, .efficient)
        XCTAssertEqual(phone.streamingQualityCeiling, .efficient)
        XCTAssertEqual(tv.djBlend, .short)
        XCTAssertEqual(phone.djBlend, .short)

        let replay = tv.merge(fromPhone)
        XCTAssertTrue(replay.applied.isEmpty)
    }

    func testLocalWriteAfterMergeBeatsAPeerClockThatRunsAhead() throws {
        let clock = Clock()
        let phone = makeStore(makeDefaults(), writer: "phone", clock: clock)
        let mac = makeStore(makeDefaults(), writer: "mac", clock: clock)
        clock.advance(60_000)
        mac.setDJBlend(.long)
        clock.millis -= 60_000
        phone.merge(try XCTUnwrap(mac.exportSyncPayload(scope: .appleID)))
        XCTAssertEqual(phone.djBlend, .long)
        phone.setDJBlend(.short)
        mac.merge(try XCTUnwrap(phone.exportSyncPayload(scope: .appleID)))
        XCTAssertEqual(mac.djBlend, .short)
    }

    func testSignOutWipesAccountSettingsAndKeepsPreferences() throws {
        let clock = Clock()
        let defaults = makeDefaults()
        let store = makeStore(defaults, writer: "phone", clock: clock)
        store.unlockAccount("111")
        store.setRecentSearchQueries([search])
        store.setTrackTrims(["42": TrackTrim(start: 3)])
        store.setStreamingQualityCeiling(.maximum)

        store.lockAccount()
        AccountDataVault.removeDefaults(for: "111", in: defaults)

        XCTAssertTrue(store.recentSearchQueries.isEmpty)
        XCTAssertTrue(store.trackTrims.isEmpty)
        XCTAssertEqual(store.streamingQualityCeiling, .maximum)

        let relaunched = makeStore(defaults, writer: "phone", clock: clock)
        XCTAssertEqual(relaunched.streamingQualityCeiling, .maximum)
        relaunched.unlockAccount("111")
        XCTAssertTrue(relaunched.recentSearchQueries.isEmpty)
        XCTAssertTrue(relaunched.trackTrims.isEmpty)
    }

    func testSignInAgainRestoresAccountSettingsFromICloud() throws {
        let clock = Clock()
        let defaults = makeDefaults()
        let store = makeStore(defaults, writer: "phone", clock: clock)
        store.unlockAccount("111")
        store.setRecentSearchQueries([search])
        store.setCollectionPolicies(["p1": .standard])
        let iCloudCopy = try XCTUnwrap(store.exportSyncPayload(scope: .account))
        XCTAssertEqual(try payload(iCloudCopy).accountTag, AccountDataVault.storageSuffix(for: "111"))

        store.lockAccount()
        AccountDataVault.removeDefaults(for: "111", in: defaults)
        XCTAssertNil(store.exportSyncPayload(scope: .account))

        store.unlockAccount("111")
        XCTAssertTrue(store.recentSearchQueries.isEmpty)
        let result = store.merge(iCloudCopy)
        XCTAssertFalse(result.accountMismatch)
        XCTAssertEqual(store.recentSearchQueries, [search])
        XCTAssertEqual(store.collectionPolicies["p1"], .standard)
    }

    func testAccountSwitchNeverInheritsAnotherAccountsSettings() throws {
        let clock = Clock()
        let defaults = makeDefaults()
        let store = makeStore(defaults, writer: "phone", clock: clock)
        store.unlockAccount("111")
        store.setRecentSearchQueries([search])
        let firstAccount = try XCTUnwrap(store.exportSyncPayload(scope: .account))

        store.lockAccount()
        store.unlockAccount("222")
        XCTAssertTrue(store.recentSearchQueries.isEmpty)
        let result = store.merge(firstAccount)
        XCTAssertTrue(result.accountMismatch)
        XCTAssertTrue(store.recentSearchQueries.isEmpty)

        let appleIDPayload = try payload(store.exportSyncPayload(scope: .appleID) ?? Data(#"{"items":[],"scope":"appleID"}"#.utf8))
        XCTAssertFalse(appleIDPayload.entries.contains { $0.id == SettingKeys.RecentSearchQueries.id })

        store.lockAccount()
        store.unlockAccount("111")
        XCTAssertEqual(store.recentSearchQueries, [search])
    }

    func testLegacyPayloadNeverCarriesAccountSettings() throws {
        let clock = Clock()
        let store = makeStore(makeDefaults(), writer: "tv", clock: clock)
        store.unlockAccount("222")
        let legacy = SettingsSyncPayload(entries: [
            .init(id: SettingKeys.CollectionPolicies.id, valueJSON: try JSONEncoder().encode(["p1": CollectionPolicy.standard]), revision: 1, updatedAtMillis: clock.millis + 10_000, writerId: "old"),
            .init(id: SettingKeys.StreamingQualityCeiling.id, valueJSON: try JSONEncoder().encode(QualityCeiling.efficient), revision: 1, updatedAtMillis: clock.millis + 10_000, writerId: "old"),
        ])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object["entries"] = object.removeValue(forKey: "items")
        object.removeValue(forKey: "scope")
        object.removeValue(forKey: "format")
        let result = store.merge(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(store.streamingQualityCeiling, .efficient)
        XCTAssertTrue(store.collectionPolicies.isEmpty)
        XCTAssertEqual(result.unknownIds, [SettingKeys.CollectionPolicies.id])
    }

    func testDeviceLocalSettingsNeverLeaveTheDevice() throws {
        let clock = Clock()
        let defaults = makeDefaults()
        let store = makeStore(defaults, writer: "phone", clock: clock)
        store.unlockAccount("111")
        store.setCellularDownloadsAllowed(true)
        store.setAmbientScreensaverTimeoutSeconds(300)
        store.setAnalyseMusicOnDevice(false)
        store.setDJMatchWorkout(true)
        store.setSyncSettingsWithICloud(false)
        store.setDownloadedCollections(["p1": DownloadedCollectionRecord(id: "p1", kind: .playlist, title: "Mine")])
        store.setStreamingQualityCeiling(.maximum)
        defaults.set("Studio", forKey: "red.forbes.sounding.output.v1")
        defaults.set(true, forKey: "mac.sidebar.library.sets")
        defaults.set(true, forKey: "red.forbes.sounding.phone.didLeaveWelcome")
        defaults.set("dense", forKey: "trackList.density.likes")
        store.preferences.scan()

        let deviceLocal: Set<String> = [
            SettingKeys.CellularDownloadsAllowed.id,
            SettingKeys.AmbientScreensaverTimeoutSeconds.id,
            SettingKeys.AnalyseMusicOnDevice.id,
            SettingKeys.DJMatchWorkout.id,
            SettingKeys.SyncSettingsWithICloud.id,
            SettingKeys.DownloadedCollections.id,
            "defaults:red.forbes.sounding.output.v1",
            "defaults:mac.sidebar.library.sets",
            "defaults:red.forbes.sounding.phone.didLeaveWelcome",
        ]
        let appleID = try payload(store.exportSyncPayload(scope: .appleID))
        let account = try? payload(store.exportSyncPayload(scope: .account))
        let exported = Set(appleID.entries.map(\.id)).union(account?.entries.map(\.id) ?? [])
        XCTAssertTrue(exported.isDisjoint(with: deviceLocal), "\(exported.intersection(deviceLocal))")
        XCTAssertTrue(exported.contains(SettingKeys.StreamingQualityCeiling.id))
        XCTAssertTrue(exported.contains("defaults:trackList.density.likes"))

        let peer = makeStore(makeDefaults(), writer: "tv", clock: clock)
        let hostile = SettingsSyncPayload(entries: [
            .init(id: SettingKeys.CellularDownloadsAllowed.id, valueJSON: try JSONEncoder().encode(true), revision: 9, updatedAtMillis: .max, writerId: "x"),
            .init(id: "defaults:red.forbes.sounding.output.v1", valueJSON: SyncedPreferences.encode("Kitchen")!, revision: 9, updatedAtMillis: .max, writerId: "x"),
        ], scope: .appleID)
        peer.merge(try JSONEncoder().encode(hostile))
        XCTAssertFalse(peer.cellularDownloadsAllowed)
    }

    func testGenericPreferencesSyncByKey() throws {
        let clock = Clock()
        let ipadDefaults = makeDefaults()
        let macDefaults = makeDefaults()
        let ipad = makeStore(ipadDefaults, writer: "ipad", clock: clock)
        let mac = makeStore(macDefaults, writer: "mac", clock: clock)
        ipad.preferences.scan()
        mac.preferences.scan()

        clock.advance()
        ipadDefaults.set("dense", forKey: "trackList.density.likes")
        XCTAssertTrue(ipad.preferences.scan())
        clock.advance()
        macDefaults.set(Data([1, 2, 3]), forKey: "trackTable.columns.v2.likes")
        mac.preferences.scan()

        mac.merge(try XCTUnwrap(ipad.exportSyncPayload(scope: .appleID)))
        ipad.merge(try XCTUnwrap(mac.exportSyncPayload(scope: .appleID)))

        XCTAssertEqual(macDefaults.string(forKey: "trackList.density.likes"), "dense")
        XCTAssertEqual(ipadDefaults.data(forKey: "trackTable.columns.v2.likes"), Data([1, 2, 3]))
        XCTAssertFalse(mac.preferences.scan())
    }
}
