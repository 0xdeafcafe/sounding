import XCTest

@MainActor
final class TVBackTests: XCTestCase {
    private var app: XCUIApplication!
    private var log: [String] = []
    private static let sidebarTabs = [
        "sidebar.tab.home", "sidebar.tab.search", "sidebar.tab.library",
        "sidebar.tab.decks", "sidebar.tab.stations", "sidebar.tab.nowPlaying", "sidebar.tab.settings",
    ]
    private static let shotDirectory = ProcessInfo.processInfo.environment["TV_BACK_SHOT_DIR"]

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        log = []
    }

    override func tearDown() {
        let attachment = XCTAttachment(string: log.joined(separator: "\n"))
        attachment.name = "back-log"
        attachment.lifetime = .keepAlways
        add(attachment)
        if app?.state == .runningForeground { app.terminate() }
        super.tearDown()
    }

    // MARK: Helpers

    private func launch(tab: String, _ extra: [String: String] = [:], enter: Bool = true, wait: TimeInterval = 4, probe: Bool = true) {
        if app?.state == .runningForeground { app.terminate() }
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        app.launchEnvironment["SOUNDING_TV_TAB"] = tab
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launchArguments += ["-red.forbes.sounding.didSeeTVWelcome", "YES"]
        app.launch()
        guard probe else {
            Thread.sleep(forTimeInterval: wait + 8)
            note("launch \(tab) \(extra): quiet")
            return
        }
        _ = waitFor(timeout: 25) { self.focusedElement() != nil }
        Thread.sleep(forTimeInterval: wait)
        if enter, focusIsOnSidebar() {
            press(.down, settle: 0.8)
            _ = waitFor(timeout: 5) { !self.focusIsOnSidebar() && self.focusedElement() != nil }
        }
        note("launch \(tab) \(extra): focus \(focusKey())")
    }

    private func note(_ line: String) {
        log.append(line)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = Self.shotDirectory else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: url)
    }

    private func press(_ button: XCUIRemote.Button, settle: TimeInterval = 0.5) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
    }

    private func focusedElement() -> XCUIElement? {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard element.exists else { return nil }
        guard element.identifier.isEmpty else { return element }
        let identified = element.descendants(matching: .any).matching(NSPredicate(format: "identifier != ''")).firstMatch
        return identified.exists ? identified : element
    }

    private func focusKey() -> String {
        guard let focused = focusedElement() else { return "nil" }
        return "\(focused.identifier)|\(focused.label)"
    }

    private func focusIsOnSidebar() -> Bool {
        Self.sidebarTabs.contains(focusedElement()?.identifier ?? "")
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func focus(identifier: String, pressing direction: XCUIRemote.Button, limit: Int = 14) -> Bool {
        for _ in 0..<limit where focusedElement()?.identifier != identifier {
            press(direction, settle: 0.45)
        }
        return focusedElement()?.identifier == identifier
    }

    private func focus(labelPrefix: String, pressing direction: XCUIRemote.Button, limit: Int = 30) -> Bool {
        for _ in 0..<limit where focusedElement()?.label.hasPrefix(labelPrefix) != true {
            press(direction, settle: 0.4)
        }
        return focusedElement()?.label.hasPrefix(labelPrefix) == true
    }

    private func exists(_ identifier: String) -> Bool {
        app.descendants(matching: .any)[identifier].exists
    }

    @discardableResult
    private func back(_ name: String, settle: TimeInterval = 1.6, expectForeground: Bool = true, probeFocus: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let before = probeFocus ? focusKey() : "-"
        press(.menu, settle: settle)
        shot("back-\(name)")
        let alive = !waitFor(timeout: 4) { self.app.state != .runningForeground }
        note("\(name): \(before) -> \(probeFocus ? focusKey() : "-") \(alive ? "foreground" : "LEFT THE APP state=\(app.state.rawValue)")")
        if expectForeground {
            XCTAssertTrue(alive, "Menu from \(name) left the app (state \(app.state.rawValue)).", file: file, line: line)
        }
        return alive
    }

    private func expectSidebar(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let reached = waitFor(timeout: 4) { self.focusIsOnSidebar() }
        XCTAssertTrue(reached, "Menu from \(name) did not land on the tab bar (focused \(focusKey())).", file: file, line: line)
    }

    private func expectFocus(_ prefix: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let reached = waitFor(timeout: 4) { self.focusedElement()?.identifier.hasPrefix(prefix) == true }
        XCTAssertTrue(reached, "Menu from \(name) did not return focus to \(prefix) (focused \(focusKey())).", file: file, line: line)
    }

    private func isPlaying() -> Bool {
        app.buttons.matching(NSPredicate(format: "label == 'Pause'")).count > 0
    }

    private func pauseIfPlaying() {
        if isPlaying() { press(.playPause, settle: 0.8) }
    }

    // MARK: Tab roots

    func testBack00_Calibrate() {
        launch(tab: "Home", enter: false)
        note("start state=\(app.state.rawValue) focus=\(focusKey())")
        for step in 1...3 {
            press(.menu, settle: 2.5)
            shot("back-calibrate-menu-\(step)")
            note("menu \(step): state=\(app.state.rawValue) focus=\(focusKey())")
        }
        press(.home, settle: 3)
        shot("back-calibrate-home")
        note("home: state=\(app.state.rawValue)")
        app.activate()
        Thread.sleep(forTimeInterval: 3)
        note("activate: state=\(app.state.rawValue) focus=\(focusKey())")
    }

    func testBack01_TabRootsGoToTabBar() {
        for tab in ["Home", "Search", "Decks", "Stations", "Settings"] {
            launch(tab: tab)
            shot("back-root-\(tab.lowercased())-0")
            back("root-\(tab.lowercased())")
            expectSidebar("\(tab) root")
        }
    }

    func testBack01b_LibraryRootQuiet() {
        launch(tab: "Library", probe: false)
        press(.down, settle: 1)
        press(.right, settle: 1)
        shot("back-root-library-0")
        back("root-library-detail", probeFocus: false)
        back("root-library", probeFocus: false)
        let left = back("root-library-tabbar", settle: 2.5, expectForeground: false, probeFocus: false)
        note("library tab bar left=\(!left)")
    }

    func testBack02_TabBarLeavesTheApp() {
        launch(tab: "Home", enter: false)
        for _ in 0..<3 where !focusIsOnSidebar() { press(.menu, settle: 1.2) }
        XCTAssertTrue(focusIsOnSidebar(), "Could not reach the tab bar (focused \(focusKey())).")
        shot("back-tabbar-0")
        let alive = back("tabbar", settle: 2.5, expectForeground: false)
        note("tab bar Menu alive=\(alive) state=\(app.state.rawValue)")
        XCTAssertFalse(alive, "Menu on the tab bar should leave the app; it stayed in the foreground.")
    }

    // MARK: Now Playing

    func testBack03_NowPlayingRootRevealsThenTabBar() {
        launch(tab: "Now Playing", ["SOUNDING_TV_PLAY": "1"], wait: 7)
        pauseIfPlaying()
        shot("back-np-0")
        back("np-1")
        XCTAssertFalse(focusIsOnSidebar(), "First Menu on Now Playing should only reveal the bar.")
        back("np-2")
        expectSidebar("Now Playing")
    }

    func testBack04_NowPlayingEmptyGoesToTabBar() {
        launch(tab: "Now Playing", ["SOUNDING_TV_FORCE_EMPTY_NOWPLAYING": "1"])
        shot("back-np-empty-0")
        back("np-empty")
        expectSidebar("Now Playing empty")
    }

    func testBack05_NowPlayingFromHomeReturnsHome() {
        launch(tab: "Home", wait: 6)
        guard focusedElement()?.label == "Play" || focus(labelPrefix: "Play", pressing: .right, limit: 4) else {
            XCTFail("Home hero has no Play (focused \(focusKey())).")
            return
        }
        press(.select, settle: 0.5)
        let opened = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Pause"])).firstMatch.waitForExistence(timeout: 20)
        _ = waitFor(timeout: 6) { self.exists("nowplaying.action.more") }
        Thread.sleep(forTimeInterval: 2)
        pauseIfPlaying()
        shot("back-np-from-home-0")
        XCTAssertTrue(opened && exists("nowplaying.action.more"), "Play on the hero did not open Now Playing.")
        back("np-from-home")
        let home = waitFor(timeout: 5) { !self.exists("nowplaying.action.more") }
        XCTAssertTrue(home, "Menu from Now Playing opened from Home did not return to Home (focused \(focusKey())).")
    }

    func testBack06_Panels() {
        for kind in ["more", "cues", "tracklist", "output", "upNext", "comments"] {
            launch(tab: "Now Playing", ["SOUNDING_TV_PLAY": "1", "SOUNDING_TV_NP_PANEL": kind], wait: 8)
            pauseIfPlaying()
            shot("back-panel-\(kind)-0")
            back("panel-\(kind)")
            if kind == "cues" {
                XCTAssertFalse(focusIsOnSidebar(), "Menu from Cues should go to More, not the tab bar.")
                back("panel-\(kind)-more")
            }
            expectFocus("nowplaying.action", "\(kind) panel")
        }
    }

    func testBack07_LyricsReturnsToControls() {
        launch(tab: "Now Playing", ["SOUNDING_TV_PLAY": "1", "SOUNDING_TV_NP_LYRICS": "1"], wait: 8)
        shot("back-lyrics-0")
        back("lyrics")
        XCTAssertFalse(focusIsOnSidebar(), "Menu from Lyrics should return to the controls, not the tab bar.")
        XCTAssertTrue(exists("nowplaying.action.more"), "Menu from Lyrics did not return to Now Playing.")
    }

    func testBack08_Covers() {
        let covers: [(String, [String: String])] = [
            ("cues", ["SOUNDING_TV_CUES_OPEN": "1"]),
            ("comments", ["SOUNDING_TV_COMMENTS_OPEN": "1"]),
            ("decks", ["SOUNDING_TV_DJ_OPEN": "1"]),
        ]
        for (name, env) in covers {
            var merged = env
            merged["SOUNDING_TV_PLAY"] = "1"
            launch(tab: "Now Playing", merged, wait: 9)
            shot("back-cover-\(name)-0")
            back("cover-\(name)", settle: 2)
            pauseIfPlaying()
            let home = waitFor(timeout: 5) { self.exists("nowplaying.action.more") }
            XCTAssertTrue(home, "Menu from the \(name) cover did not return to Now Playing (focused \(focusKey())).")
            XCTAssertFalse(focusIsOnSidebar(), "Menu from the \(name) cover parked focus on the tab bar.")
        }
        launch(tab: "Now Playing", ["SOUNDING_TV_PLAY": "1", "SOUNDING_TV_NP_FOCUS": "details"], wait: 7)
        pauseIfPlaying()
        if focusedElement()?.identifier == "nowplaying.action.behindTheTrack" {
            press(.select, settle: 3)
            shot("back-cover-behind-0")
            back("cover-behind", settle: 2)
            expectFocus("nowplaying.action", "Behind the Track")
        } else {
            note("behind: could not focus details (\(focusKey()))")
        }
    }

    func testBack09_IdleAndAmbient() {
        launch(tab: "Now Playing", ["SOUNDING_TV_PLAY": "1", "SOUNDING_TV_NP_IDLE_AFTER": "6"], wait: 12)
        shot("back-idle-0")
        back("idle")
        XCTAssertFalse(focusIsOnSidebar(), "Menu from idle should wake Now Playing, not jump to the tab bar.")
        pauseIfPlaying()

        launch(tab: "Home", ["SOUNDING_TV_AMBIENT": "2"], wait: 8)
        shot("back-ambient-0")
        back("ambient")
        let home = waitFor(timeout: 5) { self.exists("sidebar.tab.home") }
        XCTAssertTrue(home, "Menu from the ambient screen did not return to the app (focused \(focusKey())).")
    }

    // MARK: Settings

    func testBack10_SettingsPagesCoversAndDialogs() {
        launch(tab: "Settings", ["SOUNDING_TV_TV_SETTINGS": "devices"], wait: 5)
        shot("back-settings-devices-0")
        if focus(identifier: "settings.devices.add", pressing: .down, limit: 10) || focus(identifier: "settings.devices.add", pressing: .up, limit: 10) {
            press(.select, settle: 3)
            shot("back-settings-adddevice-0")
            back("settings-adddevice", settle: 2)
            expectFocus("settings.devices", "Add a Device")
        } else {
            note("settings: no Add a Device row (\(focusKey()))")
        }
        back("settings-devices")
        expectFocus("settings.section", "Settings › Remotes & Devices")

        launch(tab: "Settings", ["SOUNDING_TV_TV_SETTINGS": "about"], wait: 5)
        if focus(labelPrefix: "Reset All Settings", pressing: .down, limit: 30) {
            press(.select, settle: 2)
            shot("back-settings-reset-0")
            back("settings-reset-dialog", settle: 2)
            XCTAssertFalse(focusIsOnSidebar(), "Menu on the Reset dialog should cancel it, not leave the page.")
            XCTAssertTrue(exists("settings.detail.about"), "Menu on the Reset dialog left the About page.")
        } else {
            note("settings: no Reset All Settings row (\(focusKey()))")
        }
        back("settings-about")
        expectFocus("settings.section", "Settings › About")
        back("settings-root")
        expectSidebar("Settings root")
    }

    // MARK: Library, Home, Search detail pages

    func testBack11_LibraryAccountMenuAndSocial() {
        launch(tab: "Library", wait: 5)
        guard focus(identifier: "library.account", pressing: .up, limit: 14) else {
            XCTFail("Could not focus the account menu (focused \(focusKey())).")
            return
        }
        press(.select, settle: 1.5)
        shot("back-library-accountmenu-0")
        back("library-accountmenu")
        expectFocus("library.account", "account menu")
        press(.select, settle: 1.5)
        press(.select, settle: 3)
        shot("back-library-profile-0")
        back("library-profile", settle: 2)
        expectFocus("library.", "Profile page")
    }

    func testBack12_HomeShelfDetail() {
        launch(tab: "Home", wait: 6)
        var opened = false
        for _ in 0..<6 {
            press(.down, settle: 0.7)
            let label = focusedElement()?.label ?? ""
            let id = focusedElement()?.identifier ?? ""
            if id.contains(".card."), label.range(of: #"\d+:\d\d"#, options: .regularExpression) == nil {
                let before = focusKey()
                press(.select, settle: 3)
                if isPlaying() {
                    press(.playPause, settle: 0.6)
                    back("home-card-play")
                    continue
                }
                if focusKey() != before {
                    opened = true
                    shot("back-home-detail-0")
                    back("home-detail", settle: 2)
                    let returned = waitFor(timeout: 5) { self.focusKey() == before }
                    XCTAssertTrue(returned, "Menu from a Home detail did not return to \(before) (focused \(focusKey())).")
                    break
                }
            }
        }
        note("home detail opened=\(opened)")
        back("home-root")
        expectSidebar("Home")
    }

    func testBack13_SearchBrowseTile() {
        launch(tab: "Search", wait: 6)
        let before = focusKey()
        press(.select, settle: 3)
        shot("back-search-browse-0")
        if focusKey() != before {
            back("search-browse", settle: 2)
            let returned = waitFor(timeout: 5) { self.focusKey() == before }
            XCTAssertTrue(returned, "Menu from a Browse page did not return to \(before) (focused \(focusKey())).")
        } else {
            note("search: select on \(before) opened nothing")
        }
        back("search-root")
        expectSidebar("Search")
    }

    // MARK: Decks

    func testBack14_DecksPicker() {
        launch(tab: "Decks", wait: 6)
        shot("back-decks-0")
        if focus(identifier: "decks.next", pressing: .right, limit: 8) || focus(identifier: "decks.next", pressing: .left, limit: 8) {
            press(.select, settle: 2.5)
            shot("back-decks-picker-0")
            back("decks-picker")
            XCTAssertFalse(focusIsOnSidebar(), "Menu on the Decks picker should close it, not leave Decks.")
        } else if focus(labelPrefix: "Choose a Track", pressing: .down, limit: 6) {
            press(.select, settle: 2.5)
            shot("back-decks-picker-0")
            back("decks-picker")
            XCTAssertFalse(focusIsOnSidebar(), "Menu on the Decks picker should close it, not leave Decks.")
        } else {
            note("decks: no Next… or Choose a Track (\(focusKey()))")
        }
        back("decks-root")
        expectSidebar("Decks")
    }
}
