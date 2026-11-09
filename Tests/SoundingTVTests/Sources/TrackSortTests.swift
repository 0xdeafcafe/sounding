import XCTest
@testable import SoundingTV

final class TrackSortTests: XCTestCase {
    private let tracks = Array(VisualFixtures.tracks.prefix(5))

    private func summaries(_ bpms: [Int: Double]) -> [String: TrackAnalysisSummary] {
        Dictionary(uniqueKeysWithValues: bpms.map { (tracks[$0.key].id, TrackAnalysisSummary(bpm: $0.value)) })
    }

    func testUnanalysedTracksSortAfterAnalysedOnesInBothDirections() {
        let analysis = summaries([3: 128, 1: 90])
        for ascending in [true, false] {
            let sorted = TrackSort.sorted(tracks, by: .bpm, ascending: ascending, analysis: analysis)
            XCTAssertEqual(Set(sorted.prefix(2).map(\.id)), [tracks[1].id, tracks[3].id])
            XCTAssertEqual(sorted.first?.id, ascending ? tracks[1].id : tracks[3].id)
            XCTAssertEqual(Set(sorted.suffix(3).map(\.id)), Set([0, 2, 4].map { tracks[$0].id }))
        }
    }

    func testSortingWithNoAnalysisKeepsEveryTrack() {
        let sorted = TrackSort.sorted(tracks, by: .bpm, ascending: true, analysis: [:])
        XCTAssertEqual(Set(sorted.map(\.id)), Set(tracks.map(\.id)))
    }

    func testUnanalysedCountFollowsTheSortKey() {
        let analysis = summaries([0: 120, 2: 100])
        XCTAssertEqual(TrackSort.unanalysedCount(in: tracks, key: .bpm, analysis: analysis), 3)
        XCTAssertEqual(TrackSort.unanalysedCount(in: tracks, key: .key, analysis: analysis), 5)
        XCTAssertEqual(TrackSort.unanalysedCount(in: tracks, key: .title, analysis: analysis), 0)
        XCTAssertEqual(TrackSort.unanalysedCount(in: tracks, key: nil, analysis: analysis), 0)
    }

    func testOnlyTempoAndKeySortsHaveAnAnalysisValueToShow() {
        XCTAssertNotNil(TrackSortKey.bpm.analysisKind)
        XCTAssertNotNil(TrackSortKey.key.analysisKind)
        XCTAssertNil(TrackSortKey.genre.analysisKind)
        XCTAssertNil(TrackSortKey.dateAdded.analysisKind)
    }

    func testEqualValuesKeepTheirOriginalOrder() {
        let analysis = summaries([0: 124, 1: 124, 2: 124, 3: 124, 4: 124])
        for ascending in [true, false] {
            let sorted = TrackSort.sorted(tracks, by: .bpm, ascending: ascending, analysis: analysis)
            XCTAssertEqual(sorted.map(\.id), tracks.map(\.id))
        }
    }

    func testUnanalysedTracksKeepTheirOrderAtTheEnd() {
        let analysis = summaries([4: 100])
        let sorted = TrackSort.sorted(tracks, by: .bpm, ascending: false, analysis: analysis)
        XCTAssertEqual(sorted.map(\.id), [4, 0, 1, 2, 3].map { tracks[$0].id })
    }

    func testMissingEnergySortsLastInBothDirections() {
        var analysis: [String: TrackAnalysisSummary] = [:]
        analysis[tracks[2].id] = TrackAnalysisSummary(energy: 3)
        analysis[tracks[0].id] = TrackAnalysisSummary(energy: 8)
        for ascending in [true, false] {
            let sorted = TrackSort.sorted(tracks, by: .energy, ascending: ascending, analysis: analysis)
            XCTAssertEqual(sorted.first?.id, ascending ? tracks[2].id : tracks[0].id)
            XCTAssertEqual(sorted.suffix(3).map(\.id), [1, 3, 4].map { tracks[$0].id })
        }
    }

    func testBPMRangeKeepsOnlyAnalysedTracksInsideIt() {
        let analysis = summaries([0: 99, 1: 100, 2: 119.9, 3: 120, 4: 128])
        let query = TrackCollectionQuery(sortKey: nil, bpmRange: TrackBPMRange(lower: 100, upper: 120))
        let kept = TrackCollection.apply(tracks, query: query, analysis: analysis)
        XCTAssertEqual(kept.map(\.id), [1, 2].map { tracks[$0].id })
    }

    func testSourceFiltersCombineWithOrAndOtherFiltersWithAnd() {
        let downloaded: Set<String> = [tracks[1].id, tracks[3].id]
        let played: Set<String> = [tracks[3].id]
        let context = TrackFilterContext(
            isDownloaded: { downloaded.contains($0.id) },
            isPlayed: { played.contains($0.id) }
        )
        let downloadedOnly = TrackCollection.apply(tracks, query: TrackCollectionQuery(sortKey: nil, filters: [.downloaded]), analysis: [:], context: context)
        XCTAssertEqual(downloadedOnly.map(\.id), [tracks[1].id, tracks[3].id])
        let downloadedOrLocal = TrackCollection.apply(tracks, query: TrackCollectionQuery(sortKey: nil, filters: [.downloaded, .local]), analysis: [:], context: context)
        XCTAssertEqual(Set(downloadedOrLocal.map(\.id)), Set(tracks.filter { $0.isLocal || downloaded.contains($0.id) }.map(\.id)))
        let downloadedUnplayed = TrackCollection.apply(tracks, query: TrackCollectionQuery(sortKey: nil, filters: [.downloaded, .unplayed]), analysis: [:], context: context)
        XCTAssertEqual(downloadedUnplayed.map(\.id), [tracks[1].id])
    }

    func testKeyCompatibleNeedsANowPlayingKeyAndAnAnalysedKey() {
        let eightA = CamelotKey(wheelPosition: 8, mode: .minor)
        var analysis: [String: TrackAnalysisSummary] = [:]
        analysis[tracks[0].id] = TrackAnalysisSummary(key: CamelotKey(wheelPosition: 9, mode: .minor))
        analysis[tracks[1].id] = TrackAnalysisSummary(key: CamelotKey(wheelPosition: 8, mode: .major))
        analysis[tracks[2].id] = TrackAnalysisSummary(key: CamelotKey(wheelPosition: 3, mode: .minor))
        let query = TrackCollectionQuery(sortKey: nil, filters: [.keyCompatible])
        let matched = TrackCollection.apply(tracks, query: query, analysis: analysis, context: TrackFilterContext(nowPlayingKey: eightA))
        XCTAssertEqual(matched.map(\.id), [tracks[0].id, tracks[1].id])
        XCTAssertTrue(TrackCollection.apply(tracks, query: query, analysis: analysis).isEmpty)
    }

    func testSetsFilterUsesTheMinimumLength() {
        let minimum = tracks.map(\.duration).sorted()[2]
        let query = TrackCollectionQuery(sortKey: nil, filters: [.sets])
        let sets = TrackCollection.apply(tracks, query: query, analysis: [:], context: TrackFilterContext(setMinimumDuration: minimum))
        XCTAssertEqual(Set(sets.map(\.id)), Set(tracks.filter { $0.duration >= minimum }.map(\.id)))
    }

    func testSearchAndAnalysedFilterApplyTogether() {
        let analysis = summaries([0: 120])
        let query = TrackCollectionQuery(sortKey: nil, filters: [.analysed])
        XCTAssertEqual(TrackCollection.apply(tracks, query: query, search: tracks[0].title, analysis: analysis).map(\.id), [tracks[0].id])
        XCTAssertTrue(TrackCollection.apply(tracks, query: query, search: "zzzz-no-match", analysis: analysis).isEmpty)
    }

    func testQueryRoundTripsThroughItsStoredForm() {
        let query = TrackCollectionQuery(sortKey: .bpm, ascending: true, filters: [.downloaded, .unplayed], bpmRange: TrackBPMRange(lower: 120, upper: 128))
        XCTAssertEqual(TrackCollectionQuery(rawValue: query.rawValue), query)
        XCTAssertEqual(TrackCollectionQuery(rawValue: TrackCollectionQuery.collectionOrder.rawValue), .collectionOrder)
        XCTAssertNil(TrackCollectionQuery(rawValue: "nonsense"))
    }

    func testOnlyAChangedSortNeedsTheWholeCollection() {
        XCTAssertFalse(TrackCollection.needsFullCollection(.newestFirst, naturalOrder: .newestFirst))
        XCTAssertTrue(TrackCollection.needsFullCollection(TrackCollectionQuery(sortKey: .bpm), naturalOrder: .newestFirst))
        XCTAssertTrue(TrackCollection.needsFullCollection(TrackCollectionQuery(sortKey: .dateAdded, ascending: true), naturalOrder: .newestFirst))
        XCTAssertFalse(TrackCollection.needsFullCollection(.collectionOrder, naturalOrder: .collectionOrder))
    }
}
