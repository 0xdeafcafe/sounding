import XCTest

@MainActor
final class TVE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var timings: [String] = []

    private static let repeats = Int(ProcessInfo.processInfo.environment["E2E_REPEATS"] ?? "") ?? 3
    private static var rateLimited = false
    private static let signInNote = "This Apple TV is not signed in to SoundCloud. Ask the owner to sign in on it, then rerun."
    private static let screenBudget: TimeInterval = 3
    private static let sidebarTabs = [
        "sidebar.tab.home", "sidebar.tab.search", "sidebar.tab.library",
        "sidebar.tab.decks", "sidebar.tab.nowPlaying", "sidebar.tab.settings",
    ]

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

    private func launch(tab: String, _ extra: [String: String] = [:], enters: Bool = true) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        app.launchEnvironment["SOUNDING_TV_TAB"] = tab
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launchArguments += ["-red.forbes.sounding.didSeeTVWelcome", "YES"]
        let started = Date()
        app.launch()
        var focused = false
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if focusedElement() != nil { focused = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        record("launch-\(tab)", since: started, ok: focused, budget: 25)
        XCTAssertTrue(focused, "\(tab) launched with nothing focused.")
        alive("launch \(tab)")
        requireSignedIn()
        if enters, focusIsOnSidebar() { _ = enterContent(tab) }
    }

    private func record(_ name: String, since started: Date, ok: Bool, budget: TimeInterval = TVE2ETests.screenBudget) {
        let elapsed = Date().timeIntervalSince(started)
        timings.append(String(format: "%@ %.2fs%@", name, elapsed, ok ? "" : " MISSING"))
        if ok, elapsed > budget {
            XCTFail(String(format: "%@ took %.2fs, over the %.1fs budget.", name, elapsed, budget))
        }
    }

    private func requireSignedIn() {
        for _ in 0..<3 where !focusIsOnSidebar() { press(.up, settle: 0.6) }
        let home = app.descendants(matching: .any)["sidebar.tab.home"]
        let signedIn = home.waitForExistence(timeout: 4)
        if focusIsOnSidebar() { press(.down, settle: 0.6) }
        if !signedIn {
            continueAfterFailure = false
            XCTFail(Self.signInNote)
        }
    }

    private func alive(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        if app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'limiting requests' OR label CONTAINS[c] 'rate limit'")).count > 0 {
            Self.rateLimited = true
            continueAfterFailure = false
            XCTFail("SoundCloud is limiting requests after \(context). Stopping.", file: file, line: line)
        }
        XCTAssertEqual(app.state, .runningForeground, "The app is no longer running after \(context).", file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func press(_ button: XCUIRemote.Button, settle: TimeInterval = 0.5) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
    }

    private func focusedElement() -> XCUIElement? {
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
        guard all.count > 0 else { return nil }
        let element = all.element(boundBy: 0)
        guard element.identifier.isEmpty else { return element }
        let identified = element.descendants(matching: .any).matching(NSPredicate(format: "identifier != ''"))
        return identified.count > 0 ? identified.element(boundBy: 0) : element
    }

    private func focusKey() -> String {
        guard let focused = focusedElement() else { return "nil" }
        return "\(focused.identifier)|\(focused.label)"
    }

    private func focusIsOnSidebar() -> Bool {
        Self.sidebarTabs.contains(focusedElement()?.identifier ?? "")
    }

    private func waitForFocus(where condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    @discardableResult
    private func selectTab(_ identifier: String) -> Bool {
        for _ in 0..<5 where !focusIsOnSidebar() { press(.menu, settle: 0.8) }
        guard focusIsOnSidebar() else {
            XCTFail("Could not reach the sidebar (focused \(focusKey())).")
            return false
        }
        let target = Self.sidebarTabs.firstIndex(of: identifier) ?? 0
        for _ in 0..<(Self.sidebarTabs.count * 2) {
            let current = focusedElement()?.identifier ?? ""
            if current == identifier { break }
            let index = Self.sidebarTabs.firstIndex(of: current) ?? 0
            press(index < target ? .right : .left, settle: 0.4)
        }
        guard focusedElement()?.identifier == identifier else {
            XCTFail("Could not focus \(identifier) (focused \(focusKey())).")
            return false
        }
        press(.select, settle: 0.2)
        return true
    }

    private func enterContent(_ name: String) -> Bool {
        let started = Date()
        if focusIsOnSidebar() { press(.down, settle: 0.2) }
        let entered = waitForFocus(where: { !focusIsOnSidebar() && focusedElement() != nil }, timeout: 6)
        record("enter-\(name)", since: started, ok: entered)
        if !entered {
            XCTFail("Focus could not enter \(name) (focused \(focusKey())).")
            shot("stranded-\(name)")
        }
        alive("enter \(name)")
        return entered
    }

    func testTV01_SidebarTabsCycle() {
        launch(tab: "Home")
        for round in 0..<Self.repeats {
            for tab in Self.sidebarTabs {
                let started = Date()
                guard selectTab(tab) else { continue }
                record("tab-\(tab)-\(round)", since: started, ok: true, budget: 10)
                alive("select \(tab)")
                if round == 0 { Thread.sleep(forTimeInterval: 1); shot("tab-\(tab)") }
                _ = enterContent(tab)
            }
        }
    }

    private func walkRows(_ name: String, rows: Int, opensItems: Bool) {
        var seen: [String] = []
        var stuck = 0
        for row in 0..<rows {
            let before = focusKey()
            press(.down, settle: 0.6)
            let after = focusKey()
            seen.append(after)
            alive("\(name) down \(row)")
            if after == before { stuck += 1 } else { stuck = 0 }
            if after == "nil" {
                XCTFail("Focus vanished walking \(name) at row \(row).")
                shot("\(name)-focus-lost-\(row)")
                return
            }
            if stuck >= 2 { break }
            press(.right, settle: 0.4)
            press(.right, settle: 0.4)
            press(.left, settle: 0.4)
            alive("\(name) across \(row)")
            guard opensItems else { continue }
            let opening = focusKey()
            let started = Date()
            press(.select, settle: 1.5)
            alive("\(name) open row \(row)")
            if app.state == .runningBackground {
                XCTFail("Selecting \(opening) sent the app to the background.")
                app.activate()
                return
            }
            if focusKey() == opening { continue }
            shot("\(name)-row-\(row)-opened")
            record("\(name)-open-\(row)", since: started, ok: true, budget: 4)
            press(.menu, settle: 1.5)
            if app.state == .runningBackground {
                XCTFail("Menu after opening \(opening) left the app.")
                app.activate()
                return
            }
            alive("\(name) back row \(row)")
            if focusKey() != opening, focusIsOnSidebar() {
                XCTFail("Menu from \(opening) returned focus to the sidebar instead of the row.")
                _ = enterContent(name)
            }
        }
        let attachment = XCTAttachment(string: seen.joined(separator: "\n"))
        attachment.name = "\(name)-focus-path"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTV02_HomeWalkAndOpenEveryRow() {
        launch(tab: "Home")
        Thread.sleep(forTimeInterval: 2)
        shot("home")
        walkRows("home", rows: 6, opensItems: true)
    }

    func testTV03_FollowingWalk() {
        launch(tab: "Following")
        Thread.sleep(forTimeInterval: 2)
        shot("following")
        walkRows("following", rows: 5, opensItems: true)
    }

    func testTV04_LibraryShelvesOpenEach() {
        launch(tab: "Library")
        Thread.sleep(forTimeInterval: 2)
        shot("library")
        var shelves: [String] = []
        for _ in 0..<16 {
            let id = focusedElement()?.identifier ?? ""
            if id.hasPrefix("library.shelf."), !shelves.contains(id) { shelves.append(id) }
            press(.down, settle: 0.5)
        }
        alive("library walk")
        XCTAssertFalse(shelves.isEmpty, "Walking down Library never focused a shelf header.")
        for shelf in shelves {
            for _ in 0..<20 where focusedElement()?.identifier != shelf { press(.up, settle: 0.35) }
            if focusedElement()?.identifier != shelf {
                for _ in 0..<20 where focusedElement()?.identifier != shelf { press(.down, settle: 0.35) }
            }
            guard focusedElement()?.identifier == shelf else {
                XCTFail("Could not refocus \(shelf).")
                continue
            }
            for round in 0..<1 {
                let started = Date()
                press(.select, settle: 0.2)
                let opened = waitForFocus(where: { (focusedElement()?.identifier ?? "") != shelf }, timeout: 6)
                record("\(shelf)-open-\(round)", since: started, ok: opened, budget: 4)
                alive("\(shelf) open")
                if round == 0 { shot("\(shelf)-detail") }
                press(.down, settle: 0.6)
                press(.down, settle: 0.6)
                press(.select, settle: 1.5)
                alive("\(shelf) item")
                if round == 0 { shot("\(shelf)-item") }
                press(.menu, settle: 1.2)
                if focusedElement()?.identifier != shelf { press(.menu, settle: 1.2) }
                alive("\(shelf) back")
                XCTAssertEqual(focusedElement()?.identifier, shelf, "Back from \(shelf) did not return to its header.")
                if focusedElement()?.identifier != shelf { break }
            }
        }
    }

    private static let nowPlayingActions = [
        "nowplaying.action.upNext", "nowplaying.action.lyrics", "nowplaying.action.comments",
        "nowplaying.action.tracklist", "nowplaying.action.trackMap", "nowplaying.action.about",
        "nowplaying.action.autoMix", "nowplaying.action.decks", "nowplaying.action.sleepTimer",
        "nowplaying.action.output", "nowplaying.action.more",
    ]

    private func startRealPlayback() -> Bool {
        launch(tab: "Library")
        for _ in 0..<16 where focusedElement()?.identifier != "library.shelf.likes" { press(.down, settle: 0.4) }
        guard focusedElement()?.identifier == "library.shelf.likes" else {
            XCTFail("Could not find the Likes shelf.")
            return false
        }
        press(.select, settle: 1.5)
        press(.down, settle: 0.6)
        press(.down, settle: 0.6)
        let started = Date()
        press(.select, settle: 0.2)
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Pause"])).firstMatch
        let shown = play.waitForExistence(timeout: 20)
        record("play-like-to-now-playing", since: started, ok: shown, budget: 4)
        XCTAssertTrue(shown, "Selecting a liked track never opened Now Playing.")
        alive("start playback")
        return shown
    }

    func testTV05_NowPlayingTransportAndPanels() {
        guard startRealPlayback() else { return }
        shot("np")
        for round in 0..<(Self.repeats * 2) {
            press(.playPause, settle: 0.5)
            alive("play/pause \(round)")
        }
        press(.up, settle: 0.8)
        for round in 0..<Self.repeats {
            press(.right, settle: 0.3)
            press(.right, settle: 0.3)
            press(.left, settle: 0.3)
            alive("scrub \(round)")
        }
        press(.down, settle: 0.8)
        var visited: [String] = []
        for _ in 0..<16 {
            let id = focusedElement()?.identifier ?? ""
            if id.hasPrefix("nowplaying.action."), !visited.contains(id) { visited.append(id) }
            press(.right, settle: 0.4)
        }
        for _ in 0..<16 { press(.left, settle: 0.25) }
        alive("np action walk")
        XCTAssertFalse(visited.isEmpty, "Never focused a Now Playing action.")
        for action in visited where action != "nowplaying.action.like" && action != "nowplaying.action.sharePlay" {
            for _ in 0..<16 where focusedElement()?.identifier != action { press(.right, settle: 0.3) }
            guard focusedElement()?.identifier == action else {
                XCTFail("Could not refocus \(action).")
                for _ in 0..<16 { press(.left, settle: 0.2) }
                continue
            }
            for round in 0..<2 {
                let started = Date()
                press(.select, settle: 0.2)
                let moved = waitForFocus(where: { (focusedElement()?.identifier ?? "") != action }, timeout: 4)
                record("\(action)-\(round)", since: started, ok: moved, budget: 3)
                Thread.sleep(forTimeInterval: 0.8)
                alive("open \(action)")
                if round == 0 { shot(action) }
                press(.down, settle: 0.4)
                press(.up, settle: 0.4)
                press(.menu, settle: 1.2)
                alive("close \(action)")
                if focusedElement()?.identifier != action {
                    XCTFail("Closing \(action) left focus on \(focusKey()).")
                    shot("\(action)-close-focus")
                    break
                }
            }
            for _ in 0..<16 { press(.left, settle: 0.2) }
        }
    }

    func testTV06_SettingsEveryCategory() {
        let categories = ["subscription", "playback", "downloads", "analysis", "musicFolders", "devices", "homeLighting", "about"]
        launch(tab: "Settings")
        for round in 0..<2 {
            for category in categories {
                let id = "settings.section.\(category)"
                for _ in 0..<12 where focusedElement()?.identifier != id {
                    let current = focusedElement()?.identifier ?? ""
                    let currentIndex = categories.firstIndex { "settings.section.\($0)" == current } ?? 0
                    let targetIndex = categories.firstIndex(of: category) ?? 0
                    press(currentIndex < targetIndex ? .down : .up, settle: 0.4)
                }
                guard focusedElement()?.identifier == id else {
                    XCTFail("Could not focus \(id) (focused \(focusKey())).")
                    continue
                }
                let started = Date()
                press(.select, settle: 0.1)
                let detail = app.descendants(matching: .any)["settings.detail.\(category)"]
                let opened = detail.waitForExistence(timeout: 8)
                record("settings-\(category)-\(round)", since: started, ok: opened)
                XCTAssertTrue(opened, "Settings \(category) never opened its detail.")
                alive("settings \(category)")
                if round == 0 { shot("settings-\(category)") }
                for _ in 0..<6 { press(.down, settle: 0.35) }
                alive("settings \(category) walk")
                press(.menu, settle: 1.2)
                if app.descendants(matching: .any)["settings.back"].exists { press(.menu, settle: 1.2) }
                alive("settings \(category) back")
                XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 4), "Back from \(category) did not return to the Settings list.")
            }
        }
    }

    func testTV07_SearchBrowseAndOpen() {
        for (round, query) in ["first", "second"].enumerated() {
            launch(tab: "Search")
            Thread.sleep(forTimeInterval: 2)
            shot("search-\(round)")
            for _ in 0..<3 {
                let before = focusKey()
                press(.down, settle: 0.6)
                alive("search walk \(query)")
                if focusKey() == before { break }
            }
            let opening = focusKey()
            press(.select, settle: 1.5)
            alive("search open \(query)")
            if round == 0 { shot("search-open-\(round)") }
            if focusKey() != opening {
                press(.menu, settle: 1.2)
                XCTAssertNotEqual(app.state, .runningBackground, "Menu from a search result left the app.")
            }
            alive("search back \(query)")
        }
    }

    func testTV08_ProfileWalk() {
        launch(tab: "Profile")
        Thread.sleep(forTimeInterval: 2)
        shot("profile")
        for _ in 0..<6 {
            press(.down, settle: 0.5)
            press(.right, settle: 0.4)
            alive("profile walk")
        }
    }

    private func smoothOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    func testTV10_HitchesSidebarTabs() {
        launch(tab: "Home")
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: smoothOptions()) {
            for tab in ["sidebar.tab.library", "sidebar.tab.settings", "sidebar.tab.home"] {
                selectTab(tab)
                Thread.sleep(forTimeInterval: 1)
            }
        }
        alive("hitch tabs")
    }

    func testTV11_HitchesHomeFocus() {
        launch(tab: "Home")
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: smoothOptions()) {
            for button: XCUIRemote.Button in [.down, .right, .right, .down, .right, .left, .down, .up, .up, .up] {
                press(button, settle: 0.4)
            }
        }
        alive("hitch home")
    }

    func testTV12_IdleCPUOnNowPlaying() {
        guard startRealPlayback() else { return }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            Thread.sleep(forTimeInterval: 5)
        }
        alive("idle")
    }
}
