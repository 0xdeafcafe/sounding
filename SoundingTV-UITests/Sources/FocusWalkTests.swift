import XCTest

@MainActor
final class FocusWalkTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(tab: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_TAB"] = tab
        for (k, v) in extra { app.launchEnvironment[k] = v }
        if extra["SOUNDING_TV_REAL"] == "1" { RealSession.apply(to: app) }
        app.launchArguments += ["-red.forbes.sounding.didSeeTVWelcome", "YES"]
        if ProcessInfo.processInfo.environment["VFY_LIGHT"] == "1" {
            app.launchArguments += ["-AppleInterfaceStyle", "Light"]
        }
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, settle: TimeInterval = 0.8) {
        for _ in 0..<times {
            XCUIRemote.shared.press(button)
            Thread.sleep(forTimeInterval: settle)
        }
    }

    private func focusLabel(_ app: XCUIApplication) -> String {
        let f = focusedElement(in: app)
        return "\(f?.identifier ?? "nil")|\(f?.label ?? "nil")"
    }

    func testLane4SettingsWalk() {
        let page = ProcessInfo.processInfo.environment["LANE4_PAGE"] ?? "playback"
        let app = launch(tab: "Settings", extra: ["SOUNDING_TV_DISMISS_WELCOME": "1", "SOUNDING_TV_TV_SETTINGS": page])
        Thread.sleep(forTimeInterval: 4)
        shot("settings-\(page)-0")
        for i in 1...8 {
            press(.down, settle: 0.6)
            shot("settings-\(page)-\(i)")
            let note = XCTAttachment(string: "settings \(page) down\(i): \(focusLabel(app))")
            note.lifetime = .keepAlways
            add(note)
        }
        app.terminate()
    }

    func testDriveDJModeMenu() {
        let app = launch(tab: "Home", extra: [
            "SOUNDING_TV_SC_MOCK": "1", "SOUNDING_TV_UI_FIXTURE": "1",
            "SOUNDING_TV_UI_DESTINATION": "now-playing", "SOUNDING_TV_DJ_OPEN": "1",
        ])
        Thread.sleep(forTimeInterval: 10)
        shot("dj-0")
        press(.up, times: 3)
        shot("dj-focus-top")
        press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        shot("dj-mode-menu")
        app.terminate()
    }

    func testDriveTopShelf() {
        let app = launch(tab: "Home", extra: ["SOUNDING_TV_SC_MOCK": "1", "SOUNDING_TV_UI_FIXTURE": "1"])
        Thread.sleep(forTimeInterval: 8)
        XCUIRemote.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        shot("topshelf-home-screen")
        press(.up, times: 2)
        shot("topshelf-focused")
        app.terminate()
    }

    func testVerifyWalk() {
        let env = ProcessInfo.processInfo.environment
        let tab = env["VFY_TAB"] ?? "Home"
        var extra = ["SOUNDING_TV_DISMISS_WELCOME": "1"]
        for pair in (env["VFY_ENV"] ?? "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { extra[kv[0]] = kv[1] }
        }
        if env["VFY_REAL"] == "1" { extra["SOUNDING_TV_REAL"] = "1" }
        let prefix = env["VFY_PREFIX"] ?? "vfy"
        let app = launch(tab: tab, extra: extra)
        Thread.sleep(forTimeInterval: Double(env["VFY_WAIT"] ?? "8") ?? 8)
        shot("\(prefix)-0")
        for (i, step) in (env["VFY_STEPS"] ?? "").split(separator: ",").map(String.init).enumerated() {
            switch step {
            case "d": press(.down)
            case "u": press(.up)
            case "l": press(.left)
            case "r": press(.right)
            case "s": press(.select)
            case "m": press(.menu)
            case "p": press(.playPause)
            case "w": Thread.sleep(forTimeInterval: 3)
            default: break
            }
            shot("\(prefix)-\(i + 1)-\(step)")
        }
        app.terminate()
    }

    func testLane4AttachWalk() {
        let app = XCUIApplication()
        app.activate()
        Thread.sleep(forTimeInterval: 3)
        let prefix = ProcessInfo.processInfo.environment["LANE4_PREFIX"] ?? "attach"
        let steps = (ProcessInfo.processInfo.environment["LANE4_STEPS"] ?? "").split(separator: ",").map(String.init)
        shot("\(prefix)-0")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(prefix)-tree"
        tree.lifetime = .keepAlways
        add(tree)
        for (i, step) in steps.enumerated() {
            switch step {
            case "d": press(.down)
            case "u": press(.up)
            case "l": press(.left)
            case "r": press(.right)
            case "s": press(.select)
            case "m": press(.menu)
            case "p": press(.playPause)
            case "w": Thread.sleep(forTimeInterval: 3)
            default: break
            }
            shot("\(prefix)-\(i + 1)-\(step)")
            let note = XCTAttachment(string: "\(prefix) \(i + 1) \(step): \(focusLabel(app))")
            note.lifetime = .keepAlways
            add(note)
        }
    }

    func testLane4WalkTabs() {
        let tabs = ProcessInfo.processInfo.environment["LANE4_TABS"] ?? "Home,Following,Search,Library,Now Playing,Profile,Settings"
        let real = ProcessInfo.processInfo.environment["LANE4_REAL"] ?? "1"
        for tab in tabs.split(separator: ",").map(String.init) {
            var extra = ["SOUNDING_TV_PLAY": "1", "SOUNDING_TV_DISMISS_WELCOME": "1"]
            if real == "1" { extra["SOUNDING_TV_REAL"] = "1" }
            let app = launch(tab: tab, extra: extra)
            Thread.sleep(forTimeInterval: 6)
            shot("\(tab)-0-initial")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(tab)-tree"
            tree.lifetime = .keepAlways
            add(tree)
            add(XCTAttachment(string: focusLabel(app)))
            for i in 1...4 {
                press(.down)
                shot("\(tab)-\(i)-down")
                let note = XCTAttachment(string: "\(tab) down\(i): \(focusLabel(app))")
                note.lifetime = .keepAlways
                add(note)
            }
            press(.left)
            shot("\(tab)-5-left")
            app.terminate()
        }
    }

    private func focusedElement(in app: XCUIApplication) -> XCUIElement? {
        let all = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
        guard all.count > 0 else { return nil }
        let element = all.element(boundBy: 0)
        guard element.identifier.isEmpty else { return element }
        let identified = element.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier != ''"))
        return identified.count > 0 ? identified.element(boundBy: 0) : element
    }

    private static let sidebarTabIdentifiers = [
        "sidebar.tab.home", "sidebar.tab.feed", "sidebar.tab.search",
        "sidebar.tab.library", "sidebar.tab.nowPlaying", "sidebar.tab.profile", "sidebar.tab.settings",
    ]

    private func focusIsOnSidebar(in app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "hasFocus == true AND identifier IN %@", Self.sidebarTabIdentifiers)
        return app.buttons.matching(predicate).count > 0
    }

    func testEveryTabHasSomethingFocusable() {
        for tab in ["Home", "Feed", "Search", "Library", "Settings", "Now Playing"] {
            let app = launch(tab: tab)
            XCTAssertNotNil(
                focusedElement(in: app),
                "The \(tab) tab has no focused element on appear. A tvOS region with no "
                + "focusable descendant cannot be entered, and every button press does nothing."
            )
            app.terminate()
        }
    }

    func testFeedHeroMovesDownIntoTheChipList() {
        let app = launch(tab: "Feed", extra: ["SOUNDING_TV_FEED_STATE": "loaded"])

        guard let hero = focusedElement(in: app) else {
            return XCTFail("Feed opened with nothing focused — the hero never took focus.")
        }
        XCTAssertEqual(
            hero.identifier, "feed.hero",
            "Feed opened with focus on \"\(hero.identifier)\", not the hero."
        )

        XCUIRemote.shared.press(.down)

        guard let next = focusedElement(in: app) else {
            return XCTFail("Focus vanished on Down from the hero — the chip list is unreachable.")
        }
        XCTAssertTrue(
            next.identifier.hasPrefix("feed.chip."),
            "Down from the hero did not move focus into the chip list — landed on "
            + "\"\(next.identifier)\" instead."
        )
    }

    func testSearchEntersContentNotSidebar() {
        let app = launch(tab: "Search")
        guard focusedElement(in: app) != nil else {
            return XCTFail("Search opened with nothing focused — the content is unreachable.")
        }
        XCTAssertFalse(
            focusIsOnSidebar(in: app),
            "Search opened with focus still on one of the sidebar's own tab rows — the sidebar's "
            + "glass panel stays expanded and covers the \"…SEARCHED\" header and the first result row."
        )
    }

    func testSettingsEntersContentNotSidebar() {
        let app = launch(tab: "Settings")
        guard let focused = focusedElement(in: app) else {
            return XCTFail("Settings opened with nothing focused — the content is unreachable.")
        }
        XCTAssertFalse(
            focusIsOnSidebar(in: app),
            "Settings opened with focus still on one of the sidebar's own tab rows — the sidebar "
            + "stays expanded and covers every row label."
        )
        XCTAssertEqual(
            focused.identifier, "settings.section.subscription",
            "Settings opened with focus on \"\(focused.identifier)\", not the Subscription row — "
            + "expected focus on the list's first NavigationLink."
        )
    }

    func testProfileAndDJModeAreNotAffected() {
        let profileApp = launch(tab: "Profile")
        XCTAssertFalse(
            focusIsOnSidebar(in: profileApp),
            "Profile opened with focus on the sidebar — this screen was not supposed to have the "
            + "gap Search/Settings had, but it does."
        )
        profileApp.terminate()

        let djApp = launch(
            tab: "NowPlaying",
            extra: ["SOUNDING_TV_DJ_OPEN": "1", "SOUNDING_TV_PLAY": "1"]
        )
        Thread.sleep(forTimeInterval: 3)
        guard let focused = focusedElement(in: djApp) else {
            return XCTFail("DJ Mode opened with nothing focused.")
        }
        XCTAssertEqual(
            focused.label, "Mix Now",
            "DJ Mode opened with focus on \"\(focused.label)\", not \"Mix Now\" — expected "
            + "`DJModeView`'s own `.defaultFocus` target to win with a track loaded."
        )
    }

    func testNowPlayingEmptyStateIsEnterable() {
        let app = launch(tab: "Now Playing", extra: ["SOUNDING_TV_FORCE_EMPTY_NOWPLAYING": "1"])
        guard let focused = focusedElement(in: app) else {
            return XCTFail(
                "Now Playing's empty state opened with nothing focused — the region is unenterable."
            )
        }
        XCTAssertEqual(
            focused.identifier, "nowplaying.empty.browseHome",
            "Now Playing's empty state opened with focus on \"\(focused.identifier)\", not the "
            + "Browse Home button — expected the empty state's own `.defaultFocus` target to win."
        )
        XCTAssertFalse(
            focusIsOnSidebar(in: app),
            "Now Playing's empty state opened with focus still on one of the sidebar's own tab rows."
        )
        app.terminate()
    }

    func testSignInScreenHasFocusableRecoveryAction() {
        let app = XCUIApplication()
        app.launchArguments += ["-red.forbes.sounding.didSeeTVWelcome", "YES"]
        app.launch()
        guard let focused = focusedElement(in: app) else {
            return XCTFail(
                "Sign-in screen opened with nothing focused — the whole app is unenterable while "
                + "signed out."
            )
        }
        XCTAssertEqual(
            focused.identifier, "login.recovery",
            "Sign-in screen opened with focus on \"\(focused.identifier)\", not the recovery "
            + "action — expected `.defaultFocus($focus, .action)` to land on `RecoveryButton`."
        )
        app.terminate()
    }

    func testSettingsWalksToTheBottomWithoutStranding() {
        let app = launch(tab: "Settings")
        var seen = Set<String>()

        for step in 0..<25 {
            guard let current = focusedElement(in: app) else {
                return XCTFail("Focus stranded after \(step) Down-presses in Settings.")
            }
            let id = current.identifier + current.label
            guard seen.insert(id).inserted || step == 0 else { break }
            XCUIRemote.shared.press(.down)
        }
    }

    func testSettingsCategoryOpensDetailAndBackReturnsToRoot() {
        let app = launch(tab: "Settings")
        let subscription = app.descendants(matching: .any)["settings.section.subscription"]
        XCTAssertTrue(subscription.waitForExistence(timeout: 8), "The Settings root never appeared.")

        XCUIRemote.shared.press(.down)

        let playback = app.descendants(matching: .any)["settings.section.playback"]
        XCTAssertTrue(
            playback.waitForExistence(timeout: 8),
            "Playback is missing from the Settings category list."
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.detail.playback"].waitForExistence(timeout: 8),
            "Selecting Playback didn't open its detail page."
        )
        let back = app.descendants(matching: .any)["settings.back"]
        XCTAssertTrue(
            back.waitForExistence(timeout: 8),
            "The Playback page has no visible Settings back action."
        )

        XCTAssertEqual(
            focusedElement(in: app)?.identifier,
            "settings.back",
            "The nested Settings page did not open with its back action focused."
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            subscription.waitForExistence(timeout: 8),
            "The Settings back action did not return from Playback to the Settings root."
        )
    }

    func testSidebarHeaderNameIsNotClipped() {
        let app = launch(tab: "Home")
        XCUIRemote.shared.press(.left)

        let header = app.staticTexts["Alex Forbes-Reed"]
        guard header.waitForExistence(timeout: 5) else {
            return XCTFail(
                "Sidebar header did not render the demo user's full name in one piece — "
                + "dumping the tree: \(app.debugDescription)"
            )
        }
        XCTAssertFalse(
            header.label.hasSuffix("…"),
            "Sidebar header clipped the name to \"\(header.label)\" instead of showing it in full."
        )
    }

    func testLibraryShelvesFocusTravelAndOpenLikes() {
        let app = launch(tab: "Library", extra: ["SOUNDING_TV_LIBRARY_LIKES": "2400"])
        guard focusedElement(in: app) != nil else {
            return XCTFail("Library opened with nothing focused at all.")
        }
        var visited: [String] = []
        for _ in 0..<6 {
            press(.down)
            visited.append(focusedElement(in: app)?.identifier ?? "nil")
        }
        XCTAssertFalse(visited.contains("nil"), "Focus stranded walking down the Library shelves: \(visited)")
        XCTAssertTrue(
            visited.contains { $0.hasPrefix("library.") },
            "Walking down never reached a Library shelf: \(visited)"
        )
        shot("library-shelves-walk")

        for _ in 0..<12 where focusedElement(in: app)?.identifier != "library.playlists.likes" {
            press(.up)
        }
        guard focusedElement(in: app)?.identifier == "library.playlists.likes" else {
            return XCTFail("Could not reach the Likes tile in Playlists (focused: \(focusLabel(app))).")
        }
        press(.select, settle: 1.5)
        press(.down)
        let inGrid = focusedElement(in: app)?.identifier ?? "nil"
        XCTAssertTrue(
            inGrid.hasPrefix("library.detail."),
            "Likes detail did not take focus into its controls or grid (focused: \(inGrid))."
        )
        for _ in 0..<5 { press(.down, settle: 0.5) }
        XCTAssertNotNil(focusedElement(in: app), "Focus stranded paging down the Likes grid.")
        shot("library-likes-grid")
        press(.menu, settle: 1.2)
        XCTAssertEqual(focusedElement(in: app)?.identifier, "library.playlists.likes", "Back from Likes did not return focus to its tile.")
        app.terminate()
    }

    func testCommentsSheetThreadsAreReachableWithTheRemote() {
        let app = launch(tab: "Now Playing", extra: [
            "SOUNDING_TV_UI_DESTINATION": "now-playing",
            "SOUNDING_TV_PLAY": "1",
            "SOUNDING_TV_COMMENTS_DEMO": "1",
            "SOUNDING_TV_COMMENTS_OPEN": "1",
        ])

        let close = app.descendants(matching: .any)["comments.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "The comments sheet never appeared.")
        XCTAssertNotNil(focusedElement(in: app), "The comments sheet opened with nothing focused.")

        var seen = Set<String>()
        var reachedSearchPill = false
        for _ in 0..<40 {
            XCUIRemote.shared.press(.down)
            if let element = focusedElement(in: app), element.identifier.hasPrefix("comments.row.") {
                if seen.isEmpty {
                    XCUIRemote.shared.press(.right)
                    Thread.sleep(forTimeInterval: 0.6)
                    let landed = focusedElement(in: app)
                    if landed?.identifier.hasPrefix("comments.search.") == true || landed?.label == "Search" {
                        reachedSearchPill = true
                    }
                    shot("comments-after-right-\(landed?.identifier ?? "nil")")
                    XCUIRemote.shared.press(.left)
                }
                seen.insert(element.identifier)
            }
        }

        XCTAssertTrue(reachedSearchPill,
            "Right from a comment row never reached its Search button.")

        XCTAssertTrue(seen.contains("comments.row.9"),
            "The nested reply row never took focus — replies are unreachable with the remote.")
        XCTAssertTrue(seen.contains("comments.row.8"),
            "The untimed General row never took focus — read-only rows after the last focusable one are unreachable on tvOS.")

        app.terminate()
    }

    private static let fixtureNowPlaying = [
        "SOUNDING_TV_UI_FIXTURE": "1",
        "SOUNDING_TV_UI_DESTINATION": "now-playing",
    ]

    private func staticTextsContaining(_ needle: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", needle))
    }

    private func walk(to identifier: String, in app: XCUIApplication, pressing direction: XCUIRemote.Button, limit: Int = 12) -> Bool {
        for _ in 0..<limit {
            if let focused = focusedElement(in: app), focused.identifier == identifier { return true }
            XCUIRemote.shared.press(direction)
            Thread.sleep(forTimeInterval: 0.6)
        }
        return focusedElement(in: app)?.identifier == identifier
    }

    func testButtonRowOpensPanelsAndMenuClosesThem() {
        let app = launch(tab: "Now Playing", extra: Self.fixtureNowPlaying)

        let upNext = app.descendants(matching: .any)["nowplaying.action.upNext"]
        guard upNext.waitForExistence(timeout: 20) else {
            return XCTFail("Now Playing never rendered its button row.")
        }
        XCTAssertTrue(walk(to: "nowplaying.action.upNext", in: app, pressing: .right), "Right from Play never reached Up Next.")

        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 1.2)
        var reachedRow = false
        for _ in 0..<4 {
            if let focused = focusedElement(in: app), focused.identifier.hasPrefix("nowplaying.upnext.") {
                reachedRow = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(reachedRow, "Opening Up Next did not move focus into the panel.")
        shot("upnext-panel-focused")

        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(
            focusedElement(in: app)?.identifier, "nowplaying.action.upNext",
            "Closing the panel did not return focus to the button that opened it."
        )
        app.terminate()
    }

    func testWaveformFocusAndScrubKeysDoNotLeaveTheLine() {
        let app = launch(tab: "Now Playing", extra: Self.fixtureNowPlaying)

        let play = app.buttons["Play"]
        guard play.waitForExistence(timeout: 20) else { return XCTFail("Now Playing never rendered its transport.") }
        XCUIRemote.shared.press(.up)
        Thread.sleep(forTimeInterval: 0.8)
        let wave = app.descendants(matching: .any)["Playback position"]
        XCTAssertTrue(wave.exists, "The waveform exposes no Playback position element.")
        XCTAssertTrue(wave.hasFocus, "Up from the button row did not focus the waveform.")
        XCUIRemote.shared.press(.right)
        Thread.sleep(forTimeInterval: 0.6)
        XCUIRemote.shared.press(.left)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(wave.hasFocus, "Left and right scrub keys moved focus off the waveform.")
        shot("waveform-focused")
        app.terminate()
    }

    func testTrackMapRowsAndSaveAreRealButtons() {
        var env = Self.fixtureNowPlaying
        env["SOUNDING_TV_CUES_OPEN"] = "1"
        let app = launch(tab: "Now Playing", extra: env)

        let mixIn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mix In'")).element(boundBy: 0)
        XCTAssertTrue(mixIn.waitForExistence(timeout: 25), "The Track Map's Mix In row is not a button.")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mix Out'")).count > 0,
            "The Track Map's Mix Out row is not a button."
        )
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save This Moment'")).count > 0,
            "The Track Map's save action is not a button."
        )
        XCTAssertEqual(staticTextsContaining("MIX IN", in: app).count, 0, "Mix In is still an uppercase kicker.")
        app.terminate()
    }

    func testDJConsoleHasNoImplementationProse() {
        var env = Self.fixtureNowPlaying
        env["SOUNDING_TV_DJ_OPEN"] = "1"
        env["SOUNDING_TV_PLAY"] = "1"
        let app = launch(tab: "Now Playing", extra: env)

        let mixNow = app.buttons["Mix Now"]
        XCTAssertTrue(mixNow.waitForExistence(timeout: 25), "The DJ console never appeared.")

        for prose in ["estimated, not measured", "PLAN PREVIEW", "Listening and planning", "Knobs are a drawing", "No wavefor…"] {
            XCTAssertEqual(
                staticTextsContaining(prose, in: app).count, 0,
                "The DJ console still shows developer prose: \"\(prose)\"."
            )
        }
        XCTAssertTrue(app.buttons["Turn Off"].exists, "The DJ transport pills are not buttons.")
        XCTAssertTrue(app.buttons["Close"].exists, "The DJ close control is not a button.")
        app.terminate()
    }

    func testAboutSettingsHidesDeveloperContent() {
        let app = launch(tab: "Settings", extra: ["SOUNDING_TV_TV_SETTINGS": "about"])
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.detail.about"].waitForExistence(timeout: 15),
            "The About & Advanced page never appeared."
        )
        XCTAssertTrue(app.staticTexts["Version"].exists, "The About rows are missing.")
        #if DEBUG
        XCTAssertTrue(app.staticTexts["Source"].exists, "The debug Source row is missing.")
        #else
        XCTAssertEqual(staticTextsContaining("github.com", in: app).count, 0, "The Source row is shown in a release build.")
        XCTAssertEqual(app.staticTexts["Source"].exists, false, "The Source row is shown in a release build.")
        XCTAssertEqual(app.staticTexts["Mix Engine"].exists, false, "Diagnostics are shown in a release build.")
        #endif
        app.terminate()
    }

    func testAlbumDetailCollectionSettingsIsAnIconButton() {
        let app = launch(tab: "Library", extra: [
            "SOUNDING_TV_UI_FIXTURE": "1",
            "SOUNDING_TV_UI_DESTINATION": "album",
        ])
        let button = app.buttons["Collection Settings"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Collection Settings is missing from the album action row.")
        XCTAssertEqual(
            staticTextsContaining("Collection Settings", in: app).count, 0,
            "Collection Settings still renders its long label instead of an icon-only control."
        )
        app.terminate()
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

extension FocusWalkTests {
    private struct AuditScreen {
        let name: String
        let tab: String
        let env: [String: String]
        let wait: TimeInterval
        let moves: [XCUIRemote.Button]
    }

    private static let auditScreens: [AuditScreen] = [
        AuditScreen(name: "home", tab: "Home", env: [:], wait: 6, moves: [.down, .down, .right, .down, .left]),
        AuditScreen(name: "following", tab: "Following", env: ["SOUNDING_TV_FEED_STATE": "loaded"], wait: 6, moves: [.down, .down, .right, .down]),
        AuditScreen(name: "search", tab: "Search", env: [:], wait: 6, moves: [.down, .down, .right, .down]),
        AuditScreen(name: "library", tab: "Library", env: [:], wait: 6, moves: [.right, .down, .down, .right, .down]),
        AuditScreen(name: "profile", tab: "Profile", env: [:], wait: 6, moves: [.down, .down, .right, .down]),
        AuditScreen(name: "settings", tab: "Settings", env: [:], wait: 5, moves: [.down, .down, .down, .select, .down, .down]),
        AuditScreen(name: "nowplaying", tab: "Now Playing", env: ["SOUNDING_TV_UI_DESTINATION": "now-playing", "SOUNDING_TV_PLAY": "1"], wait: 10, moves: [.up, .up, .right, .right, .down, .down]),
        AuditScreen(name: "dj", tab: "Now Playing", env: ["SOUNDING_TV_UI_DESTINATION": "now-playing", "SOUNDING_TV_PLAY": "1", "SOUNDING_TV_DJ_OPEN": "1"], wait: 12, moves: [.down, .down, .right, .right, .up, .left]),
        AuditScreen(name: "comments", tab: "Now Playing", env: ["SOUNDING_TV_UI_DESTINATION": "now-playing", "SOUNDING_TV_PLAY": "1", "SOUNDING_TV_COMMENTS_DEMO": "1", "SOUNDING_TV_COMMENTS_OPEN": "1"], wait: 12, moves: [.down, .down, .right, .down]),
        AuditScreen(name: "trackmap", tab: "Now Playing", env: ["SOUNDING_TV_UI_DESTINATION": "now-playing", "SOUNDING_TV_PLAY": "1", "SOUNDING_TV_CUES_OPEN": "1"], wait: 12, moves: [.down, .down, .right, .down]),
        AuditScreen(name: "album", tab: "Library", env: ["SOUNDING_TV_UI_DESTINATION": "album"], wait: 8, moves: [.down, .down, .right, .down]),
        AuditScreen(name: "artist", tab: "Library", env: ["SOUNDING_TV_UI_DESTINATION": "artist"], wait: 8, moves: [.down, .down, .right, .down]),
        AuditScreen(name: "behind", tab: "Now Playing", env: ["SOUNDING_TV_UI_DESTINATION": "behind-track"], wait: 8, moves: [.down, .down, .right]),
        AuditScreen(name: "ambient", tab: "Now Playing", env: ["SOUNDING_TV_UI_DESTINATION": "now-playing", "SOUNDING_TV_PLAY": "1", "SOUNDING_TV_AMBIENT": "2"], wait: 14, moves: []),
    ]

    private static var auditOutputURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["A11Y_AUDIT_OUT"] ?? "/tmp/a11y-audit-tv.json")
    }

    private func auditIssues(_ app: XCUIApplication, screen: String, step: String) -> [[String: String]] {
        var collected: [[String: String]] = []
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                collected.append([
                    "screen": screen,
                    "step": step,
                    "type": String(describing: issue.auditType),
                    "typeRaw": String(issue.auditType.rawValue),
                    "element": issue.element.map { "\($0.elementType.rawValue)|\($0.identifier)|\($0.label)" } ?? "",
                    "summary": issue.compactDescription,
                    "detail": issue.detailedDescription,
                ])
                return true
            }
        } catch {
            collected.append(["screen": screen, "step": step, "type": "auditError", "summary": "\(error)"])
        }
        return collected
    }

    private func unlabelledInteractiveElements(_ app: XCUIApplication, screen: String, step: String) -> [[String: String]] {
        var found: [[String: String]] = []
        let types: [XCUIElement.ElementType] = [.button, .cell, .link, .toggle, .switch, .slider, .segmentedControl]
        let symbolName = "^[a-z0-9]+(\\.[a-z0-9]+)+$"
        for type in types {
            let query = app.descendants(matching: type).matching(
                NSPredicate(format: "(label == '' OR label MATCHES %@) AND isEnabled == true", symbolName)
            )
            let count = min(query.count, 60)
            for index in 0..<count {
                let element = query.element(boundBy: index)
                guard element.isHittable else { continue }
                if type == .cell, element.label.isEmpty,
                   element.buttons.matching(NSPredicate(format: "label != ''")).count > 0 {
                    continue
                }
                let kind = element.label.isEmpty ? "emptyLabel" : "symbolLabel"
                found.append([
                    "screen": screen, "step": step, "type": kind,
                    "element": "\(type.rawValue)|\(element.identifier)|\(element.label)",
                    "summary": "Hittable \(type) with \(element.label.isEmpty ? "an empty label" : "a raw symbol name as its label (\"\(element.label)\")") (identifier: \"\(element.identifier)\").",
                ])
            }
        }
        if let focused = focusedElement(in: app),
           [.button, .cell, .link, .toggle, .switch, .slider].contains(focused.elementType),
           focused.label.isEmpty || focused.label.range(of: symbolName, options: .regularExpression) != nil {
            found.append([
                "screen": screen, "step": step, "type": focused.label.isEmpty ? "emptyFocusedLabel" : "symbolFocusedLabel",
                "element": "\(focused.elementType.rawValue)|\(focused.identifier)|\(focused.label)",
                "summary": "Focused \(focused.elementType) reads as \"\(focused.label)\" (identifier: \"\(focused.identifier)\").",
            ])
        }
        return found
    }

    func testAccessibilityAuditWalk() throws {
        continueAfterFailure = true
        let only = ProcessInfo.processInfo.environment["A11Y_SCREENS"]?
            .split(separator: ",").map(String.init)
        var report: [[String: String]] = []
        var perScreen: [String: [String: Int]] = [:]

        for screen in Self.auditScreens where only == nil || only!.contains(screen.name) {
            var env = screen.env
            env["SOUNDING_TV_DISMISS_WELCOME"] = "1"
            let app = launch(tab: screen.tab, extra: env)
            Thread.sleep(forTimeInterval: screen.wait)

            var screenIssues: [[String: String]] = []
            screenIssues += auditIssues(app, screen: screen.name, step: "0")
            screenIssues += unlabelledInteractiveElements(app, screen: screen.name, step: "0")
            for (index, move) in screen.moves.enumerated() {
                press(move, settle: 1.0)
                let step = "\(index + 1)-\(move)"
                screenIssues += unlabelledInteractiveElements(app, screen: screen.name, step: step)
                if index == screen.moves.count - 1 {
                    screenIssues += auditIssues(app, screen: screen.name, step: step)
                }
            }
            shot("a11y-\(screen.name)")

            var counts: [String: Int] = [:]
            for issue in screenIssues { counts[issue["type"] ?? "?", default: 0] += 1 }
            perScreen[screen.name] = counts
            report += screenIssues

            let note = XCTAttachment(string: "\(screen.name): \(counts)")
            note.name = "a11y-\(screen.name)-counts"
            note.lifetime = .keepAlways
            add(note)
            app.terminate()
        }

        let payload: [String: Any] = ["perScreen": perScreen, "issues": report]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.auditOutputURL)
        }
        let unlabelled = report.filter { ($0["type"] ?? "").hasSuffix("Label") }
        XCTAssertTrue(
            unlabelled.isEmpty,
            "Interactive elements with empty or symbol-name labels: " + unlabelled.map { "\($0["screen"]!)/\($0["step"]!) \($0["element"] ?? "")" }.joined(separator: "; ")
        )
    }
}

extension FocusWalkTests {
    private func smoothOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    private func smoothMetrics(_ app: XCUIApplication) -> [XCTMetric] {
        [XCTHitchMetric(application: app), XCTClockMetric()]
    }

    private func smoothLaunch(tab: String, extra: [String: String] = [:], wait: TimeInterval = 8) -> XCUIApplication {
        var env = ["SOUNDING_TV_UI_FIXTURE": "1", "SOUNDING_TV_DISMISS_WELCOME": "1"]
        for (key, value) in extra { env[key] = value }
        let app = launch(tab: tab, extra: env)
        Thread.sleep(forTimeInterval: wait)
        return app
    }

    func testSmooth01_HomeFocusAcrossShelves() {
        let app = smoothLaunch(tab: "Home")
        measure(metrics: smoothMetrics(app), options: smoothOptions()) {
            for button: XCUIRemote.Button in [.right, .right, .right, .down, .right, .right, .down, .left, .left, .down, .right, .up, .up, .left, .left, .up] {
                XCUIRemote.shared.press(button)
                Thread.sleep(forTimeInterval: 0.45)
            }
        }
        app.terminate()
    }

    func testSmooth02_LibraryFocusAndSearch() {
        let app = smoothLaunch(tab: "Library")
        measure(metrics: smoothMetrics(app), options: smoothOptions()) {
            for button: XCUIRemote.Button in [.right, .down, .down, .down, .right, .down, .up, .up, .left, .up] {
                XCUIRemote.shared.press(button)
                Thread.sleep(forTimeInterval: 0.45)
            }
        }
        app.terminate()
    }

    func testSmooth03_SidebarTabSwitches() {
        let app = smoothLaunch(tab: "Home")
        measure(metrics: smoothMetrics(app), options: smoothOptions()) {
            for _ in 0..<3 {
                XCUIRemote.shared.press(.left)
                Thread.sleep(forTimeInterval: 0.6)
                XCUIRemote.shared.press(.down)
                Thread.sleep(forTimeInterval: 0.6)
                XCUIRemote.shared.press(.select)
                Thread.sleep(forTimeInterval: 1.2)
            }
            for _ in 0..<3 {
                XCUIRemote.shared.press(.left)
                Thread.sleep(forTimeInterval: 0.6)
                XCUIRemote.shared.press(.up)
                Thread.sleep(forTimeInterval: 0.6)
                XCUIRemote.shared.press(.select)
                Thread.sleep(forTimeInterval: 1.2)
            }
        }
        app.terminate()
    }

    func testSmooth04_NowPlayingPanelSlideIn() {
        let app = smoothLaunch(tab: "Now Playing", extra: ["SOUNDING_TV_UI_DESTINATION": "now-playing"], wait: 12)
        _ = app.descendants(matching: .any)["nowplaying.action.upNext"].waitForExistence(timeout: 20)
        _ = walk(to: "nowplaying.action.upNext", in: app, pressing: .right)
        measure(metrics: smoothMetrics(app), options: smoothOptions()) {
            XCUIRemote.shared.press(.select)
            Thread.sleep(forTimeInterval: 1.5)
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 0.5)
            XCUIRemote.shared.press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
        }
        app.terminate()
    }

    func testSmooth05_IdleAmbientFade() {
        let app = smoothLaunch(
            tab: "Now Playing",
            extra: ["SOUNDING_TV_UI_DESTINATION": "now-playing", "SOUNDING_TV_PLAY": "1", "SOUNDING_TV_AMBIENT": "6"],
            wait: 4
        )
        measure(metrics: smoothMetrics(app), options: smoothOptions()) {
            Thread.sleep(forTimeInterval: 9)
            XCUIRemote.shared.press(.right)
            Thread.sleep(forTimeInterval: 2)
        }
        app.terminate()
    }
}
