import XCTest
@testable import SoundingTV

final class TVDecksEntryTests: XCTestCase {
    func testNowPlayingNeverOpensDecksByItself() {
        for sessionIsActive in [false, true] {
            for hasStartOptions in [false, true] {
                XCTAssertEqual(
                    TVDecksEntry.entry(for: .nowPlayingAppeared, sessionIsActive: sessionIsActive, hasStartOptions: hasStartOptions),
                    .stayOnNowPlaying
                )
            }
        }
    }

    func testChoosingDecksWithASessionOpensThem() {
        XCTAssertEqual(TVDecksEntry.entry(for: .choseDecks, sessionIsActive: true, hasStartOptions: false), .openDecks)
    }

    func testChoosingDecksWithSavedOptionsOpensThem() {
        XCTAssertEqual(TVDecksEntry.entry(for: .choseDecks, sessionIsActive: false, hasStartOptions: true), .openDecks)
    }

    func testChoosingDecksTheFirstTimeAsksHowToStart() {
        XCTAssertEqual(TVDecksEntry.entry(for: .choseDecks, sessionIsActive: false, hasStartOptions: false), .configureFirst)
    }
}
