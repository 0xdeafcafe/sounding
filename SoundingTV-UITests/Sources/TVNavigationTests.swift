import XCTest

@MainActor
final class TVNavigationTests: XCTestCase {
    private var app: XCUIApplication!
    private static var rateLimited = false
    private static let sidebarTabs = [
        "sidebar.tab.home", "sidebar.tab.search", "sidebar.tab.library",
        "sidebar.tab.decks", "sidebar.tab.nowPlaying", "sidebar.tab.settings",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        if Self.rateLimited { throw XCTSkip("SoundCloud rate-limited an earlier test; stopping to protect the account.") }
        continueAfterFailure = true
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    // MARK: Helpers

    private func launch(tab: String) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "0"
        app.launchEnvironment["SOUNDING_TV_TAB"] = tab
        app.launchArguments += ["-red.forbes.sounding.didSeeTVWelcome", "YES"]
        app.launch()
        XCTAssertTrue(waitForFocus(timeout: 25) { self.focusedElement() != nil }, "\(tab) launched with nothing focused.")
        alive("launch \(tab)")
        let home = app.descendants(matching: .any)["sidebar.tab.home"]
        if !home.waitForExistence(timeout: 4) {
            continueAfterFailure = false
            XCTFail("This Apple TV is not signed in to SoundCloud. Ask the owner to sign in on it, then rerun.")
        }
        if focusIsOnSidebar() { press(.down, settle: 0.4) }
        _ = waitForFocus(timeout: 6) { !self.focusIsOnSidebar() && self.focusedElement() != nil }
    }

    private func alive(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let limited = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'limiting requests' OR label CONTAINS[c] 'rate limit'"))
        if limited.count > 0 {
            Self.rateLimited = true
            continueAfterFailure = false
            XCTFail("SoundCloud is limiting requests after \(context). Stopping.", file: file, line: line)
        }
        XCTAssertEqual(app.state, .runningForeground, "The app is no longer running after \(context).", file: file, line: line)
    }

    private func attach(_ lines: [String], _ name: String) {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard element.exists else { return nil }
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

    private func waitForFocus(timeout: TimeInterval, where condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func isPlaying() -> Bool {
        app.buttons.matching(NSPredicate(format: "label == 'Pause'")).count > 0
    }

    private func focus(identifier: String, pressing direction: XCUIRemote.Button, limit: Int = 16) -> Bool {
        for _ in 0..<limit where focusedElement()?.identifier != identifier {
            press(direction, settle: 0.4)
        }
        return focusedElement()?.identifier == identifier
    }

    private func focusShelfCard(_ shelves: [String]) -> String? {
        var path: [String] = []
        for step in 0..<18 {
            let id = focusedElement()?.identifier ?? "nil"
            path.append(id)
            if step % 4 == 0 { shot("library-walk-\(step)") }
            if let shelf = shelves.first(where: { id.hasPrefix("library.\($0).card.") }) {
                attach(path, "library-walk")
                return shelf
            }
            press(.down, settle: 0.7)
        }
        attach(path, "library-walk")
        for _ in 0..<18 { press(.up, settle: 0.3) }
        for shelf in shelves {
            let header = "library.shelf.\(shelf)"
            guard focus(identifier: header, pressing: .down, limit: 14) || focus(identifier: header, pressing: .up, limit: 14) else { continue }
            press(.down, settle: 0.6)
            if focusedElement()?.identifier.hasPrefix("library.\(shelf).card.") == true { return shelf }
        }
        return nil
    }

    private func assertMenuReturns(to identifier: String, from context: String) {
        press(.menu, settle: 1.2)
        alive("menu from \(context)")
        let back = waitForFocus(timeout: 4) { self.focusedElement()?.identifier == identifier }
        if !back {
            shot("\(context)-menu-stranded")
            XCTFail("Menu from \(context) left focus on \(focusKey()), not \(identifier).")
        }
    }

    // MARK: Album page

    func testNav01_AlbumPage() {
        launch(tab: "Library")
        Thread.sleep(forTimeInterval: 2)
        guard let shelf = focusShelfCard(["albums", "playlists"]) else {
            XCTFail("No album or playlist shelf to open.")
            return
        }
        let card = focusedElement()?.identifier ?? ""
        press(.select, settle: 0.3)
        let entered = waitForFocus(timeout: 6) { (self.focusedElement()?.identifier ?? "") != card && self.focusedElement() != nil }
        XCTAssertTrue(entered, "Opening \(shelf) left nothing focused (focused \(focusKey())).")
        Thread.sleep(forTimeInterval: 3)
        shot("album-hero")
        let play = focusedElement()
        XCTAssertTrue(play?.identifier == "collection.play" || play?.label == "Play", "Album page should enter on Play, entered on \(focusKey()).")
        var keys: [String] = []
        for step in 0..<5 {
            press(.down, settle: 0.7)
            keys.append(focusKey())
            XCTAssertNotEqual(focusKey(), "nil", "Focus vanished moving down the album page at step \(step).")
        }
        shot("album-tracks")
        let attachment = XCTAttachment(string: keys.joined(separator: "\n"))
        attachment.name = "album-focus-path"
        attachment.lifetime = .keepAlways
        add(attachment)
        for _ in 0..<5 { press(.up, settle: 0.4) }
        assertMenuReturns(to: card, from: "album")
    }

    // MARK: Decks

    private func startPausedPlayback() -> Bool {
        launch(tab: "Library")
        guard focus(identifier: "library.shelf.sets", pressing: .down) else {
            XCTFail("Could not find the Sets shelf.")
            return false
        }
        press(.down, settle: 0.6)
        press(.select, settle: 0.1)
        let shown = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Pause"])).firstMatch.waitForExistence(timeout: 20)
        XCTAssertTrue(shown, "Selecting a liked track never opened Now Playing.")
        _ = waitForFocus(timeout: 4) { self.isPlaying() }
        if isPlaying() { press(.playPause, settle: 0.8) }
        if isPlaying() { press(.playPause, settle: 0.8) }
        XCTAssertFalse(isPlaying(), "Playback did not stop.")
        alive("start playback")
        return shown
    }

    private func openDecks() -> Bool {
        press(.down, settle: 0.8)
        guard focus(identifier: "nowplaying.action.more", pressing: .right, limit: 14) else {
            XCTFail("Could not focus More (focused \(focusKey())).")
            return false
        }
        press(.select, settle: 1.2)
        guard focus(identifier: "nowplaying.action.decks", pressing: .down, limit: 12) || focus(identifier: "nowplaying.action.decks", pressing: .up, limit: 12) else {
            XCTFail("Could not focus Decks in More (focused \(focusKey())).")
            return false
        }
        press(.select, settle: 2.5)
        if app.buttons["autoMix.start"].exists {
            shot("decks-start-sheet")
            for _ in 0..<8 where focusedElement()?.identifier != "autoMix.start" {
                press(focusedElement()?.label == "Cancel" ? .right : .up, settle: 0.4)
            }
            if focusedElement()?.identifier != "autoMix.start" {
                for _ in 0..<4 where focusedElement()?.identifier != "autoMix.start" { press(.right, settle: 0.4) }
            }
            guard focusedElement()?.identifier == "autoMix.start" else {
                XCTFail("Could not focus Start in the Auto Mix sheet (focused \(focusKey())).")
                return false
            }
            press(.select, settle: 2.5)
        }
        if isPlaying() { press(.playPause, settle: 0.6) }
        return true
    }

    func testNav02_Decks() {
        guard startPausedPlayback(), openDecks() else { return }
        XCTAssertNotNil(focusedElement(), "Decks opened with nothing focused.")
        shot("decks-0")
        var keys: [String] = [focusKey()]
        for button: XCUIRemote.Button in [.right, .right, .right, .up, .up, .down, .down, .left, .left] {
            press(button, settle: 0.6)
            keys.append(focusKey())
            XCTAssertNotEqual(focusKey(), "nil", "Focus vanished in Decks.")
        }
        shot("decks-1")
        let attachment = XCTAttachment(string: keys.joined(separator: "\n"))
        attachment.name = "decks-focus-path"
        attachment.lifetime = .keepAlways
        add(attachment)
        if isPlaying() { press(.playPause, settle: 0.6) }
        press(.menu, settle: 1.2)
        alive("menu from decks")
        let back = waitForFocus(timeout: 4) { self.app.descendants(matching: .any)["decks.autoMix"].exists == false && self.focusedElement() != nil && !self.focusIsOnSidebar() }
        if !back { shot("decks-menu-stranded") }
        XCTAssertTrue(back, "Menu from Decks did not return to Now Playing (focused \(focusKey())).")
    }

    // MARK: Focus traps

    private var trapLog: [String] = []

    private func note(_ line: String) {
        trapLog.append(line)
    }

    private func selectTab(_ identifier: String) -> Bool {
        for _ in 0..<5 where !focusIsOnSidebar() { press(.menu, settle: 0.8) }
        guard focusIsOnSidebar() else {
            XCTFail("Menu never reached the sidebar (focused \(focusKey())).")
            shot("sidebar-unreachable")
            return false
        }
        let target = Self.sidebarTabs.firstIndex(of: identifier) ?? 0
        for _ in 0..<(Self.sidebarTabs.count * 2) {
            let current = focusedElement()?.identifier ?? ""
            if current == identifier { break }
            let index = Self.sidebarTabs.firstIndex(of: current) ?? 0
            press(index < target ? .right : .left, settle: 0.4)
        }
        guard focusedElement()?.identifier == identifier else { return false }
        press(.select, settle: 0.4)
        press(.down, settle: 0.3)
        return true
    }

    private func checkPage(_ name: String, opener: String) {
        let focused = waitForFocus(timeout: 8) { self.focusedElement() != nil && !self.focusIsOnSidebar() && self.focusKey() != opener }
        alive("open \(name)")
        if !focused {
            shot("\(name)-stranded")
            XCTFail("\(name) opened with nothing focusable (focused \(focusKey())).")
        }
        note("\(name): entered on \(focusKey())")
        for _ in 0..<3 { press(.down, settle: 0.45) }
        if focusKey() == "nil" {
            shot("\(name)-lost")
            XCTFail("Focus vanished walking down \(name).")
        }
        for _ in 0..<3 { press(.up, settle: 0.35) }
    }

    private func openAndReturn(_ name: String) {
        let opener = focusKey()
        guard opener != "nil", !focusIsOnSidebar() else { return }
        if let label = focusedElement()?.label, label.range(of: #"\d+:\d\d"#, options: .regularExpression) != nil || label.contains("BPM") {
            note("\(name): skipped track \(opener)")
            return
        }
        press(.select, settle: 1.2)
        alive("select \(name)")
        if isPlaying() {
            press(.playPause, settle: 0.6)
            note("\(name): \(opener) started playback; paused")
            press(.menu, settle: 1.2)
            return
        }
        if focusKey() == opener {
            note("\(name): \(opener) did not open anything")
            return
        }
        checkPage(name, opener: opener)
        press(.menu, settle: 1.2)
        let back = waitForFocus(timeout: 5) { self.focusKey() == opener }
        note("\(name): Menu returned to \(focusKey())")
        if !back {
            shot("\(name)-menu")
            XCTFail("Menu from \(name) did not go back to \(opener) (focused \(focusKey())).")
        }
    }

    private func walkTab(_ tab: String, opens: Int) {
        guard selectTab(tab) else { return }
        let entered = waitForFocus(timeout: 8) { !self.focusIsOnSidebar() && self.focusedElement() != nil }
        if !entered {
            shot("\(tab)-no-content-focus")
            note("\(tab): content had nothing focusable")
        }
        var opened = 0
        var seen: Set<String> = []
        for step in 0..<(opens * 2) where opened < opens && entered {
            let key = focusKey()
            if !seen.contains(key) {
                seen.insert(key)
                openAndReturn("\(tab)#\(step)")
                opened += 1
            }
            press(.down, settle: 0.6)
            alive("\(tab) walk")
        }
        press(.menu, settle: 1.0)
        for _ in 0..<3 where !focusIsOnSidebar() { press(.menu, settle: 1.0) }
        XCTAssertTrue(focusIsOnSidebar(), "Menu from \(tab) never reached the sidebar (focused \(focusKey())).")
        note("\(tab): Menu reached \(focusKey())")
    }

    func testNav03_EveryScreenHasFocusAndMenuGoesBack() {
        launch(tab: "Home")
        Thread.sleep(forTimeInterval: 2)
        walkTab("sidebar.tab.home", opens: 3)
        walkTab("sidebar.tab.library", opens: 4)
        walkTab("sidebar.tab.settings", opens: 8)
        walkTab("sidebar.tab.search", opens: 2)
        let attachment = XCTAttachment(string: trapLog.joined(separator: "\n"))
        attachment.name = "focus-trap-walk"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNav04_SettingsSubpages() {
        launch(tab: "Settings")
        for (category, label) in [("downloads", "Downloaded Music"), ("playback", "Your Moves")] {
            let id = "settings.section.\(category)"
            guard focus(identifier: id, pressing: .down, limit: 10) || focus(identifier: id, pressing: .up, limit: 10) else {
                XCTFail("Could not focus \(id).")
                continue
            }
            press(.select, settle: 1.5)
            var found = false
            for _ in 0..<40 {
                if focusedElement()?.label.hasPrefix(label) == true { found = true; break }
                press(.down, settle: 0.3)
            }
            if found {
                openAndReturn("settings.\(category).\(label)")
            } else {
                note("settings.\(category): no \(label) row")
            }
            press(.menu, settle: 1.2)
            let back = waitForFocus(timeout: 4) { self.focusedElement()?.identifier == id }
            XCTAssertTrue(back, "Menu from Settings › \(category) did not return to its row (focused \(focusKey())).")
        }
        let attachment = XCTAttachment(string: trapLog.joined(separator: "\n"))
        attachment.name = "settings-walk"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
