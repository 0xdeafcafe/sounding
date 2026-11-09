import XCTest

@MainActor
final class PhoneE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var timings: [String] = []

    private static let screenBudget: TimeInterval = 3
    private static let launchBudget: TimeInterval = 20
    private static let repeats = Int(ProcessInfo.processInfo.environment["E2E_REPEATS"] ?? "") ?? 3
    private static var rateLimited = false
    private static let signInNote = "This simulator is not signed in to SoundCloud. Ask the owner to sign in on it, then rerun."

    override func setUpWithError() throws {
        try super.setUpWithError()
        if Self.rateLimited { throw XCTSkip("SoundCloud rate-limited an earlier test; stopping to protect the account.") }
        continueAfterFailure = true
        timings = []
    }

    override func tearDown() {
        let log = XCTAttachment(string: timings.joined(separator: "\n"))
        log.name = "timings"
        log.lifetime = .keepAlways
        add(log)
        app?.terminate()
        super.tearDown()
    }

    private func launch(_ environment: [String: String] = [:]) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        let started = Date()
        app.launch()
        let ready = app.tabBars.firstMatch.waitForExistence(timeout: Self.launchBudget)
        record("launch", since: started, ok: ready)
        XCTAssertTrue(ready, ready ? "" : "The tab bar never appeared after launch. \(Self.signInNote)")
        dismissStrays()
        sleep(2)
    }

    private func record(_ name: String, since started: Date, ok: Bool, budget: TimeInterval = PhoneE2ETests.screenBudget) {
        let elapsed = Date().timeIntervalSince(started)
        timings.append(String(format: "%@ %.2fs%@", name, elapsed, ok ? "" : " MISSING"))
        if ok, elapsed > budget, name != "launch" {
            XCTFail(String(format: "%@ took %.2fs, over the %.1fs budget.", name, elapsed, budget))
        }
    }

    private func alive(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        if app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'limiting requests'")).count > 0 {
            Self.rateLimited = true
            continueAfterFailure = false
            XCTFail("SoundCloud is limiting requests after \(context). Stopping.", file: file, line: line)
        }
        XCTAssertEqual(app.state, .runningForeground, "The app is no longer running after \(context).", file: file, line: line)
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dismissStrays() {
        for label in ["Not Now", "Cancel", "Don’t Allow", "Don't Allow"] {
            let button = app.alerts.buttons[label].firstMatch
            if button.exists { button.tap() }
        }
    }

    @discardableResult
    private func expect(_ element: XCUIElement, _ name: String, budget: TimeInterval = PhoneE2ETests.screenBudget, started: Date = Date()) -> Bool {
        let found = poll(element, timeout: max(budget * 3, 8))
        record(name, since: started, ok: found, budget: budget)
        if !found {
            XCTFail("\(name) never appeared.")
            capture("missing-\(name)")
        }
        alive(name)
        return found
    }

    private func poll(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            usleep(100_000)
        }
        return element.exists
    }

    private func navTitle(_ title: String) -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier == %@", title)).firstMatch
    }

    private func element(labelled label: String, exact: Bool = true) -> XCUIElement {
        let predicate = exact
            ? NSPredicate(format: "label == %@", label)
            : NSPredicate(format: "label BEGINSWITH %@", label)
        return app.descendants(matching: .any).matching(predicate).matching(NSPredicate(format: "elementType IN %@", [
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.staticText.rawValue,
        ])).firstMatch
    }

    @discardableResult
    private func tap(_ label: String, exact: Bool = true, scrolls: Int = 4) -> Bool {
        let target = element(labelled: label, exact: exact)
        for attempt in 0...scrolls {
            if target.waitForExistence(timeout: attempt == 0 ? 3 : 0.6), target.isHittable {
                target.tap()
                return true
            }
            app.swipeUp()
        }
        XCTFail("Could not find \(label) to tap.")
        capture("untappable-\(label)")
        return false
    }

    private func tab(_ label: String) {
        let button = app.tabBars.buttons[label]
        if button.waitForExistence(timeout: 4) {
            button.tap()
        } else {
            app.buttons[label].firstMatch.tap()
        }
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        let button = bar.buttons.element(boundBy: 0)
        if button.exists, button.isHittable {
            button.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }
    }

    private func firstRow() -> XCUIElement? {
        let candidates = [app.collectionViews.cells.firstMatch, app.tables.cells.firstMatch]
        return candidates.first { $0.waitForExistence(timeout: 6) && $0.isHittable }
    }

    func testE2E01_TabsCycle() {
        launch()
        let roots: [(String, XCUIElement)] = [
            ("Home", navTitle("Sounding")),
            ("Library", navTitle("Library")),
            ("Settings", navTitle("Settings")),
            ("Search", app.searchFields.firstMatch),
        ]
        for round in 0..<Self.repeats {
            for (label, marker) in roots {
                let button = app.tabBars.buttons[label]
                _ = button.waitForExistence(timeout: 4)
                let started = Date()
                button.tap()
                expect(marker, "tab-\(label)-\(round)", started: started)
            }
        }
        capture("tabs-done")
    }

    private static let librarySections = ["Tracks", "Albums", "Artists", "Sets", "Setlists", "Downloads", "Mixes"]

    func testE2E02_LibrarySectionsPushPop() {
        openLibrary()
        for round in 0..<max(2, Self.repeats / 2) {
            for section in Self.librarySections {
                let started = Date()
                guard tap(section) else { continue }
                expect(navTitle(section), "library-\(section)-\(round)", started: started)
                if round == 0 { capture("library-\(section)") }
                back()
                expect(navTitle("Library"), "library-back-\(section)-\(round)")
            }
        }
    }

    func testE2E03_LibraryOpenItems() {
        openLibrary()

        tap("Playlists")
        expect(navTitle("Playlists"), "playlists")
        for round in 0..<3 {
            guard let row = firstRow() else { XCTFail("No playlist rows."); break }
            row.tap()
            sleep(1)
            alive("open playlist \(round)")
            capture("playlist-\(round)")
            back()
            expect(navTitle("Playlists"), "playlists-back-\(round)")
        }
        back()

        tap("Following")
        expect(navTitle("Following"), "following")
        for round in 0..<3 {
            guard let row = firstRow() else { XCTFail("No artist rows."); break }
            row.tap()
            sleep(1)
            alive("open artist \(round)")
            capture("artist-\(round)")
            back()
            expect(navTitle("Following"), "following-back-\(round)")
        }
        back()

        tap("Decks")
        sleep(2)
        alive("open decks")
        capture("decks")
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Done"])).firstMatch
        if close.waitForExistence(timeout: 4) { close.tap() } else { app.swipeDown(velocity: .fast) }
        expect(navTitle("Library"), "decks-closed")
    }

    private var miniPlayer: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Now Playing,'")).firstMatch
    }

    private var closeNowPlaying: XCUIElement {
        app.buttons["Close Now Playing"].firstMatch
    }

    private func openLibrary() {
        launch(["SOUNDING_TV_PHONE_TAB": "library"])
        XCTAssertTrue(navTitle("Library").waitForExistence(timeout: 8))
        let signedOut = app.buttons["Account, signed out"].firstMatch
        if signedOut.waitForExistence(timeout: 3) {
            continueAfterFailure = false
            XCTFail(Self.signInNote)
        }
    }

    private func startPlayback(from section: String) -> Bool {
        openLibrary()
        guard tap(section) else { return false }
        expect(navTitle(section), "section-\(section)")
        guard let row = firstRow() else {
            XCTFail("No rows in \(section).")
            return false
        }
        let started = Date()
        row.tap()
        let playing = miniPlayer.waitForExistence(timeout: 10)
        record("play-\(section)-miniplayer", since: started, ok: playing)
        XCTAssertTrue(playing, "Tapping a \(section) row never showed the mini player.")
        alive("start playback")
        return playing
    }

    func testE2E04_NowPlayingOpenCloseAndTransport() {
        guard startPlayback(from: "Likes") else { return }
        for round in 0..<Self.repeats {
            let started = Date()
            miniPlayer.tap()
            guard expect(closeNowPlaying, "np-open-\(round)", started: started) else { return }
            if round == 0 { capture("np-open") }
            closeNowPlaying.tap()
            let closed = Date()
            let gone = closeNowPlaying.waitForNonExistence(timeout: 6)
            record("np-close-\(round)", since: closed, ok: gone)
            XCTAssertTrue(gone, "Now Playing did not close.")
            alive("np-close-\(round)")
        }

        miniPlayer.tap()
        guard expect(closeNowPlaying, "np-open-transport") else { return }
        let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Pause"])).firstMatch
        for round in 0..<Self.repeats {
            guard toggle.waitForExistence(timeout: 4), toggle.isHittable else {
                XCTFail("No play/pause button in Now Playing.")
                capture("np-no-toggle")
                break
            }
            toggle.tap()
            usleep(400_000)
            alive("play/pause \(round)")
        }
        let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next", "Next Track", "Skip Forward"])).firstMatch
        for round in 0..<Self.repeats {
            guard next.waitForExistence(timeout: 4), next.isHittable else {
                XCTFail("No next button in Now Playing.")
                capture("np-no-next")
                break
            }
            next.tap()
            usleep(600_000)
            alive("next \(round)")
        }
        let previous = app.buttons.matching(NSPredicate(format: "label IN %@", ["Previous", "Previous Track", "Skip Back"])).firstMatch
        for round in 0..<3 where previous.exists && previous.isHittable {
            previous.tap()
            usleep(600_000)
            alive("previous \(round)")
        }
        capture("np-after-transport")

        let scrubber = app.otherElements.matching(NSPredicate(format: "label == 'Playback position'")).firstMatch
        if scrubber.waitForExistence(timeout: 4) {
            for (start, end) in [(0.1, 0.8), (0.8, 0.2), (0.2, 0.5), (0.5, 0.95), (0.9, 0.05)] as [(CGFloat, CGFloat)] {
                let origin = scrubber.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.3))
                let destination = scrubber.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.3))
                origin.press(forDuration: 0.1, thenDragTo: destination, withVelocity: .default, thenHoldForDuration: 0.1)
                alive("scrub \(start)→\(end)")
            }
        } else {
            XCTFail("No scrubber in Now Playing.")
            capture("np-no-scrubber")
        }
        capture("np-after-scrub")
        closeNowPlaying.tap()
        XCTAssertTrue(closeNowPlaying.waitForNonExistence(timeout: 6))
        alive("np final close")
    }

    func testE2E05_NowPlayingPanesAndQueue() {
        guard startPlayback(from: "Likes") else { return }
        miniPlayer.tap()
        guard expect(closeNowPlaying, "np-open") else { return }
        let panes = ["Up Next", "Lyrics", "Comments", "Tracklist", "Details"]
        for round in 0..<3 {
            for pane in panes {
                let button = app.buttons[pane].firstMatch
                guard button.waitForExistence(timeout: 2), button.isHittable else { continue }
                let started = Date()
                button.tap()
                usleep(700_000)
                record("pane-\(pane)-\(round)", since: started, ok: true)
                alive("pane \(pane)")
                if round == 0 { capture("pane-\(pane)") }
            }
        }
        let upNext = app.buttons["Up Next"].firstMatch
        if upNext.exists, upNext.isHittable {
            upNext.tap()
            sleep(1)
            for _ in 0..<3 { app.swipeUp() }
            for _ in 0..<3 { app.swipeDown() }
            alive("queue scroll")
            capture("queue")
        }
        if closeNowPlaying.exists, closeNowPlaying.isHittable { closeNowPlaying.tap() }
        alive("panes close")
    }

    func testE2E06_PlayASet() throws {
        openLibrary()
        guard tap("Sets") else { return }
        expect(navTitle("Sets"), "sets")
        guard let row = firstRow() else { throw XCTSkip("This account has no sets.") }
        row.tap()
        guard expect(miniPlayer, "set-miniplayer", budget: 10) else { return }
        miniPlayer.tap()
        expect(closeNowPlaying, "set-np-open")
        capture("set-np")
        for _ in 0..<3 {
            app.swipeUp()
            app.swipeDown()
        }
        alive("set scroll")
        if closeNowPlaying.exists, closeNowPlaying.isHittable { closeNowPlaying.tap() }
        alive("set close")
    }

    func testE2E07_SearchAndOpenResults() {
        launch(["SOUNDING_TV_PHONE_TAB": "search"])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "No search field.")
        for (round, query) in ["house", "techno", "ambient"].enumerated() {
            field.tap()
            if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
                let clear = field.buttons["Clear text"].firstMatch
                if clear.exists { clear.tap() }
            }
            field.typeText(query)
            app.keyboards.buttons["search"].firstMatch.tapIfExists()
            sleep(2)
            alive("search \(query)")
            if round == 0 { capture("search-\(query)") }
            if let row = firstRow() {
                row.tap()
                sleep(1)
                alive("open result \(query)")
                if round == 0 { capture("search-result-\(query)") }
                if app.navigationBars.firstMatch.buttons.element(boundBy: 0).exists {
                    back()
                    sleep(1)
                }
                if closeNowPlaying.exists { closeNowPlaying.tap() }
            }
        }
    }

    private static let settingsPages = [
        "Account", "Subscription", "Activity", "Scout", "Messages",
        "Playback", "Alarms", "Music Analysis", "Devices", "Home Lighting",
        "Downloads", "Music Folders", "About & Advanced",
    ]

    func testE2E08_SettingsEveryPage() {
        launch(["SOUNDING_TV_PHONE_TAB": "settings"])
        XCTAssertTrue(navTitle("Settings").waitForExistence(timeout: 8))
        for round in 0..<2 {
            for page in Self.settingsPages {
                guard tap(page, exact: false) else { continue }
                sleep(1)
                alive("settings \(page)")
                if round == 0 { capture("settings-\(page)") }
                for _ in 0..<2 { app.swipeUp() }
                alive("settings scroll \(page)")
                back()
                let started = Date()
                let home = navTitle("Settings")
                if !home.waitForExistence(timeout: 2) { back() }
                expect(home, "settings-back-\(page)-\(round)", started: started)
                for _ in 0..<3 { app.swipeDown() }
            }
        }
    }

    func testE2E09_HomeShelvesOpenAndBack() {
        launch(["SOUNDING_TV_PHONE_TAB": "home"])
        XCTAssertTrue(navTitle("Sounding").waitForExistence(timeout: 8))
        capture("home")
        for round in 0..<4 {
            let screen = app.windows.firstMatch.frame
            let tiles = app.scrollViews.buttons.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty && screen.contains($0.frame) }
            guard round < tiles.count else { break }
            tiles[round].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(2)
            alive("home tile \(round)")
            capture("home-tile-\(round)")
            if closeNowPlaying.exists { closeNowPlaying.tap(); sleep(1) }
            let done = app.buttons["Done"].firstMatch
            if done.exists, done.isHittable { done.tap(); sleep(1) }
            if !navTitle("Sounding").exists { back(); sleep(1) }
            alive("home back \(round)")
        }
        for _ in 0..<4 { app.swipeUp() }
        for _ in 0..<4 { app.swipeDown() }
        alive("home scroll")
    }

    private func smoothOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    func testE2E10_HitchesTabSwitching() {
        launch()
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: smoothOptions()) {
            for label in ["Library", "Settings", "Search", "Home"] {
                tab(label)
                usleep(500_000)
            }
        }
        alive("hitch tabs")
    }

    func testE2E11_HitchesLibraryPushPop() {
        openLibrary()
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: smoothOptions()) {
            for section in ["Likes", "Playlists"] {
                tap(section)
                _ = navTitle(section).waitForExistence(timeout: 4)
                app.swipeUp()
                app.swipeDown()
                back()
                _ = navTitle("Library").waitForExistence(timeout: 4)
            }
        }
        alive("hitch library")
    }

    func testE2E12_HitchesNowPlaying() {
        guard startPlayback(from: "Likes") else { return }
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: smoothOptions()) {
            miniPlayer.tap()
            _ = closeNowPlaying.waitForExistence(timeout: 4)
            usleep(500_000)
            closeNowPlaying.tap()
            _ = closeNowPlaying.waitForNonExistence(timeout: 4)
        }
        alive("hitch now playing")
    }

    func testE2E13_IdleCPU() {
        guard startPlayback(from: "Likes") else { return }
        tab("Library")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            sleep(5)
        }
        alive("idle")
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if exists, isHittable { tap() }
    }
}
