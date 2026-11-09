import XCTest

@MainActor
final class AddToPlaylistTests: XCTestCase {
    private var app: XCUIApplication!

    private enum Look: String {
        case light
        case dark
        case xl
    }

    private func launch(_ look: Look, failWrites: Bool) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "1"
        app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
        app.launchEnvironment["SOUNDING_TV_ADD_TO_PLAYLIST"] = "1"
        if failWrites { app.launchEnvironment["SOUNDING_TV_PLAYLIST_WRITE_FAIL"] = "1" }
        let size = look == .xl ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launchArguments += ["-AppleInterfaceStyle", look == .dark ? "Dark" : "Light"]
        app.launch()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func device() -> String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    private func openSheet() {
        XCTAssertTrue(app.navigationBars["Add to Playlist"].waitForExistence(timeout: 15))
        capture("\(device())-sheet")
    }

    private func runFailure(_ look: Look) {
        launch(look, failWrites: true)
        openSheet()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Made for Late Nights, '")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.alerts["Couldn’t Add to Playlist"].waitForExistence(timeout: 10))
        capture("\(device())-\(look.rawValue)-failure-alert")
        app.alerts.buttons["Try Again"].tap()
        XCTAssertTrue(app.alerts["Couldn’t Add to Playlist"].waitForExistence(timeout: 10))
        capture("\(device())-\(look.rawValue)-failure-alert-retry")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add to Playlist"].exists)
        capture("\(device())-\(look.rawValue)-after-failure")
    }

    private func runNewPlaylist(_ look: Look) {
        launch(look, failWrites: false)
        openSheet()
        let newButton = app.buttons["New Playlist"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 10))
        newButton.tap()
        let alert = app.alerts["New Playlist"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture("\(device())-\(look.rawValue)-new-playlist-alert")
        let field = alert.textFields["Title"]
        XCTAssertTrue(field.exists)
        field.typeText("Late Night Drive 2")
        capture("\(device())-\(look.rawValue)-new-playlist-typed")
        alert.buttons["Create"].tap()
        sleep(1)
        capture("\(device())-\(look.rawValue)-new-playlist-creating")
    }

    func testFailureLight() { runFailure(.light) }
    func testFailureDark() { runFailure(.dark) }
    func testFailureXL() { runFailure(.xl) }
    func testNewPlaylistLight() { runNewPlaylist(.light) }
    func testNewPlaylistDark() { runNewPlaylist(.dark) }
    func testNewPlaylistXL() { runNewPlaylist(.xl) }
}
