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
        app.launch()
        return app
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

    func testLibraryLoadingSkeletonIsEnterable() {
        let app = launch(tab: "Library", extra: ["SOUNDING_TV_LIBRARY_SKELETON": "1"])

        guard let onEntry = focusedElement(in: app) else {
            return XCTFail(
                "Library opened over its loading skeleton with nothing focused at all — "
                + "dumping the tree: \(app.debugDescription)"
            )
        }
        XCTAssertFalse(
            focusIsOnSidebar(in: app),
            "Library opened with focus still on the sidebar's own tab rows, not the rail "
            + "(focused: \"\(onEntry.identifier)\")."
        )

        XCUIRemote.shared.press(.right)

        guard let afterRight = focusedElement(in: app) else {
            return XCTFail(
                "Focus stranded after a Right-press out of the Library rail — the loading "
                + "skeleton has no focusable descendant, so its `.focusSection()` cannot be entered."
            )
        }
        XCTAssertEqual(
            afterRight.identifier, "content.skeleton",
            "Right out of the Library rail landed on \"\(afterRight.identifier)\" rather than the "
            + "loading skeleton — the content pane is not enterable while loading."
        )
        app.terminate()
    }

    func testLibrarySortPickerIsReachableAndFocusable() {
        let app = launch(tab: "Library")

        guard focusedElement(in: app) != nil else {
            return XCTFail("Library opened with nothing focused at all.")
        }

        func pickerHasFocus() -> Bool {
            let picker = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'tracklist.sort'"))
                .element(boundBy: 0)
            guard picker.exists else { return false }
            if picker.hasFocus { return true }
            return picker.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).count > 0
        }

        var walkLog: [String] = []
        let moves: [XCUIRemote.Button] = [.right, .up, .up, .right, .right, .right, .left]
        for move in moves where !pickerHasFocus() {
            XCUIRemote.shared.press(move)
            Thread.sleep(forTimeInterval: 1.0)
            let f = focusedElement(in: app)
            walkLog.append("after \(move): id=\"\(f?.identifier ?? "nil")\" label=\"\(f?.label ?? "nil")\"")
        }
        let finalShot = XCUIScreen.main.screenshot()
        try? finalShot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/sort-walk-final.png"))
        guard pickerHasFocus() else {
            try? app.debugDescription.data(using: .utf8)?
                .write(to: URL(fileURLWithPath: "/tmp/sort-walk-dump.txt"))
            return XCTFail(
                "Could not walk focus onto the sort picker. Walk: \(walkLog.joined(separator: " | "))"
            )
        }

        let focusedNow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
            .element(boundBy: 0)
        let frame = focusedNow.frame

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "sort-picker-focused"
        attachment.lifetime = .keepAlways
        add(attachment)

        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/sort-capsule-focused.png"))
        let meta = #"{"x": \#(frame.origin.x), "y": \#(frame.origin.y), "w": \#(frame.size.width), "h": \#(frame.size.height)}"#
        try? meta.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/sort-capsule-focused.json"))

        app.terminate()
    }

    func testCommentsSheetThreadsAreReachableWithTheRemote() {
        let app = launch(tab: "Now Playing", extra: [
            "SOUNDING_TV_COMMENTS_DEMO": "1",
            "SOUNDING_TV_COMMENTS_OPEN": "1",
        ])

        let close = app.descendants(matching: .any)["comments.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "The comments sheet never appeared.")
        XCTAssertNotNil(focusedElement(in: app), "The comments sheet opened with nothing focused.")

        var seen = Set<String>()
        for _ in 0..<40 {
            XCUIRemote.shared.press(.down)
            if let element = focusedElement(in: app), element.identifier.hasPrefix("comments.row.") {
                seen.insert(element.identifier)
            }
        }

        XCTAssertTrue(seen.contains("comments.row.9"),
            "The nested reply row never took focus — replies are unreachable with the remote.")
        XCTAssertTrue(seen.contains("comments.row.8"),
            "The untimed General row never took focus — read-only rows after the last focusable one are unreachable on tvOS.")

        app.terminate()
    }
}
