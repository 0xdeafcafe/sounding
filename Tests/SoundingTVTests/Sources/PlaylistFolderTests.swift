import XCTest
@testable import SoundingTV

final class PlaylistFolderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder(
        _ id: String,
        parent: String? = nil,
        children: [PlaylistFolderChild] = [],
        modified: TimeInterval = 0,
        deleted: Bool = false
    ) -> PlaylistFolder {
        PlaylistFolder(
            id: id,
            name: id,
            parentID: parent,
            childIDs: children,
            createdAt: base,
            modifiedAt: base.addingTimeInterval(modified),
            isDeleted: deleted
        )
    }

    func testNewestFolderOwnsAPlaylistListedTwice() {
        let tree = PlaylistFolderTree(records: [
            "a": folder("a", children: [.playlist("1")], modified: 1),
            "b": folder("b", children: [.playlist("1")], modified: 2),
        ])
        XCTAssertEqual(tree.owners["1"], "b")
        XCTAssertEqual(tree.children["a"], [])
        XCTAssertEqual(tree.children["b"], [.playlist("1")])
    }

    func testCycleAndDeletedParentFallBackToRoot() {
        let tree = PlaylistFolderTree(records: [
            "a": folder("a", parent: "b"),
            "b": folder("b", parent: "a"),
            "c": folder("c", parent: "gone"),
            "d": folder("d", parent: "dead"),
            "dead": folder("dead", deleted: true),
        ])
        XCTAssertEqual(Set(tree.roots), ["a", "b", "c", "d"])
        XCTAssertNil(tree.folders["dead"])
    }

    func testUnlistedSubfolderIsAppendedToItsParent() {
        let tree = PlaylistFolderTree(records: [
            "a": folder("a", children: [.playlist("1")]),
            "b": folder("b", parent: "a"),
        ])
        XCTAssertEqual(tree.children["a"], [.playlist("1"), .folder("b")])
        XCTAssertEqual(tree.roots, ["a"])
    }

    func testRecordMergeKeepsNewestPerFolderAndTombstones() {
        func record(_ millis: Int64, _ tag: String) -> SyncedRecord {
            SyncedRecord(modifiedAtMillis: millis, writerId: "w", payload: Data(tag.utf8))
        }
        let local = ["a": record(5, "local-a"), "b": record(1, "local-b")]
        let remote = ["a": record(3, "remote-a"), "b": record(4, "tombstone-b"), "c": record(2, "remote-c")]
        let merged = SyncedRecordMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged["a"]?.payload, Data("local-a".utf8))
        XCTAssertEqual(merged["b"]?.payload, Data("tombstone-b".utf8))
        XCTAssertEqual(merged["c"]?.payload, Data("remote-c".utf8))
        XCTAssertEqual(SyncedRecordMerge.merge(local: remote, remote: local), merged)
    }

    func testChildKeysRoundTrip() throws {
        let children: [PlaylistFolderChild] = [.playlist("123"), .folder("ABC")]
        let data = try JSONEncoder().encode(children)
        XCTAssertEqual(try JSONDecoder().decode([PlaylistFolderChild].self, from: data), children)
    }
}
