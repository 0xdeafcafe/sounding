import XCTest

@MainActor
final class IOSWalkthroughTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        RealSession.apply(to: app)
        app.launch()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 15)
        let nearbySheet = app.navigationBars["Confirm Sign-In"]
        if nearbySheet.waitForExistence(timeout: 4) {
            nearbySheet.buttons["Cancel"].tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func capture(_ name: String, tree includeTree: Bool = false) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard includeTree else { return }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name).tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openTab(_ label: String) {
        let button = app.tabBars.buttons[label]
        if button.waitForExistence(timeout: 5) {
            button.tap()
        } else {
            app.buttons[label].firstMatch.tap()
        }
        _ = app.wait(for: .runningForeground, timeout: 2)
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func firstTrackRow() -> XCUIElement? {
        let candidates = [
            app.collectionViews.cells.firstMatch,
            app.tables.cells.firstMatch,
            app.scrollViews.buttons.element(boundBy: 0),
        ]
        return candidates.first { $0.waitForExistence(timeout: 8) && $0.isHittable }
    }

    private func pauseButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Pause'")).firstMatch
    }

    func test01_TabsWalkthrough() {
        capture("01-launch")
        for tab in ["Home", "Library", "Settings", "Search"] {
            openTab(tab)
            capture("01-tab-\(tab)")
        }
    }

    func test02_PlayFromLibraryAndOpenNowPlaying() {
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
        capture("02-library-list")

        guard let row = firstTrackRow() else {
            XCTFail("No track row found")
            return
        }
        let tapped = Date()
        row.tap()
        let started = pauseButton().waitForExistence(timeout: 20)
        let elapsed = Date().timeIntervalSince(tapped)
        note("02-time-to-playing", started ? String(format: "%.2fs", elapsed) : "did not reach playing within 20s")
        capture("02-after-tap")

        let accessory = app.otherElements.matching(NSPredicate(format: "identifier CONTAINS[c] 'accessory' OR identifier CONTAINS[c] 'miniplayer'")).firstMatch
        if accessory.exists {
            accessory.tap()
        } else {
            app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)).tap()
        }
        Thread.sleep(forTimeInterval: 2)
        capture("02-now-playing")

        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        capture("02-now-playing-below-fold")

        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.5)
        capture("02-dismissed")
    }

    func test03_DownloadATrack() {
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)

        guard let row = firstTrackRow() else {
            XCTFail("No track row found")
            return
        }
        row.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1)
        capture("03-context-menu")

        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Download'")).firstMatch
        guard download.waitForExistence(timeout: 3) else {
            note("03-result", "No Download action in the context menu")
            return
        }
        download.tap()
        let started = Date()
        var observations: [String] = []
        for step in 0..<12 {
            Thread.sleep(forTimeInterval: 5)
            let labels = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'download' OR label CONTAINS[c] 'queued' OR label CONTAINS[c] 'waiting'"))
                .allElementsBoundByIndex.prefix(6).map(\.label)
            observations.append(String(format: "%5.1fs %@", Date().timeIntervalSince(started), labels.joined(separator: " | ")))
            if step == 1 || step == 11 { capture("03-download-\(step)") }
        }
        note("03-download-observations", observations.joined(separator: "\n"))

        openTab("Settings")
        let downloads = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Download'")).firstMatch
        if downloads.waitForExistence(timeout: 5) {
            downloads.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        capture("03-settings-downloads")
    }

    func test06_PlayDownloadedTrackAndSeek() {
        let pairingPrompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Does this match'")).firstMatch
        if pairingPrompt.waitForExistence(timeout: 4) {
            app.buttons["Cancel"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)

        guard let row = firstTrackRow() else {
            XCTFail("No track row found")
            return
        }
        row.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1)
        capture("06-context-menu")
        let download = app.buttons.matching(NSPredicate(format: "label ==[c] 'Download'")).firstMatch
        if download.waitForExistence(timeout: 3) {
            download.tap()
            Thread.sleep(forTimeInterval: 45)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        capture("06-before-play")

        row.tap()
        let started = pauseButton().waitForExistence(timeout: 20)
        note("06-playing", started ? "playing" : "did not reach playing within 20s")
        Thread.sleep(forTimeInterval: 4)
        openNowPlaying()
        capture("06-now-playing")

        let laneStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.62))
        let laneEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.62))
        laneStart.press(forDuration: 0.1, thenDragTo: laneEnd, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 3)
        capture("06-after-seek")
        Thread.sleep(forTimeInterval: 20)
        capture("06-after-seek-later")
        note("06-still-playing", pauseButton().exists ? "pause visible" : "pause not visible")
    }

    private func openNowPlaying() {
        app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)).tap()
        Thread.sleep(forTimeInterval: 2)
    }

    private func drag(fromY: CGFloat, toY: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.5)
    }

    func test05_NowPlayingGestures() {
        openTab("Library")
        for (label, from) in [("title", 0.16), ("artwork", 0.40), ("waveform", 0.62)] as [(String, CGFloat)] {
            openNowPlaying()
            drag(fromY: from, toY: min(from + 0.5, 0.98))
            capture("05-dismiss-from-\(label)")
            if app.tabBars.firstMatch.isHittable == false {
                app.swipeDown(velocity: .fast)
                Thread.sleep(forTimeInterval: 1)
            }
        }
        openNowPlaying()
        drag(fromY: 0.80, toY: 0.20)
        capture("05-scroll-up-from-controls")
        drag(fromY: 0.40, toY: 0.05)
        capture("05-scroll-up-from-artwork")
    }

    private func tapButton(containing text: String, timeout: TimeInterval = 5) -> Bool {
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        guard button.waitForExistence(timeout: timeout) else { return false }
        button.tap()
        Thread.sleep(forTimeInterval: 1.5)
        return true
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func pullToRefresh() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    func test20_HomeSurfaces() {
        openTab("Home")
        Thread.sleep(forTimeInterval: 3)
        capture("20-home-foryou")
        app.swipeUp()
        capture("20-home-foryou-scrolled")
        app.swipeUp()
        capture("20-home-foryou-scrolled2")
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        pullToRefresh()
        capture("20-home-refresh")
        Thread.sleep(forTimeInterval: 2)
        let title = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sounding'")).firstMatch
        if title.exists {
            title.tap()
            Thread.sleep(forTimeInterval: 1)
            capture("20-home-titlemenu")
            let following = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Following'")).firstMatch
            if following.waitForExistence(timeout: 2) { following.tap() }
            Thread.sleep(forTimeInterval: 3)
            capture("20-home-following")
            app.swipeUp()
            capture("20-home-following-scrolled")
            app.swipeDown(velocity: .fast)
            pullToRefresh()
            capture("20-home-following-refresh")
        }
    }

    func test21_LibrarySections() {
        openTab("Library")
        Thread.sleep(forTimeInterval: 2)
        capture("21-library-index", tree: true)
        for section in ["Likes", "Sets", "Playlists", "Following"] {
            if tapButton(containing: section) {
                Thread.sleep(forTimeInterval: 2)
                capture("21-library-\(section)")
                app.swipeUp()
                capture("21-library-\(section)-scrolled")
                app.swipeDown(velocity: .fast)
                pullToRefresh()
                Thread.sleep(forTimeInterval: 1)
                capture("21-library-\(section)-refresh")
                goBack()
            }
        }
    }

    func test22_LibraryPlaylistAndArtist() {
        openTab("Library")
        if tapButton(containing: "Playlists") {
            let cell = app.collectionViews.cells.firstMatch
            if cell.waitForExistence(timeout: 8) { cell.tap() }
            Thread.sleep(forTimeInterval: 3)
            capture("22-playlist-detail")
            app.swipeUp()
            capture("22-playlist-detail-scrolled")
            goBack()
            goBack()
        }
        if tapButton(containing: "Following") {
            let cell = app.collectionViews.cells.firstMatch
            if cell.waitForExistence(timeout: 8) { cell.tap() }
            Thread.sleep(forTimeInterval: 3)
            capture("22-artist-detail")
            app.swipeUp()
            capture("22-artist-detail-scrolled")
            app.swipeUp()
            capture("22-artist-detail-scrolled2")
        }
    }

    func test23_Search() {
        openTab("Search")
        capture("23-search-empty", tree: true)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            Thread.sleep(forTimeInterval: 1)
            capture("23-search-focused")
            field.typeText("deadmau5")
            app.keyboards.buttons["Search"].tap()
            Thread.sleep(forTimeInterval: 4)
            capture("23-search-results")
            app.swipeUp()
            capture("23-search-results-scrolled")
        }
    }

    func test24_SettingsPages() {
        openTab("Settings")
        capture("24-settings-root")
        app.swipeUp()
        capture("24-settings-root-2")
        app.swipeUp()
        capture("24-settings-root-3")
        app.swipeUp()
        capture("24-settings-root-4")
        let rows = app.collectionViews.firstMatch.cells.allElementsBoundByIndex.map(\.label)
        note("24-settings-rows", rows.joined(separator: "\n"))
    }

    func test25_Profile() {
        openTab("Home")
        let avatar = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'account' OR label CONTAINS[c] 'profile'")).firstMatch
        if avatar.waitForExistence(timeout: 3) {
            avatar.tap()
            Thread.sleep(forTimeInterval: 2)
            capture("25-profile")
            app.swipeUp()
            capture("25-profile-2")
        }
    }

    func test26_HomeTitleAndMenu() {
        openTab("Home")
        Thread.sleep(forTimeInterval: 3)
        capture("26-home-title-large")
        app.swipeUp()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        capture("26-home-title-collapsed")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1)
        capture("26-home-title-menu")
        let following = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Following'")).firstMatch
        if following.waitForExistence(timeout: 2) {
            following.tap()
            Thread.sleep(forTimeInterval: 5)
            capture("26-home-following")
            app.swipeUp()
            capture("26-home-following-scrolled")
        }
    }

    func test04_ScrollPerformance() {
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTOSSignpostMetric.scrollDraggingMetric], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
        capture("04-after-scroll")
    }
}

enum RealSession {
    static func apply(to app: XCUIApplication) {
        guard let path = ProcessInfo.processInfo.environment["SOUNDING_DEV_SESSION"],
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["oauthToken"] as? String, !token.isEmpty else { return }
        app.launchEnvironment["SOUNDING_TV_DEV_TOKEN"] = token
        if let clientID = json["clientId"] as? String, !clientID.isEmpty {
            app.launchEnvironment["SOUNDING_TV_DEV_CLIENT_ID"] = clientID
        }
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
    }
}

@MainActor
final class CrossDeviceFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        RealSession.apply(to: app)
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("LANE5_ENV_") {
            app.launchEnvironment[String(key.dropFirst("LANE5_ENV_".count))] = value
        }
        app.launch()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name).tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testNearbyPairingConfirm() {
        Thread.sleep(forTimeInterval: 6)
        capture("pair-0-early")
        let confirm = app.buttons["It Matches"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        capture("pair-1-code")
        confirm.tap()
        Thread.sleep(forTimeInterval: 6)
        capture("pair-2-after-confirm")
        Thread.sleep(forTimeInterval: 10)
        capture("pair-3-later")
    }

    func testCompanionSettingsScreen() {
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Companion"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        capture("companion-1")
    }
}

extension IOSWalkthroughTests {
    private func startPlayingFirstLike() {
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
        guard let row = firstTrackRow() else {
            XCTFail("No track row found")
            return
        }
        row.tap()
        _ = pauseButton().waitForExistence(timeout: 20)
    }

    func test21_NowPlayingBackdropWithArtwork() {
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
        let rows = app.collectionViews.cells
        guard rows.element(boundBy: 1).waitForExistence(timeout: 8) else {
            XCTFail("No second row")
            return
        }
        rows.element(boundBy: 1).tap()
        _ = pauseButton().waitForExistence(timeout: 20)
        openNowPlaying()
        Thread.sleep(forTimeInterval: 3)
        capture("21-np-artwork")
        let next = app.buttons.matching(NSPredicate(format: "label ==[c] 'Next Track'")).firstMatch
        let tapped = Date()
        if next.waitForExistence(timeout: 3) { next.tap() }
        Thread.sleep(forTimeInterval: 0.35)
        capture("21-np-mid-skip")
        Thread.sleep(forTimeInterval: 2.5)
        capture("21-np-after-skip")
        note("21-skip-wallclock", String(format: "%.2fs", Date().timeIntervalSince(tapped)))
    }

    func test22_UpNextQueueControls() {
        startPlayingFirstLike()
        openNowPlaying()
        Thread.sleep(forTimeInterval: 2)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        let upNext = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Up Next'")).firstMatch
        if upNext.waitForExistence(timeout: 5) { upNext.tap() }
        Thread.sleep(forTimeInterval: 1.5)
        capture("22-up-next")
        let shuffle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Shuffle'")).firstMatch
        if shuffle.exists { shuffle.tap() }
        let repeatButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Repeat'")).firstMatch
        if repeatButton.exists { repeatButton.tap() }
        Thread.sleep(forTimeInterval: 1)
        capture("22-up-next-modes")
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Heartbeat'")).firstMatch
        if entry.waitForExistence(timeout: 3) {
            entry.tap()
            Thread.sleep(forTimeInterval: 3)
            capture("22-up-next-played")
        }
    }

    func test20_NowPlayingPlayheadAndMarkers() {
        startPlayingFirstLike()
        openNowPlaying()
        Thread.sleep(forTimeInterval: 3)
        capture("20-np-a")
        Thread.sleep(forTimeInterval: 1)
        capture("20-np-b")
        Thread.sleep(forTimeInterval: 1)
        capture("20-np-c")
        let pause = pauseButton()
        if pause.exists { pause.tap() }
        Thread.sleep(forTimeInterval: 1)
        capture("20-np-paused")
    }
}

extension IOSWalkthroughTests {
    private func dismissNearbySheets() {
        for title in ["Confirm Sign-In", "Confirm Code"] {
            let bar = app.navigationBars[title]
            if bar.exists {
                let cancel = bar.buttons["Cancel"]
                if cancel.exists { cancel.tap() } else { app.buttons["Cancel"].firstMatch.tap() }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func snap(_ name: String, tree: Bool = false) {
        dismissNearbySheets()
        capture(name, tree: tree)
    }

    private func tapRow(containing text: String, timeout: TimeInterval = 6) -> Bool {
        dismissNearbySheets()
        let cell = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        if cell.waitForExistence(timeout: timeout) {
            cell.tap()
            Thread.sleep(forTimeInterval: 1.5)
            return true
        }
        return tapButton(containing: text, timeout: 2)
    }

    func test30_LibraryIndexAndSections() {
        openTab("Library")
        Thread.sleep(forTimeInterval: 2)
        snap("30-library-index", tree: true)
        for section in ["Likes", "Sets", "Playlists", "Following"] {
            if tapRow(containing: section) {
                Thread.sleep(forTimeInterval: 2.5)
                snap("30-library-\(section)")
                goBack()
            }
        }
    }

    func test31_PlaylistAndArtistDetail() {
        openTab("Library")
        if tapRow(containing: "Playlists") {
            let cell = app.collectionViews.cells.firstMatch
            if cell.waitForExistence(timeout: 8) { cell.tap() }
            Thread.sleep(forTimeInterval: 3)
            snap("31-playlist-detail")
            let more = app.buttons["More"].firstMatch
            if more.waitForExistence(timeout: 2) {
                more.tap()
                Thread.sleep(forTimeInterval: 1)
                snap("31-playlist-more-menu")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
                Thread.sleep(forTimeInterval: 0.8)
            }
            goBack()
            goBack()
        }
        if tapRow(containing: "Following") {
            let cell = app.collectionViews.cells.firstMatch
            if cell.waitForExistence(timeout: 8) { cell.tap() }
            Thread.sleep(forTimeInterval: 3)
            snap("31-artist-detail")
            app.swipeUp()
            snap("31-artist-detail-scrolled")
        }
    }

    func test32_SearchRecentsAndResults() {
        openTab("Search")
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { return }
        field.tap()
        field.typeText("deadmau5")
        app.keyboards.buttons["Search"].tap()
        Thread.sleep(forTimeInterval: 4)
        snap("32-search-results")
        let clear = app.searchFields.firstMatch.buttons["Clear text"]
        if clear.exists { clear.tap() }
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        Thread.sleep(forTimeInterval: 1.5)
        snap("32-search-recents", tree: true)
        app.swipeUp()
        snap("32-search-recents-scrolled")
    }

    func test33_Following() {
        openTab("Home")
        Thread.sleep(forTimeInterval: 2)
        snap("33-home", tree: true)
        let title = app.navigationBars.staticTexts["Sounding"].firstMatch
        if title.waitForExistence(timeout: 3) {
            title.tap()
            Thread.sleep(forTimeInterval: 1)
            snap("33-home-title-menu")
            let following = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Following'")).firstMatch
            if following.waitForExistence(timeout: 2) { following.tap() }
            Thread.sleep(forTimeInterval: 4)
            snap("33-following", tree: true)
            let row = app.collectionViews.cells.firstMatch
            if row.waitForExistence(timeout: 5) {
                row.swipeLeft()
                Thread.sleep(forTimeInterval: 1)
                snap("33-following-swipe")
                row.swipeRight()
                Thread.sleep(forTimeInterval: 0.5)
                let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'More actions'")).firstMatch
                if more.waitForExistence(timeout: 2) {
                    more.tap()
                    Thread.sleep(forTimeInterval: 1)
                    snap("33-following-menu")
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
                }
            }
        }
    }

    private func dismissPairingPrompt(timeout: TimeInterval = 6) {
        let prompt = app.staticTexts["Confirm Code"]
        guard prompt.waitForExistence(timeout: timeout) else { return }
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) { cancel.tap() }
        Thread.sleep(forTimeInterval: 1)
    }

    private func relaunch(with environment: [String: String], keepSession: Bool = true) {
        app.terminate()
        app = XCUIApplication()
        if keepSession { RealSession.apply(to: app) }
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        Thread.sleep(forTimeInterval: 3)
    }

    private func playFirstLikeAndOpenNowPlaying() {
        dismissPairingPrompt()
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
        dismissPairingPrompt(timeout: 1)
        guard let row = firstTrackRow() else {
            XCTFail("No track row found")
            return
        }
        row.tap()
        _ = pauseButton().waitForExistence(timeout: 20)
        openNowPlaying()
        Thread.sleep(forTimeInterval: 2)
    }

    private func selectPane(_ name: String) {
        let segment = app.segmentedControls.buttons[name].firstMatch
        if segment.waitForExistence(timeout: 3) {
            segment.tap()
        } else {
            let fallback = app.buttons[name].firstMatch
            if fallback.waitForExistence(timeout: 2) { fallback.tap() }
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    func test30_NowPlayingHeroAndPanes() {
        playFirstLikeAndOpenNowPlaying()
        capture("30-np-a")
        Thread.sleep(forTimeInterval: 1)
        capture("30-np-b")

        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        capture("30-np-up-next")
        selectPane("Comments")
        capture("30-np-comments")
        selectPane("Tracklist")
        capture("30-np-tracklist")
        selectPane("Behind the Track")
        capture("30-np-about")
    }

    func test31_TrackMapSheet() {
        playFirstLikeAndOpenNowPlaying()
        let cues = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Cue Points'")).firstMatch
        if cues.waitForExistence(timeout: 5) { cues.tap() }
        Thread.sleep(forTimeInterval: 2)
        capture("31-track-map-live")

        relaunch(with: ["SOUNDING_TV_CUES": "1"])
        Thread.sleep(forTimeInterval: 2)
        capture("31-track-map-demo")
        let setMixOut = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Set'")).firstMatch
        if setMixOut.waitForExistence(timeout: 3) { setMixOut.tap() }
        Thread.sleep(forTimeInterval: 1)
        capture("31-track-map-demo-set")
    }

    func test32_SetlistSheet() {
        playFirstLikeAndOpenNowPlaying()
        let setlist = app.buttons["Setlist"].firstMatch
        if setlist.waitForExistence(timeout: 5) { setlist.tap() }
        Thread.sleep(forTimeInterval: 3)
        capture("32-setlist")
    }

    func test33_DJRemote() {
        relaunch(with: ["SOUNDING_TV_DJ": "1", "SOUNDING_TV_DJ_DEMO": "1"])
        dismissPairingPrompt(timeout: 3)
        capture("33-dj-remote")
        let deckB = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Deck B' OR label == 'B'")).firstMatch
        if deckB.waitForExistence(timeout: 3) { deckB.tap() }
        Thread.sleep(forTimeInterval: 1)
        capture("33-dj-remote-deck-b")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        capture("33-dj-remote-mixer")
    }

    func test34_SignIn() {
        relaunch(with: ["SOUNDING_TV_SIGNIN": "1"], keepSession: false)
        dismissPairingPrompt(timeout: 3)
        capture("34-sign-in-web")

        relaunch(with: ["SOUNDING_TV_SIGNIN": "1", "SOUNDING_TV_SIGNIN_URL": "http://127.0.0.1:9/"], keepSession: false)
        dismissPairingPrompt(timeout: 3)
        Thread.sleep(forTimeInterval: 2)
        capture("34-sign-in-unavailable")
    }
}

extension IOSWalkthroughTests {
    private func measureOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        return options
    }

    private func openLibraryLikes(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Library"]
        if tab.waitForExistence(timeout: 5) { tab.tap() }
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
    }

    func testPerf01_Launch() {
        measure(metrics: [XCTApplicationLaunchMetric(), XCTClockMetric()], options: measureOptions()) {
            let launched = XCUIApplication()
            RealSession.apply(to: launched)
            launched.launch()
            _ = launched.tabBars.firstMatch.waitForExistence(timeout: 15)
            launched.terminate()
        }
    }

    func testPerf02_TabSwitching() {
        let tabs = ["Library", "Settings", "Search", "Home"]
        measure(
            metrics: [XCTOSSignpostMetric.navigationTransitionMetric, XCTHitchMetric(application: app), XCTClockMetric()],
            options: measureOptions()
        ) {
            for tab in tabs {
                let button = app.tabBars.buttons[tab]
                if button.waitForExistence(timeout: 5) { button.tap() }
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
    }

    func testPerf03_OpenLibraryDestinations() {
        let tab = app.tabBars.buttons["Library"]
        if tab.waitForExistence(timeout: 5) { tab.tap() }
        Thread.sleep(forTimeInterval: 2)
        measure(
            metrics: [XCTOSSignpostMetric.navigationTransitionMetric, XCTHitchMetric(application: app), XCTClockMetric()],
            options: measureOptions()
        ) {
            for name in ["Likes", "Playlists", "Artists"] {
                let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
                guard entry.waitForExistence(timeout: 5) else { continue }
                entry.tap()
                Thread.sleep(forTimeInterval: 1.5)
                let back = app.navigationBars.buttons.firstMatch
                if back.exists {
                    back.tap()
                    Thread.sleep(forTimeInterval: 0.8)
                }
            }
        }
    }

    func test34_SettingsPages() {
        openTab("Settings")
        snap("34-settings-root")
        for page in ["Account", "Playback", "Activity", "Messages", "About"] {
            if tapRow(containing: page) {
                Thread.sleep(forTimeInterval: 2)
                snap("34-settings-\(page)")
                app.swipeUp()
                snap("34-settings-\(page)-scrolled")
                goBack()
            }
        }
    }

    func test35_Profile() {
        openTab("Library")
        dismissNearbySheets()
        let avatar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Account'")).firstMatch
        if avatar.waitForExistence(timeout: 3) {
            avatar.tap()
            Thread.sleep(forTimeInterval: 3)
            snap("35-profile")
            app.swipeUp()
            snap("35-profile-scrolled")
            goBack()
        }
        openTab("Settings")
        if tapRow(containing: "Account") {
            snap("35-account")
        }
    }

    func testPerf04_PlayAndOpenNowPlaying() {
        openLibraryLikes(app)
        let row = app.collectionViews.cells.firstMatch
        guard row.waitForExistence(timeout: 8) else { return XCTFail("No track row") }
        row.tap()
        _ = pauseButton().waitForExistence(timeout: 20)
        measure(
            metrics: [XCTOSSignpostMetric.navigationTransitionMetric, XCTHitchMetric(application: app), XCTClockMetric()],
            options: measureOptions()
        ) {
            openNowPlaying()
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    func testPerf05_ScrollLibraryLikes() {
        openLibraryLikes(app)
        measure(
            metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTHitchMetric(application: app), XCTClockMetric()],
            options: measureOptions()
        ) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }
}

extension IOSWalkthroughTests {
    private func relaunchForDevices(story: String?) {
        app.terminate()
        app = XCUIApplication()
        RealSession.apply(to: app)
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        app.launchEnvironment["SOUNDING_TV_PHONE_TAB"] = "settings"
        app.launchEnvironment["SOUNDING_TV_PHONE_SETTINGS"] = "devices"
        if let story { app.launchEnvironment["SOUNDING_TV_TV_STORY"] = story }
        app.launch()
        Thread.sleep(forTimeInterval: 3)
    }

    func test90_SettingsDevices() {
        relaunchForDevices(story: nil)
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
        Thread.sleep(forTimeInterval: 1.2)
        capture("90-settings-root")

        relaunchForDevices(story: "connected")
        _ = app.staticTexts["Devices"].waitForExistence(timeout: 5)
        capture("90-devices-connected", tree: true)

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Living Room'")).firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap()
            Thread.sleep(forTimeInterval: 1.2)
            capture("90-device-detail")
            let detailBack = app.navigationBars.buttons.firstMatch
            if detailBack.exists { detailBack.tap() }
            Thread.sleep(forTimeInterval: 1)
            row.swipeLeft()
            Thread.sleep(forTimeInterval: 0.8)
            capture("90-devices-swipe-forget")
        }

        relaunchForDevices(story: "unreachable")
        _ = app.staticTexts["Devices"].waitForExistence(timeout: 5)
        capture("90-devices-unreachable")

        relaunchForDevices(story: "neverPaired")
        _ = app.staticTexts["Devices"].waitForExistence(timeout: 5)
        capture("90-devices-none")
        let add = app.buttons["Add Apple TV…"].firstMatch
        if add.waitForExistence(timeout: 5) {
            add.tap()
            Thread.sleep(forTimeInterval: 1.5)
            capture("90-add-apple-tv-sheet", tree: true)
        }
    }
}

extension IOSWalkthroughTests {
    func test60_NoIntelligenceTab() {
        dismissPairingPrompt()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertFalse(tabBar.buttons["Intelligence"].exists)
        for tab in ["Home", "Library", "Settings"] {
            XCTAssertTrue(tabBar.buttons[tab].exists, "Missing \(tab) tab")
        }
    }

    private func openTabVerified(_ label: String, navigationTitle: String) {
        for _ in 0..<3 {
            dismissPairingPrompt(timeout: 2)
            openTab(label)
            if app.navigationBars[navigationTitle].waitForExistence(timeout: 4) { return }
        }
    }

    func test61_MusicAnalysisSettings() {
        openTabVerified("Settings", navigationTitle: "Settings")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Music Analysis'")).firstMatch
        if !row.waitForExistence(timeout: 8) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Music Analysis row missing")
        row.tap()
        Thread.sleep(forTimeInterval: 1.5)
        capture("61-music-analysis")

        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS[c] 'Analyse Music on This Device'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Analyse toggle missing")
        XCTAssertTrue(app.staticTexts["Storage Used"].waitForExistence(timeout: 5), "Storage Used row missing")

        let clear = app.buttons["Clear Analysis Data"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "Clear button missing")
        if clear.isEnabled {
            clear.tap()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Confirmation missing")
            XCTAssertTrue(sheet.buttons["Clear Analysis Data"].exists)
            capture("61-music-analysis-confirm")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists {
                cancel.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            }
            XCTAssertTrue(app.staticTexts["Storage Used"].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts["Music Intelligence"].exists)
    }

    func test62_LibrarySetlists() {
        openTabVerified("Library", navigationTitle: "Library")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Setlists'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Setlists row missing")
        row.tap()
        Thread.sleep(forTimeInterval: 1.5)
        capture("62-library-setlists")
        XCTAssertTrue(app.navigationBars["Setlists"].waitForExistence(timeout: 5))
    }
}

extension IOSWalkthroughTests {
    private func heroLabel() -> String? {
        let hero = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Now Playing,'")).firstMatch
        guard hero.waitForExistence(timeout: 5) else { return nil }
        return hero.label
    }

    private func playbackPositionValue() -> String? {
        let lane = app.otherElements.matching(NSPredicate(format: "label == 'Playback position'")).firstMatch
        guard lane.waitForExistence(timeout: 5) else { return nil }
        return lane.value as? String
    }

    private func openNowPlayingForVerification(prefix: String) {
        dismissPairingPrompt()
        openTab("Library")
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
        dismissPairingPrompt(timeout: 1)
        if let row = firstTrackRow() {
            row.tap()
            if pauseButton().waitForExistence(timeout: 20) {
                openNowPlaying()
                Thread.sleep(forTimeInterval: 2)
                note("\(prefix)-source", "real session")
                return
            }
        }
        relaunch(with: ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        Thread.sleep(forTimeInterval: 2)
        note("\(prefix)-source", "fixtures (real session unavailable)")
    }

    private func horizontalSwipe(atY y: CGFloat, toLeft: Bool) {
        let startX: CGFloat = toLeft ? 0.82 : 0.18
        let endX: CGFloat = toLeft ? 0.08 : 0.92
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func captureBurst(_ prefix: String, delays: [TimeInterval]) {
        var elapsed: TimeInterval = 0
        for delay in delays {
            Thread.sleep(forTimeInterval: max(0, delay - elapsed))
            elapsed = delay
            capture(String(format: "%@-%03dms", prefix, Int(delay * 1000)))
        }
    }

    func test40_NowPlayingSwipeToSkipAnywhereOnHero() {
        openNowPlayingForVerification(prefix: "40")
        let before = heroLabel()
        note("40-before", before ?? "nil")
        capture("40-before")

        horizontalSwipe(atY: 0.19, toLeft: true)
        captureBurst("40-title-swipe", delays: [0.08, 0.25, 0.5, 1.5])
        let afterTitleSwipe = heroLabel()
        note("40-after-title-swipe", afterTitleSwipe ?? "nil")
        XCTAssertNotEqual(before, afterTitleSwipe, "Swiping on the title should skip to the next track")

        Thread.sleep(forTimeInterval: 1.5)
        horizontalSwipe(atY: 0.42, toLeft: true)
        captureBurst("40-artwork-swipe", delays: [0.08, 0.25, 0.5, 1.5])
        let afterArtworkSwipe = heroLabel()
        note("40-after-artwork-swipe", afterArtworkSwipe ?? "nil")
        XCTAssertNotEqual(afterTitleSwipe, afterArtworkSwipe, "Swiping on the artwork should skip to the next track")

        Thread.sleep(forTimeInterval: 1.5)
        horizontalSwipe(atY: 0.30, toLeft: false)
        captureBurst("40-back-swipe", delays: [0.08, 0.25, 0.5, 1.5])
        note("40-after-back-swipe", heroLabel() ?? "nil")
    }

    func test41_NowPlayingBackdropWithAndWithoutArtwork() {
        relaunch(with: ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        Thread.sleep(forTimeInterval: 4)
        capture("41-backdrop-artwork")

        relaunch(with: [
            "SOUNDING_TV_UI_FIXTURE": "1",
            "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1",
            "SOUNDING_TV_FAKE_ARTWORK": "none",
        ])
        Thread.sleep(forTimeInterval: 3)
        capture("41-backdrop-no-artwork")
    }

    func test42_NowPlayingPlayheadMoves() {
        openNowPlayingForVerification(prefix: "42")
        var samples: [String] = []
        for index in 0..<4 {
            if let value = playbackPositionValue() { samples.append(value) }
            capture("42-playhead-\(index)")
            Thread.sleep(forTimeInterval: 1)
        }
        note("42-samples", samples.joined(separator: " | "))
        XCTAssertEqual(Set(samples).count, samples.count, "The playhead position should advance every second")
    }

    func test43_NowPlayingTrackChangeFrames() {
        openNowPlayingForVerification(prefix: "43")
        Thread.sleep(forTimeInterval: 2)
        capture("43-before-skip")
        let next = app.buttons.matching(NSPredicate(format: "label ==[c] 'Next Track'")).firstMatch
        guard next.waitForExistence(timeout: 3) else {
            XCTFail("No Next Track button")
            return
        }
        next.tap()
        captureBurst("43-skip", delays: [0.05, 0.15, 0.3, 0.5, 1.0, 2.0])
        note("43-after", heroLabel() ?? "nil")
    }
}

@MainActor
final class IOSAuditTests: XCTestCase {
    private var app: XCUIApplication!
    private var counter = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        if ProcessInfo.processInfo.environment["AUDIT_REAL"] == "1" { RealSession.apply(to: app) }
        app.launch()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 4)
    }

    private func clearPairing() {
        if app.staticTexts["Confirm Code"].exists {
            capture("PAIRING-SHEET")
            app.buttons["Cancel"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func capture(_ name: String) {
        if name != "PAIRING-SHEET" { clearPairing() }
        counter += 1
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = String(format: "%03d-%@", counter, name)
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dump(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = "labels-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func settle(_ s: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: s) }

    private func tab(_ label: String) {
        clearPairing()
        let b = app.tabBars.buttons[label]
        if b.waitForExistence(timeout: 5) { b.tap() } else { app.buttons[label].firstMatch.tap() }
        settle(2)
    }

    @discardableResult
    private func tapLabel(_ label: String, exact: Bool = false) -> Bool {
        clearPairing()
        let pred = exact ? NSPredicate(format: "label == %@", label) : NSPredicate(format: "label CONTAINS[c] %@", label)
        for attempt in 0..<3 {
            for q in [app.buttons, app.cells, app.staticTexts, app.otherElements] {
                let e = q.matching(pred).firstMatch
                if e.waitForExistence(timeout: attempt == 0 ? 2 : 0.5), e.isHittable { e.tap(); settle(2); return true }
            }
            app.swipeUp(); settle(0.8)
        }
        return false
    }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists, b.isHittable { b.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        settle(1.5)
    }

    private func scrollShots(_ name: String, pages: Int) {
        for i in 1...max(pages, 1) {
            app.swipeUp()
            settle(1)
            capture("\(name)-scroll\(i)")
        }
        for _ in 0..<pages { app.swipeDown(velocity: .fast) }
        settle(0.5)
    }

    private func page(_ label: String, pages: Int = 1, exact: Bool = false) {
        if tapLabel(label, exact: exact) {
            capture(label)
            dump(label)
            if pages > 0 { scrollShots(label, pages: pages) }
            back()
        } else {
            capture("MISSING-\(label)")
            dump("MISSING-\(label)")
        }
    }

    func testAudit() {
        capture("launch")
        for t in ["Home", "Intelligence", "Library", "Settings", "Search"] {
            tab(t)
            capture("tab-\(t)")
            dump("tab-\(t)")
            if t != "Search" { scrollShots("tab-\(t)", pages: 2) }
        }

        tab("Library")
        for s in ["Likes", "Sets", "Playlists", "Following"] {
            if tapLabel(s, exact: true) {
                capture("library-\(s)")
                dump("library-\(s)")
                scrollShots("library-\(s)", pages: 1)
                if s == "Playlists" || s == "Following" {
                    if let c = [app.collectionViews.cells.firstMatch, app.tables.cells.firstMatch].first(where: { $0.exists && $0.isHittable }) {
                        c.tap(); settle(3)
                        capture("library-\(s)-detail")
                        dump("library-\(s)-detail")
                        scrollShots("library-\(s)-detail", pages: 2)
                        back()
                    }
                }
                back()
            } else {
                capture("MISSING-library-\(s)")
                dump("MISSING-library-\(s)")
            }
        }

        tab("Search")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            capture("search-focused")
            field.typeText("daft punk")
            app.keyboards.buttons["Search"].tap()
            settle(4)
            capture("search-results")
            scrollShots("search-results", pages: 1)
        }

        tab("Settings")
        for p in ["Account", "Subscription", "Activity", "Messages", "Companion", "Playback", "Downloads", "About & Advanced"] {
            page(p, pages: 3)
        }
        tapLabel("Account"); tapLabel("View Profile"); capture("profile"); dump("profile"); scrollShots("profile", pages: 2); back(); back()
    }

    func testPlayer() {
        Thread.sleep(forTimeInterval: 3)
        clearPairing()
        tab("Library")
        tapLabel("Likes", exact: true)
        settle(3)
        guard let row = [app.collectionViews.cells.firstMatch, app.tables.cells.firstMatch, app.scrollViews.buttons.element(boundBy: 0)].first(where: { $0.waitForExistence(timeout: 8) && $0.isHittable }) else {
            capture("no-row"); return
        }
        row.press(forDuration: 1.2)
        settle(1)
        capture("context-menu")
        dump("context-menu")
        let dl = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Download'")).firstMatch
        if dl.exists { dl.tap(); settle(2); capture("after-download-tap") } else { app.tap(); settle(1) }
        let sort = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sort'")).firstMatch
        if sort.exists { sort.tap(); settle(1); capture("sort-menu"); app.tap() }
        settle(1)
        row.tap()
        settle(6)
        capture("miniplayer")
        dump("miniplayer")
        app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)).tap()
        settle(3)
        capture("nowplaying-top")
        dump("nowplaying-top")
        func npButton(_ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        }
        let more = npButton("More")
        if more.exists, more.isHittable { more.tap(); settle(1.5); capture("np-More"); app.tap(); settle(1) }
        let setlist = npButton("Setlist")
        if setlist.exists, setlist.isHittable {
            setlist.tap(); settle(2); capture("np-Setlist")
            app.swipeUp(); settle(1); capture("np-Setlist-scroll")
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() } else { app.swipeDown(velocity: .fast) }
            settle(1.5)
        }
        ensureNP()
        let cues = npButton("Cue Points")
        if cues.exists, cues.isHittable {
            cues.tap(); settle(2); capture("np-TrackMap"); dump("np-TrackMap")
            app.swipeDown(velocity: .fast); settle(1.5)
        }
        ensureNP()
        capture("np-back-to-top")
        let comments = npButton("Comments")
        if comments.exists, comments.isHittable { comments.tap(); settle(2.5); capture("np-Comments"); dump("np-Comments") }
        for i in 1...5 {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .default, thenHoldForDuration: 0)
            settle(1.5)
            capture("np-scroll\(i)")
            if i == 2 { dump("np-scroll2") }
        }
        let up = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Up Next'")).firstMatch
        if up.exists, up.isHittable { up.tap(); settle(1.5); capture("np-upnext") }
    }

    private func ensureNP() {
        if app.buttons["Close Now Playing"].exists { return }
        app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)).tap()
        settle(2.5)
    }

    private func tapButton(_ prefix: String) -> Bool {
        clearPairing()
        let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix)).firstMatch
        if b.waitForExistence(timeout: 3), b.isHittable { b.tap(); settle(2); return true }
        return false
    }

    func testExtras() {
        Thread.sleep(forTimeInterval: 3)
        clearPairing()
        tab("Home")
        if tapButton("Account,") { capture("home-avatar"); dump("home-avatar"); app.swipeDown(velocity: .fast); settle(1) }
        if tapButton("Apple TV,") { capture("home-appletv-card"); back() }
        tab("Home")
        app.swipeUp(); app.swipeUp(); settle(1)
        if tapButton("Night Tapes, artist") { capture("home-artist"); app.swipeDown(velocity: .fast); settle(1) }
        tab("Intelligence")
        if tapButton("Run on this iPhone") { capture("intel-balanced-menu"); app.tap(); settle(1) }
        if tapButton("Clear Analysis Data") { capture("intel-clear-confirm"); dump("intel-clear-confirm"); let c = app.buttons["Cancel"].firstMatch; if c.exists { c.tap() } else { app.tap() }; settle(1) }
        tab("Library")
        tapLabel("Likes", exact: true)
        if tapButton("Download All") { capture("likes-download-all"); dump("likes-download-all"); app.tap(); settle(1) }
        if tapButton("Liked Tracks Settings") { capture("likes-settings"); dump("likes-settings"); app.swipeDown(velocity: .fast); settle(1) }
        back()
        tab("Search")
        if tapButton("Browse Hip Hop") { capture("search-vibe"); dump("search-vibe"); scrollShots("search-vibe", pages: 1); back() }
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap(); field.typeText("night"); app.keyboards.buttons["Search"].tap(); settle(3)
            if tapLabel("See All Songs") { capture("search-see-all-songs"); back() }
            if tapButton("Night Tapes") { capture("search-artist"); dump("search-artist") }
        }
        tab("Settings")
        tapLabel("Companion"); settle(1)
        if tapButton("Turn On Decks") { capture("companion-decks"); dump("companion-decks"); scrollShots("companion-decks", pages: 2) }
    }

    func testNowPlayingScroll() {
        Thread.sleep(forTimeInterval: 3)
        clearPairing()
        ensureNP()
        capture("npx-top")
        for i in 1...10 {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.3)
            settle(1)
            capture("npx-scroll\(i)")
            let up = app.buttons["Up Next"].firstMatch
            if i == 4, up.exists, up.isHittable { up.tap(); settle(1.5); capture("npx-upnext") }
        }
    }

    func testSettingsTail() {
        Thread.sleep(forTimeInterval: 3)
        clearPairing()
        tab("Settings")
        for p in ["Downloads", "About & Advanced", "Messages", "Activity", "Subscription"] {
            page(p, pages: 2)
        }
    }

    func testUpNext() {
        Thread.sleep(forTimeInterval: 3)
        clearPairing()
        ensureNP()
        let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Comments'")).firstMatch
        if comments.exists, comments.isHittable { comments.tap(); settle(2.5) }
        for _ in 0..<3 {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.045))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.3)
            settle(1)
        }
        capture("un-comments-panel")
        let up = app.buttons["Up Next"].firstMatch
        if up.exists, up.isHittable { up.tap(); settle(2); capture("un-upnext"); dump("un-upnext") } else { dump("un-no-upnext") }
        for i in 1...3 {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.3)
            settle(1)
            capture("un-scroll\(i)")
        }
    }
}

extension IOSWalkthroughTests {
    func test70_DownloadsSettings() {
        relaunch(with: ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "downloads"])
        dismissPairingPrompt(timeout: 2)
        XCTAssertTrue(app.staticTexts["Downloaded Music"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Download Quality"].exists)
        XCTAssertTrue(app.switches["Optimise Storage"].exists || app.staticTexts["Optimise Storage"].exists)
        XCTAssertTrue(app.staticTexts["Applies to new downloads."].exists)
        XCTAssertTrue(app.buttons["Clear Cache"].exists)
        XCTAssertFalse(app.staticTexts["Storage Limit"].exists)
        capture("70-downloads-settings", tree: true)

        app.staticTexts["Downloaded Music"].tap()
        XCTAssertTrue(app.navigationBars["Downloaded Music"].waitForExistence(timeout: 5))
        capture("70-downloaded-music")
    }
}

extension IOSWalkthroughTests {
    private static let auditInteractiveTypes: [XCUIElement.ElementType] = [
        .button, .switch, .slider, .link, .textField, .secureTextField, .searchField,
        .segmentedControl, .stepper, .toggle, .picker, .datePicker, .menuItem, .tab,
    ]

    private func launchForAudit(_ environment: [String: String] = [:], largestType: Bool = false) {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
        app.launchEnvironment["SOUNDING_TV_PHONE_TAB"] = "home"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        if largestType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        dismissPairingPrompt(timeout: 1)
        if environment["SOUNDING_TV_NOW_PLAYING_EXPANDED"] == "1" {
            XCTAssertTrue(app.buttons["Close Now Playing"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func unlabelledInteractiveElements() -> [String] {
        var found: [String] = []
        for type in Self.auditInteractiveTypes {
            let query = app.descendants(matching: type)
            for index in 0..<min(query.count, 200) {
                let element = query.element(boundBy: index)
                guard element.exists, app.frame.intersects(element.frame), !element.frame.isEmpty else { continue }
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.isEmpty, element.title.isEmpty, element.identifier.isEmpty else { continue }
                let childLabel = element.descendants(matching: .any).allElementsBoundByIndex
                    .first { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
                if childLabel == nil {
                    found.append("\(type.rawValue)@\(element.frame.integral)")
                }
            }
        }
        return found
    }

    private func audit(_ screen: String, types: XCUIAccessibilityAuditType = XCUIAccessibilityAuditType.all.subtracting(.textClipped)) {
        var issues: [String] = []
        var warnings: [String] = []
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                let described = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' \($0.frame.integral)" } ?? "-"
                if issue.compactDescription.contains("nearly passed") {
                    warnings.append("[\(issue.auditType.rawValue)] \(issue.compactDescription) :: \(described)")
                } else {
                    issues.append("[\(issue.auditType.rawValue)] \(issue.compactDescription) :: \(described)")
                }
                return true
            }
        } catch {
            issues.append("audit threw: \(error)")
        }
        let empties = unlabelledInteractiveElements()
        let report = XCTAttachment(string: "== \(screen) ==\nAudit issues (\(issues.count)):\n" + issues.joined(separator: "\n") + "\nNear-threshold contrast (\(warnings.count)):\n" + warnings.joined(separator: "\n") + "\nUnlabelled interactive (\(empties.count)):\n" + empties.joined(separator: "\n"))
        report.name = "audit-\(screen)"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertTrue(issues.isEmpty, "\(screen): \(issues.count) accessibility audit issues\n" + issues.joined(separator: "\n"))
        XCTAssertTrue(empties.isEmpty, "\(screen): \(empties.count) interactive elements with empty labels\n" + empties.joined(separator: "\n"))
    }

    func test90_AuditHome() {
        launchForAudit(["SOUNDING_TV_PHONE_TAB": "home"])
        audit("home")
    }

    func test91_AuditLibrary() {
        launchForAudit(["SOUNDING_TV_PHONE_TAB": "library"])
        audit("library")
    }

    func test92_AuditSearch() {
        launchForAudit(["SOUNDING_TV_PHONE_TAB": "search"])
        audit("search")
    }

    func test93_AuditSettings() {
        launchForAudit(["SOUNDING_TV_PHONE_TAB": "settings"])
        audit("settings")
    }

    func test94_AuditWelcome() {
        launchForAudit(["SOUNDING_TV_WELCOME": "1", "SOUNDING_TV_DISMISS_WELCOME": "0"])
        audit("welcome")
    }

    func test95_AuditNowPlaying() {
        launchForAudit(["SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        audit("now-playing")
    }

    func test96_AuditNowPlayingAtLargestType() {
        launchForAudit(["SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"], largestType: true)
        audit("now-playing-ax5", types: [.dynamicType, .textClipped, .sufficientElementDescription])
    }

    func test97_AuditHomeAtLargestType() {
        launchForAudit(["SOUNDING_TV_PHONE_TAB": "home"], largestType: true)
        audit("home-ax5", types: [.dynamicType, .textClipped, .sufficientElementDescription])
    }

    func test98_AuditLibraryAtLargestType() {
        launchForAudit(["SOUNDING_TV_PHONE_TAB": "library"], largestType: true)
        audit("library-ax5", types: [.dynamicType, .textClipped, .sufficientElementDescription])
    }
}

@MainActor
final class IOSFinalAuditTests: XCTestCase {
    private var app: XCUIApplication!
    private var counter = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private func launch(_ environment: [String: String] = [:]) {
        if app != nil { app.terminate() }
        app = XCUIApplication()
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 20)
        settle(3)
        clearSheets()
    }

    private func settle(_ seconds: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: seconds) }

    private func clearSheets() {
        if app.staticTexts["Confirm Code"].exists || app.navigationBars["Confirm Sign-In"].exists {
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
            settle(1)
        }
    }

    private func shoot(_ name: String) {
        clearSheets()
        counter += 1
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = String(format: "%03d-%@", counter, name)
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func scrollShots(_ name: String, pages: Int) {
        for index in 1...max(pages, 1) {
            app.swipeUp()
            settle(1)
            shoot("\(name)-scroll\(index)")
        }
        for _ in 0..<pages { app.swipeDown(velocity: .fast) }
        settle(0.5)
    }

    private func tab(_ label: String) {
        clearSheets()
        let button = app.tabBars.buttons[label]
        if button.waitForExistence(timeout: 5) { button.tap() } else { app.buttons[label].firstMatch.tap() }
        settle(2)
    }

    @discardableResult
    private func tapRow(_ label: String, exact: Bool = false) -> Bool {
        clearSheets()
        let predicate = exact
            ? NSPredicate(format: "label == %@", label)
            : NSPredicate(format: "label CONTAINS[c] %@", label)
        for attempt in 0..<4 {
            for query in [app.buttons, app.cells, app.staticTexts] {
                let element = query.matching(predicate).firstMatch
                if element.waitForExistence(timeout: attempt == 0 ? 2 : 0.4), element.isHittable {
                    element.tap()
                    settle(2)
                    return true
                }
            }
            app.swipeUp()
            settle(0.6)
        }
        return false
    }

    private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists, button.isHittable { button.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        settle(1.2)
    }

    private func firstCell() -> XCUIElement? {
        [app.collectionViews.cells.firstMatch, app.tables.cells.firstMatch]
            .first { $0.waitForExistence(timeout: 6) && $0.isHittable }
    }

    func testF01_Tabs() {
        launch()
        shoot("home")
        scrollShots("home", pages: 3)
        tab("Library")
        shoot("library")
        scrollShots("library", pages: 2)
        tab("Search")
        shoot("search-recents")
        scrollShots("search-recents", pages: 1)
        tab("Settings")
        shoot("settings")
        scrollShots("settings", pages: 2)
    }

    func testF02_LibrarySections() {
        launch(["SOUNDING_TV_PHONE_TAB": "library"])
        for section in ["Likes", "Sets", "Setlists", "Playlists", "Following"] {
            if tapRow(section, exact: true) {
                shoot("library-\(section)")
                scrollShots("library-\(section)", pages: 1)
                if section == "Likes" {
                    let sort = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sort'")).firstMatch
                    if sort.exists, sort.isHittable { sort.tap(); settle(1); shoot("likes-sort-menu"); app.tap(); settle(1) }
                    if let row = firstCell() {
                        row.press(forDuration: 1.2)
                        settle(1)
                        shoot("likes-row-menu")
                        app.tap()
                        settle(1)
                    }
                }
                if section == "Playlists" || section == "Following" || section == "Setlists" {
                    if let cell = firstCell() {
                        cell.tap()
                        settle(3)
                        shoot("library-\(section)-detail")
                        scrollShots("library-\(section)-detail", pages: 2)
                        back()
                    }
                }
                back()
            } else {
                shoot("MISSING-library-\(section)")
            }
        }
    }

    func testF03_Search() {
        launch(["SOUNDING_TV_PHONE_TAB": "search"])
        shoot("search-idle")
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { shoot("MISSING-search-field"); return }
        field.tap()
        settle(1)
        shoot("search-focused")
        field.typeText("night")
        app.keyboards.buttons["Search"].tap()
        settle(4)
        shoot("search-results")
        scrollShots("search-results", pages: 2)
        if tapRow("See All Songs") { shoot("search-see-all"); back() }
        field.tap()
        let clear = app.searchFields.firstMatch.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText("zzqxwv")
        app.keyboards.buttons["Search"].tap()
        settle(4)
        shoot("search-empty")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        settle(1.5)
        shoot("search-recents-after")
        for vibe in ["Browse Hip Hop", "Browse"] {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", vibe)).firstMatch
            if button.waitForExistence(timeout: 3), button.isHittable {
                button.tap()
                settle(3)
                shoot("search-vibe")
                scrollShots("search-vibe", pages: 1)
                break
            }
        }
    }

    func testF04_HomeAndFollowing() {
        launch(["SOUNDING_TV_PHONE_TAB": "home"])
        shoot("home")
        app.swipeUp()
        settle(1)
        let titleText = app.navigationBars.staticTexts["Sounding"].firstMatch
        let titleButton = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sounding'")).firstMatch
        let title = titleText.exists ? titleText : titleButton
        if title.waitForExistence(timeout: 3) {
            title.tap()
            settle(1)
            shoot("home-title-menu")
            let following = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Following'")).firstMatch
            if following.waitForExistence(timeout: 2) {
                following.tap()
                settle(4)
                shoot("home-following")
                scrollShots("home-following", pages: 2)
                if let row = firstCell() {
                    row.swipeLeft()
                    settle(1)
                    shoot("home-following-swipe")
                    row.swipeRight()
                    settle(0.5)
                }
            }
        }
        for state in ["empty", "error", "loading"] {
            launch(["SOUNDING_TV_PHONE_TAB": "home", "SOUNDING_TV_FEED_STATE": state])
            shoot("feed-\(state)")
        }
        launch(["SOUNDING_TV_PHONE_TAB": "home"])
        for prefix in ["Account,"] {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix)).firstMatch
            if button.waitForExistence(timeout: 2), button.isHittable {
                button.tap()
                settle(2)
                shoot("home-\(prefix)")
                app.swipeDown(velocity: .fast); settle(1)
            }
        }
    }

    func testF05_SettingsPages() {
        for page in ["account", "subscription", "activity", "messages", "playback", "downloads", "analysis", "devices", "about"] {
            launch(["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": page])
            shoot("settings-\(page)")
            scrollShots("settings-\(page)", pages: 3)
        }
        launch(["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "downloads"])
        if tapRow("Downloaded Music") { shoot("settings-downloaded-music"); scrollShots("settings-downloaded-music", pages: 1) }
        launch(["SOUNDING_TV_PHONE_TAB": "settings"])
        if tapRow("Account") {
            if tapRow("View Profile") { shoot("profile"); scrollShots("profile", pages: 2) }
        }
    }

    func testF06_NowPlaying() {
        launch(["SOUNDING_TV_PHONE_TAB": "library"])
        shoot("miniplayer-library")
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        settle(2)
        shoot("np-top")
        for index in 1...6 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            settle(1)
            shoot("np-scroll\(index)")
        }
        for pane in ["upNext", "comments", "tracklist", "about"] {
            launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": pane, "SOUNDING_TV_COMMENTS_DEMO": "1"])
            settle(3)
            if pane == "tracklist" || pane == "about" {
                app.swipeUp()
                settle(1)
                app.swipeUp()
                settle(1)
            }
            shoot("np-pane-\(pane)")
        }
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'More'")).firstMatch
        if more.waitForExistence(timeout: 3), more.isHittable { more.tap(); settle(1.5); shoot("np-more-menu"); app.tap(); settle(1) }
    }

    func testF07_NowPlayingSheets() {
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_PHONE_CUES": "1"])
        settle(4)
        shoot("sheet-cue-points")
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_PHONE_CUES": "1", "SOUNDING_TV_CUES": "1", "SOUNDING_TV_TRACKMAP_DEMO": "1"])
        settle(4)
        shoot("sheet-cue-points-demo")
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "setlist"])
        settle(4)
        shoot("sheet-setlist")
        app.swipeUp()
        settle(1)
        shoot("sheet-setlist-scroll")
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "setlistScanning"])
        settle(4)
        shoot("sheet-setlist-scanning")
        launch(["SOUNDING_TV_DJ": "1", "SOUNDING_TV_DJ_DEMO": "1"])
        settle(2)
        shoot("decks")
        let deckB = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Deck B' OR label == 'B'")).firstMatch
        if deckB.waitForExistence(timeout: 3) { deckB.tap(); settle(1); shoot("decks-b") }
        app.swipeUp()
        settle(1)
        shoot("decks-scroll")
    }

    func testF08_SignIn() {
        launch(["SOUNDING_TV_SIGNIN": "1", "SOUNDING_TV_UI_FIXTURE": "0"])
        settle(3)
        shoot("sign-in")
        launch(["SOUNDING_TV_SIGNIN": "1", "SOUNDING_TV_UI_FIXTURE": "0", "SOUNDING_TV_SIGNIN_URL": "http://127.0.0.1:9/"])
        settle(3)
        shoot("sign-in-unavailable")
    }
}

extension IOSWalkthroughTests {
    private func smoothOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    private func smoothRelaunch(_ extra: [String: String] = [:]) {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "1"
        app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launch()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 3)
    }

    private func smoothScrollMetrics() -> [XCTMetric] {
        [
            XCTOSSignpostMetric.scrollDecelerationMetric,
            XCTOSSignpostMetric.scrollDraggingMetric,
            XCTHitchMetric(application: app),
            XCTClockMetric(),
        ]
    }

    private func smoothTransitionMetrics() -> [XCTMetric] {
        [
            XCTOSSignpostMetric.navigationTransitionMetric,
            XCTOSSignpostMetric.customNavigationTransitionMetric,
            XCTHitchMetric(application: app),
            XCTClockMetric(),
        ]
    }

    private func smoothHitchMetrics() -> [XCTMetric] {
        [XCTHitchMetric(application: app), XCTClockMetric()]
    }

    private func smoothSwipe(fromX: CGFloat, toX: CGFloat, y: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func smoothOpenLikes() {
        let tab = app.tabBars.buttons["Library"]
        if tab.waitForExistence(timeout: 5) { tab.tap() }
        let likes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        if likes.waitForExistence(timeout: 5) { likes.tap() }
        Thread.sleep(forTimeInterval: 2)
    }

    private func smoothOpenNowPlaying() {
        smoothRelaunch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        Thread.sleep(forTimeInterval: 2)
    }

    private func smoothTap(_ text: String, timeout: TimeInterval = 5) -> Bool {
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        guard button.waitForExistence(timeout: timeout) else { return false }
        button.tap()
        return true
    }

    func testSmooth01_HomeScrollVertical() {
        smoothRelaunch()
        measure(metrics: smoothScrollMetrics(), options: smoothOptions()) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func testSmooth02_HomeShelfHorizontal() {
        smoothRelaunch()
        measure(metrics: smoothScrollMetrics(), options: smoothOptions()) {
            smoothSwipe(fromX: 0.85, toX: 0.1, y: 0.33)
            smoothSwipe(fromX: 0.85, toX: 0.1, y: 0.33)
            smoothSwipe(fromX: 0.1, toX: 0.9, y: 0.33)
            smoothSwipe(fromX: 0.1, toX: 0.9, y: 0.33)
        }
    }

    func testSmooth03_LikesScroll() {
        smoothRelaunch()
        smoothOpenLikes()
        measure(metrics: smoothScrollMetrics(), options: smoothOptions()) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func testSmooth04_SearchResultsScroll() {
        smoothRelaunch()
        let tab = app.tabBars.buttons["Search"]
        if tab.waitForExistence(timeout: 5) { tab.tap() }
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { return XCTFail("No search field") }
        field.tap()
        field.typeText("night")
        Thread.sleep(forTimeInterval: 3)
        measure(metrics: smoothScrollMetrics(), options: smoothOptions()) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func testSmooth05_TabSwitches() {
        smoothRelaunch()
        measure(metrics: smoothTransitionMetrics(), options: smoothOptions()) {
            for tab in ["Library", "Settings", "Search", "Home"] {
                let button = app.tabBars.buttons[tab]
                if button.waitForExistence(timeout: 5) { button.tap() }
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
    }

    func testSmooth06_PushPopArtistAndPlaylist() {
        smoothRelaunch()
        let tab = app.tabBars.buttons["Library"]
        if tab.waitForExistence(timeout: 5) { tab.tap() }
        Thread.sleep(forTimeInterval: 1.5)
        measure(metrics: smoothTransitionMetrics(), options: smoothOptions()) {
            for name in ["Artists", "Playlists"] {
                guard smoothTap(name) else { continue }
                Thread.sleep(forTimeInterval: 1.2)
                let cell = app.collectionViews.cells.firstMatch
                if cell.waitForExistence(timeout: 3) {
                    cell.tap()
                    Thread.sleep(forTimeInterval: 1.5)
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                    Thread.sleep(forTimeInterval: 0.8)
                }
                app.navigationBars.buttons.element(boundBy: 0).tap()
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
    }

    func testSmooth07_MiniPlayerZoomAndDragDismiss() {
        smoothRelaunch()
        measure(metrics: smoothTransitionMetrics(), options: smoothOptions()) {
            app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)).tap()
            Thread.sleep(forTimeInterval: 1.5)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 1.2)
        }
    }

    func testSmooth08_NowPlayingPaneSwitches() {
        smoothOpenNowPlaying()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        measure(metrics: smoothHitchMetrics(), options: smoothOptions()) {
            for pane in ["Up Next", "Comments", "Tracklist", "Behind the Track"] {
                _ = smoothTap(pane, timeout: 3)
                Thread.sleep(forTimeInterval: 0.9)
            }
        }
    }

    func testSmooth09_NowPlayingSheets() throws {
        smoothOpenNowPlaying()
        guard app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Output' OR label CONTAINS[c] 'More'")).firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("No sheet entry points")
        }
        measure(metrics: smoothTransitionMetrics(), options: smoothOptions()) {
            for entry in ["Output", "More", "Cue"] {
                guard smoothTap(entry, timeout: 2) else { continue }
                Thread.sleep(forTimeInterval: 1.2)
                app.swipeDown(velocity: .fast)
                Thread.sleep(forTimeInterval: 0.9)
            }
        }
    }

    func testSmooth10_SwipeToSkipCarousel() {
        smoothOpenNowPlaying()
        measure(metrics: smoothHitchMetrics(), options: smoothOptions()) {
            smoothSwipe(fromX: 0.82, toX: 0.08, y: 0.42)
            Thread.sleep(forTimeInterval: 1.5)
            smoothSwipe(fromX: 0.82, toX: 0.08, y: 0.42)
            Thread.sleep(forTimeInterval: 1.5)
            smoothSwipe(fromX: 0.18, toX: 0.92, y: 0.42)
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    func testSmooth11_ScrubWaveform() {
        smoothOpenNowPlaying()
        measure(metrics: smoothHitchMetrics(), options: smoothOptions()) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.62))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.62))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    func testSmooth12_PullToRefresh() {
        smoothRelaunch()
        measure(metrics: smoothHitchMetrics(), options: smoothOptions()) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 2)
        }
    }

    func testSmooth13_UpNextScrollAndReorder() {
        smoothOpenNowPlaying()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        _ = smoothTap("Up Next", timeout: 5)
        Thread.sleep(forTimeInterval: 1.2)
        measure(metrics: smoothScrollMetrics(), options: smoothOptions()) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            let handle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Reorder'")).firstMatch
            if handle.exists {
                let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let to = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 4))
                from.press(forDuration: 0.5, thenDragTo: to)
            }
        }
    }

    func testSmooth14_CommentsAndTracklistScroll() {
        smoothOpenNowPlaying()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        measure(metrics: smoothScrollMetrics(), options: smoothOptions()) {
            for pane in ["Comments", "Tracklist"] {
                _ = smoothTap(pane, timeout: 3)
                Thread.sleep(forTimeInterval: 0.8)
                app.swipeUp(velocity: .fast)
                app.swipeDown(velocity: .fast)
            }
        }
    }

    func testSmooth15_TrackChange() {
        smoothOpenNowPlaying()
        let next = app.buttons.matching(NSPredicate(format: "label ==[c] 'Next Track'")).firstMatch
        guard next.waitForExistence(timeout: 5) else { return XCTFail("No Next Track button") }
        measure(metrics: smoothHitchMetrics(), options: smoothOptions()) {
            next.tap()
            Thread.sleep(forTimeInterval: 2)
            next.tap()
            Thread.sleep(forTimeInterval: 2)
        }
    }

    func testSmooth16_FirstOpenOfNowPlaying() {
        measure(metrics: smoothTransitionMetrics(), options: smoothOptions()) {
            smoothRelaunch()
            app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)).tap()
            Thread.sleep(forTimeInterval: 2)
        }
    }
}

extension IOSWalkthroughTests {
    private func uxStep(_ text: String) {
        note("step", text)
    }

    private func uxLaunch(_ environment: [String: String]) {
        app.terminate()
        app = XCUIApplication()
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        dismissPairingPrompt(timeout: 1)
    }

    @discardableResult
    private func uxTap(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 6) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            uxStep("MISSING \(name)")
            return false
        }
        element.tap()
        uxStep("tap \(name)")
        Thread.sleep(forTimeInterval: 1.2)
        return true
    }

    private func uxButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
    }

    func testUX01_WelcomeAndGuest() {
        uxLaunch(["SOUNDING_TV_WELCOME": "1", "SOUNDING_TV_UI_FIXTURE": "0"])
        capture("ux01-welcome")
        if uxTap(app.buttons["welcome.withoutSoundCloud"], "Use Without SoundCloud") { capture("ux01-music-step") }
        if uxTap(app.buttons["musicStep.notNow"], "Not Now") { capture("ux01-guest-library") }
        if uxTap(uxButton("Sign In"), "Sign In (Home)") { Thread.sleep(forTimeInterval: 3); capture("ux01-signin", tree: true) }
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Cancel','Close','Done','Back'}")).firstMatch
        if uxTap(close, "close sign-in") { capture("ux01-after-signin-close") }
        for tab in ["Library", "Settings", "Search"] {
            openTab(tab)
            capture("ux01-guest-\(tab)")
        }
    }

    func testUX02_FindAndPlay() {
        uxLaunch(["SOUNDING_TV_PHONE_TAB": "search"])
        capture("ux02-search-empty")
        let field = app.searchFields.firstMatch
        if uxTap(field, "search field") {
            field.typeText("Night Tapes")
            uxStep("type query")
            Thread.sleep(forTimeInterval: 2.5)
            capture("ux02-search-typed")
        }
        let artist = app.buttons.matching(NSPredicate(format: "label CONTAINS 'followers'")).firstMatch
        if uxTap(artist, "artist result") { capture("ux02-artist", tree: true) }
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Play' OR label CONTAINS[c] 'Shuffle'")).firstMatch
        if uxTap(play, "Play on artist") { Thread.sleep(forTimeInterval: 2); capture("ux02-playing") }
        openNowPlaying()
        uxStep("tap mini player (open Now Playing)")
        capture("ux02-np", tree: true)
        if uxTap(app.buttons["Next Track"].firstMatch, "Next Track") { capture("ux02-np-next") }
        for label in ["Comments", "Up Next", "Tracklist"] {
            if uxTap(app.buttons[label].firstMatch, label, timeout: 2) { capture("ux02-np-\(label)", tree: true) }
        }
        let close = app.buttons["Close Now Playing"]
        if !close.exists { app.swipeDown(velocity: .fast) }
        if uxTap(close, "Close Now Playing", timeout: 2) { capture("ux02-after-close") }
    }

    func testUX03_LibraryLikesQueue() {
        uxLaunch(["SOUNDING_TV_PHONE_TAB": "library"])
        capture("ux03-library")
        if uxTap(uxButton("Likes"), "Likes") { capture("ux03-likes") }
        if uxTap(uxButton("More"), "More (…)") { capture("ux03-more", tree: true) }
        if uxTap(uxButton("Sort"), "Sort By") { capture("ux03-sort", tree: true) }
        let bpm = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'BPM'")).firstMatch
        if uxTap(bpm, "BPM") { capture("ux03-sorted-bpm") }
        let row = app.collectionViews.cells.element(boundBy: 1)
        if row.waitForExistence(timeout: 4) {
            row.press(forDuration: 1.2)
            uxStep("long-press row")
            Thread.sleep(forTimeInterval: 1)
            capture("ux03-row-menu", tree: true)
            if uxTap(uxButton("Play Next"), "Play Next") { capture("ux03-after-playnext") }
        }
        let more = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'More'")).element(boundBy: 2)
        if more.waitForExistence(timeout: 2) {
            more.tap()
            uxStep("tap row ellipsis")
            Thread.sleep(forTimeInterval: 1)
            capture("ux03-ellipsis-menu", tree: true)
            if uxTap(uxButton("Add to Queue"), "Add to Queue") { capture("ux03-after-queue") }
        }
    }

    func testUX04_DownloadsFlow() {
        uxLaunch(["SOUNDING_TV_PHONE_TAB": "playlists"])
        capture("ux04-playlists")
        let first = app.collectionViews.cells.element(boundBy: 0)
        if uxTap(first, "first playlist") { capture("ux04-playlist-detail", tree: true) }
        let dl = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Download'")).firstMatch
        if uxTap(dl, "Download") { Thread.sleep(forTimeInterval: 1.5); capture("ux04-after-download", tree: true) }
        uxLaunch(["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "downloads"])
        capture("ux04-settings-downloads")
        if uxTap(app.staticTexts["Downloaded Music"], "Downloaded Music") { capture("ux04-downloaded-music", tree: true) }
    }

    func testUX05_OutputAndDevices() {
        uxLaunch(["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "devices", "SOUNDING_TV_TV_STORY": "neverPaired"])
        capture("ux05-devices-none", tree: true)
        if uxTap(app.buttons["Add Apple TV…"], "Add Apple TV") { Thread.sleep(forTimeInterval: 2); capture("ux05-add-sheet", tree: true) }
        uxLaunch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_OUTPUTS": "1", "SOUNDING_TV_TV_STORY": "connected"])
        capture("ux05-np-fake-outputs", tree: true)
        let output = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Output' OR label CONTAINS[c] 'AirPlay' OR label CONTAINS[c] 'Play On' OR label CONTAINS[c] 'Playing on'")).firstMatch
        if uxTap(output, "output button") { capture("ux05-output-menu", tree: true) }
    }

    func testUX06_Mix() {
        uxLaunch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "setlist"])
        capture("ux06-np-mix", tree: true)
        app.swipeUp()
        capture("ux06-np-mix-below")
        if uxTap(uxButton("Identify"), "Identify") { Thread.sleep(forTimeInterval: 2); capture("ux06-identify", tree: true) }
        uxLaunch(["SOUNDING_TV_PHONE_TAB": "library"])
        if uxTap(uxButton("Setlists"), "Setlists") { capture("ux06-setlists", tree: true) }
    }

    func testUX07_DecksAutoMix() {
        uxLaunch(["SOUNDING_TV_DJ": "1", "SOUNDING_TV_DJ_DEMO": "1"])
        capture("ux07-decks", tree: true)
        uxLaunch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        if uxButton("Auto Mix").waitForExistence(timeout: 4) { capture("ux07-np-automix", tree: true) } else { uxStep("MISSING Auto Mix entry in Now Playing") }
    }

    func testUX08_Errors() {
        for state in ["empty", "error", "loading"] {
            uxLaunch(["SOUNDING_TV_PHONE_TAB": "home", "SOUNDING_TV_FEED_STATE": state])
            if uxTap(app.buttons["Sounding"].firstMatch, "title menu", timeout: 2) {
                if uxTap(uxButton("Following"), "Following") { capture("ux08-feed-\(state)") }
            }
        }
        uxLaunch(["SOUNDING_TV_UI_FIXTURE": "0", "SOUNDING_TV_DISMISS_WELCOME": "1", "SOUNDING_TV_PHONE_TAB": "library"])
        capture("ux08-signedout-library", tree: true)
        uxLaunch(["SOUNDING_TV_UI_FIXTURE": "0", "SOUNDING_TV_DISMISS_WELCOME": "1", "SOUNDING_TV_PHONE_TAB": "search"])
        capture("ux08-signedout-search")
        uxLaunch(["SOUNDING_TV_UI_FIXTURE": "0", "SOUNDING_TV_DISMISS_WELCOME": "1", "SOUNDING_TV_PHONE_TAB": "settings"])
        capture("ux08-signedout-settings")
    }

    func testUX09_UpNextReorder() {
        uxLaunch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "upNext"])
        capture("ux09-up-next", tree: true)
        func row(_ n: Int) -> XCUIElement {
            app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "\(n). ")).firstMatch
        }
        func order() -> String {
            (1...5).map { row($0).exists ? row($0).label : "-" }.joined(separator: "\n")
        }
        note("order-before", order())
        if row(3).exists {
            let from = row(1).coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5))
            let to = row(3).coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.9))
            from.press(forDuration: 1.0, thenDragTo: to)
            uxStep("drag handle row1 -> row3")
            Thread.sleep(forTimeInterval: 1.5)
            capture("ux09-after-drag")
            note("order-after", order())
        }
        let edit = app.buttons["Edit"].firstMatch
        uxStep(edit.exists ? "Edit button exists" : "no Edit button")
    }
}

@MainActor
final class TrafficWalkTests: XCTestCase {
    private var app: XCUIApplication!

    func testTrafficWalkFiveMinutes() {
        continueAfterFailure = true
        let started = Date()
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_SC_MOCK"] = "1"
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        app.launchEnvironment["SOUNDING_TV_TRAFFIC_ECHO"] = "0"
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("TRAFFIC_ENV_") {
            app.launchEnvironment[String(key.dropFirst("TRAFFIC_ENV_".count))] = value
        }
        app.launch()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 20)
        dismissSheets()
        pause(8)

        open(tab: "Home")
        app.swipeUp()
        pause(3)
        app.swipeDown(velocity: .fast)
        pause(4)

        open(tab: "Library")
        if tap(containing: "Likes") {
            pause(3)
            for _ in 0..<6 {
                app.swipeUp()
                pause(2)
            }
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            pause(2)
            if let row = firstRow() {
                row.tap()
                pause(6)
                app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)).tap()
                pause(4)
                app.swipeUp()
                pause(2)
                for pane in ["Comments", "Tracklist", "Behind the Track"] {
                    select(pane: pane)
                    pause(5)
                }
                app.swipeDown(velocity: .fast)
                pause(1)
                app.swipeDown(velocity: .fast)
                pause(2)
            }
            back()
        }

        open(tab: "Library")
        if tap(containing: "Following") {
            let cell = app.collectionViews.cells.firstMatch
            if cell.waitForExistence(timeout: 8) { cell.tap() }
            pause(5)
            app.swipeUp()
            pause(3)
            app.swipeUp()
            pause(3)
            back()
            back()
        }

        open(tab: "Search")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            pause(1)
            field.typeText("dead")
            pause(1.2)
            field.typeText("mau5")
            pause(5)
            app.swipeUp()
            pause(3)
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
            pause(1)
        }

        open(tab: "Home")
        let remaining = 300 - Date().timeIntervalSince(started)
        if remaining > 0 { pause(remaining) }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "traffic-walk-end"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func dismissSheets() {
        for title in ["Confirm Sign-In", "Confirm Code"] {
            if app.navigationBars[title].waitForExistence(timeout: 2) {
                app.buttons["Cancel"].firstMatch.tap()
                pause(1)
            }
        }
    }

    private func open(tab label: String) {
        let button = app.tabBars.buttons[label]
        if button.waitForExistence(timeout: 5) {
            button.tap()
        } else if app.buttons[label].firstMatch.exists {
            app.buttons[label].firstMatch.tap()
        }
        pause(2)
    }

    private func tap(containing text: String) -> Bool {
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        guard button.waitForExistence(timeout: 6) else { return false }
        button.tap()
        pause(1.5)
        return true
    }

    private func firstRow() -> XCUIElement? {
        [app.collectionViews.cells.firstMatch, app.tables.cells.firstMatch, app.scrollViews.buttons.element(boundBy: 0)]
            .first { $0.waitForExistence(timeout: 8) && $0.isHittable }
    }

    private func select(pane name: String) {
        let segment = app.segmentedControls.buttons[name].firstMatch
        if segment.waitForExistence(timeout: 3) {
            segment.tap()
        } else {
            let fallback = app.buttons[name].firstMatch
            if fallback.waitForExistence(timeout: 2) { fallback.tap() }
        }
    }

    private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists { button.tap() }
        pause(1)
    }
}

extension IOSWalkthroughTests {
    func testArt01_LibraryAndSearchShots() {
        Thread.sleep(forTimeInterval: 2)
        snap("art-home")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        snap("art-home-scrolled")
        app.swipeDown()
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1)
        openTab("Library")
        Thread.sleep(forTimeInterval: 1.5)
        snap("art-library")
        if tapRow(containing: "Likes") {
            Thread.sleep(forTimeInterval: 2)
            snap("art-likes")
            goBack()
        }
        if tapRow(containing: "Playlists") {
            Thread.sleep(forTimeInterval: 2)
            snap("art-playlists")
            let cell = app.collectionViews.cells.firstMatch
            if cell.waitForExistence(timeout: 8) { cell.tap() }
            Thread.sleep(forTimeInterval: 2.5)
            snap("art-playlist-detail")
            goBack()
            goBack()
        }
        if tapRow(containing: "Following") {
            Thread.sleep(forTimeInterval: 2)
            snap("art-following")
            let cell = app.collectionViews.cells.firstMatch
            if cell.waitForExistence(timeout: 8) { cell.tap() }
            Thread.sleep(forTimeInterval: 2.5)
            snap("art-artist")
            goBack()
            goBack()
        }
        openTab("Search")
        Thread.sleep(forTimeInterval: 2)
        snap("art-search")
    }

    func testArt02_NowPlayingWithoutArtwork() {
        relaunch(with: ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_ARTWORK": "none", "SOUNDING_TV_FAKE_INDEX": "3"])
        Thread.sleep(forTimeInterval: 6)
        snap("art-np-noart")
        relaunch(with: ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_ARTWORK": "none", "SOUNDING_TV_FAKE_INDEX": "3", "SOUNDING_TV_NOW_PLAYING_REVIEW": "comments"])
        Thread.sleep(forTimeInterval: 5)
        snap("art-np-comments")
        relaunch(with: ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_ARTWORK": "none", "SOUNDING_TV_FAKE_INDEX": "3", "SOUNDING_TV_NOW_PLAYING_REVIEW": "upNext"])
        Thread.sleep(forTimeInterval: 5)
        snap("art-np-upnext")
    }

    private func measureScrolling() {
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollDecelerationMetric,
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
                XCTClockMetric(),
            ],
            options: measureOptions()
        ) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func testPerf06_ScrollHome() {
        relaunch(with: ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_FRAME_PROBE": "1"])
        Thread.sleep(forTimeInterval: 4)
        measureScrolling()
    }

    func testPerf07_ScrollLikes() {
        relaunch(with: ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_FRAME_PROBE": "1"])
        openLibraryLikes(app)
        Thread.sleep(forTimeInterval: 2)
        measureScrolling()
    }
}

@MainActor
final class IOSUXFixesTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(
        _ environment: [String: String] = [:],
        arguments: [String] = []
    ) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "1"
        app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        if !arguments.contains("-UIPreferredContentSizeCategoryName") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        }
        app.launchArguments += arguments
        app.launch()
        Thread.sleep(forTimeInterval: 3)
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func queueRow(_ position: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "^(Remove, )?\\Q\(position)\\E\\. .*"))
            .firstMatch
    }

    private func reorderHandle(_ position: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder \(position). ")).firstMatch
    }

    private func title(of row: XCUIElement) -> String {
        let label = row.label.replacingOccurrences(of: "Remove, ", with: "").replacingOccurrences(of: "Reorder ", with: "")
        let body = label.drop { $0 != " " }.dropFirst()
        return String(body.prefix { $0 != "," })
    }

    func testUpNextRowsReorderByDragging() {
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "upNext"])
        XCTAssertTrue(queueRow(3).waitForExistence(timeout: 10))
        let first = title(of: queueRow(1))
        let second = title(of: queueRow(2))
        let third = title(of: queueRow(3))
        XCTAssertFalse(first.isEmpty)

        let source = reorderHandle(1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = reorderHandle(3).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.2))
        source.press(forDuration: 0.5, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 4)
        capture("reorder-after-drag")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "reorder-tree"
        tree.lifetime = .keepAlways
        add(tree)

        XCTAssertEqual(title(of: queueRow(1)), second)
        XCTAssertEqual(title(of: queueRow(2)), third)
        XCTAssertEqual(title(of: queueRow(3)), first)
    }

    func testUpNextContextMenuRemovesTheRow() {
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "upNext"])
        XCTAssertTrue(queueRow(2).waitForExistence(timeout: 10))
        let first = title(of: queueRow(1))
        let second = title(of: queueRow(2))
        XCTAssertFalse(app.buttons["Delete"].exists)
        queueRow(2).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).press(forDuration: 1.2)
        capture("reorder-remove")
        let remove = app.buttons["Remove from Queue"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(title(of: queueRow(2)), second)
        XCTAssertEqual(title(of: queueRow(1)), first)
    }

    func testMiniPlayerContextMenuOffersOutputsAndTrackActions() {
        launch(["SOUNDING_TV_PHONE_TAB": "library", "SOUNDING_TV_FAKE_OUTPUTS": "1"])
        let mini = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Now Playing'")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1)
        capture("mini-context-menu")
        func item(_ label: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        XCTAssertTrue(item("Play Next").waitForExistence(timeout: 3))
        XCTAssertTrue(item("Go to Artist").exists)
        XCTAssertTrue(item("Living Room").exists)
        XCTAssertTrue(item("MacBook Pro").exists)
    }

    func testMiniPlayerStillScrubsOnLongPressAndDrag() {
        launch(["SOUNDING_TV_PHONE_TAB": "library"])
        let mini = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Now Playing'")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = mini.coordinate(withNormalizedOffset: CGVector(dx: 1.4, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.5)
        capture("mini-scrub-end")
    }

    func testNowPlayingBottomRowShowsCaptionsAtAccessibilitySizes() {
        launch(
            ["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"],
            arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        )
        capture("bottom-row-accessibility")
        XCTAssertTrue(app.staticTexts["Output"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Up Next"].exists)
    }

    func testBottomRowHasNoCaptionsAtDefaultSize() {
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        XCTAssertTrue(app.buttons["Output"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Output"].exists)
    }

    func testTrafficStopShowsOneDismissibleNotice() {
        let until = Int(Date().timeIntervalSince1970) + 3600
        launch(
            ["SOUNDING_TV_PHONE_TAB": "library"],
            arguments: ["-red.forbes.sounding.soundcloud.trafficBlockedUntil", "\(until)"]
        )
        let notice = app.staticTexts["SoundCloud is limiting requests"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        capture("traffic-notice")
        XCTAssertEqual(app.staticTexts.matching(identifier: "SoundCloud is limiting requests").count, 1)
        app.buttons["Dismiss"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(notice.exists)
    }
}

extension IOSUXFixesTests {
    func testSortingByTempoShowsDashesAndTheUnanalysedFooter() {
        launch(["SOUNDING_TV_PHONE_TAB": "library"])
        let liked = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Likes'")).firstMatch
        XCTAssertTrue(liked.waitForExistence(timeout: 10))
        liked.tap()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let sort = app.buttons["Sort By"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.tap()
        let tempo = app.descendants(matching: .any)["BPM"].firstMatch
        XCTAssertTrue(tempo.waitForExistence(timeout: 5))
        tempo.tap()
        Thread.sleep(forTimeInterval: 1.5)
        capture("sort-bpm")
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not yet analysed'")).firstMatch
        var swipes = 0
        while !footer.exists, swipes < 10 {
            app.swipeUp(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(footer.exists)
        capture("sort-bpm-footer")
    }
}

@MainActor
final class IOSDriveShotTests: XCTestCase {
    private var app: XCUIApplication!
    private var directory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRIVE_DIR"] ?? NSTemporaryDirectory()) }
    private var largeType: Bool { ProcessInfo.processInfo.environment["DRIVE_XL"] == "1" }

    private func launch(_ environment: [String: String] = [:]) {
        continueAfterFailure = true
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "1"
        app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        if largeType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraLarge"]
        }
        app.launch()
        Thread.sleep(forTimeInterval: 4)
    }

    private func shot(_ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func settle(_ seconds: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: seconds) }

    @discardableResult
    private func tapRow(_ text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        for query in [app.buttons, app.cells, app.staticTexts] {
            let element = query.matching(predicate).firstMatch
            if element.waitForExistence(timeout: 3), element.isHittable {
                element.tap()
                settle(2.5)
                return true
            }
        }
        return false
    }

    private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists { button.tap() }
        settle(1)
    }

    func testDriveLibrary() {
        launch(["SOUNDING_TV_PHONE_TAB": "library"])
        for section in ["Likes", "Sets", "Setlists", "Playlists", "Following"] {
            if tapRow(section) {
                shot("lib-\(section.lowercased())")
                app.swipeUp()
                settle(1)
                shot("lib-\(section.lowercased())-scrolled")
                if section == "Playlists" || section == "Following" {
                    app.swipeDown()
                    let cell = app.collectionViews.cells.firstMatch
                    if cell.waitForExistence(timeout: 4) {
                        cell.tap()
                        settle(3)
                        shot(section == "Playlists" ? "lib-playlist-detail" : "lib-artist-detail")
                        app.swipeUp()
                        settle(1)
                        shot(section == "Playlists" ? "lib-playlist-detail-scrolled" : "lib-artist-detail-scrolled")
                        back()
                    }
                }
                back()
            }
        }
    }

    func testDriveHomeAndSearch() {
        launch(["SOUNDING_TV_PHONE_TAB": "home"])
        shot("home-top")
        app.swipeUp()
        settle(1)
        shot("home-scrolled")
        app.swipeUp()
        settle(1)
        shot("home-scrolled2")
        launch(["SOUNDING_TV_PHONE_TAB": "home", "SOUNDING_TV_FEED_STATE": "loaded"])
        shot("home-following")
        launch(["SOUNDING_TV_PHONE_TAB": "search"])
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            settle(1)
            shot("search-focused")
            field.typeText("night tapes")
            app.keyboards.buttons["Search"].tap()
            settle(3)
            shot("search-results")
            app.swipeUp()
            settle(1)
            shot("search-results-scrolled")
        }
    }

    func testDriveAddAppleTV() {
        for (name, story) in [("empty", "neverPaired"), ("connected", "connected")] {
            launch(["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "devices", "SOUNDING_TV_TV_STORY": story])
            shot("add-0-devices-\(name)")
            let add = app.buttons["Add Apple TV…"].firstMatch
            if add.waitForExistence(timeout: 5) {
                add.tap()
                settle(2)
                shot("add-1-sheet-\(name)")
            }
        }
        for nearby in ["priming", "denied", "listening", "checking", "found", "signingIn", "failed"] {
            launch(["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "devices", "SOUNDING_TV_TV_STORY": "neverPaired", "SOUNDING_TV_NEARBY_STORY": nearby])
            let button = app.buttons["Add Apple TV…"].firstMatch
            if button.waitForExistence(timeout: 4) {
                button.tap()
                settle(2)
                shot("add-2-\(nearby)")
                let useQR = app.buttons["Use QR Code Instead"].firstMatch
                if nearby == "priming", useQR.exists {
                    useQR.tap()
                    settle(2)
                    shot("add-3-qr")
                }
            }
        }
    }

    private func probeScroll(_ label: String, _ environment: [String: String], _ prepare: () -> Void = {}) {
        launch(environment.merging(["SOUNDING_TV_FRAME_PROBE": label]) { _, new in new })
        prepare()
        settle(2)
        for _ in 0..<4 {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
        settle(1)
    }

    func testPerfHome() {
        probeScroll("home", ["SOUNDING_TV_PHONE_TAB": "home"])
    }

    func testPerfLikes() {
        probeScroll("likes", ["SOUNDING_TV_PHONE_TAB": "library"]) { tapRow("Likes") }
    }

    func testPerfSearchResults() {
        probeScroll("search", ["SOUNDING_TV_PHONE_TAB": "search"]) {
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("night tapes")
                app.keyboards.buttons["Search"].tap()
                settle(3)
            }
        }
    }

    func testPerfArtist() {
        probeScroll("artist", ["SOUNDING_TV_UI_DESTINATION": "artist"])
    }

    func testPerfPlaylist() {
        probeScroll("playlist", ["SOUNDING_TV_UI_DESTINATION": "playlist"])
    }
}

final class SignInAutoFillTests: XCTestCase {
    func testSignInFieldAutoFill() {
        let signIn = XCUIApplication()
        signIn.launchEnvironment["SOUNDING_TV_SIGNIN"] = "1"
        signIn.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        signIn.launch()
        let field = signIn.webViews.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        XCTAssertTrue(signIn.keyboards.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 12)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "sign-in-autofill"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
