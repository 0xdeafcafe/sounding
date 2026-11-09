import XCTest

@MainActor
final class MusicStepE2ETests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testChoosingAFolderLeavesTheStep() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        app.launchEnvironment["SOUNDING_TV_MUSIC_STEP"] = "1"
        app.launch()

        let choose = app.buttons["musicStep.chooseFolder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20), "The music step never appeared.")
        XCTAssertFalse(app.buttons["welcome.signIn"].exists, "The welcome's Sign In button is still in the hierarchy under the music step.")
        capture(app, "music-step")
        choose.tap()
        sleep(3)
        capture(app, "picker")

        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8), "No Open button in the folder picker.")
        open.tap()

        let left = NSPredicate(format: "exists == false")
        expectation(for: left, evaluatedWith: choose)
        waitForExpectations(timeout: 10)
        sleep(2)
        capture(app, "after")
        XCTAssertFalse(app.buttons["musicStep.notNow"].exists, "Still on the music step after choosing a folder.")
    }
}
