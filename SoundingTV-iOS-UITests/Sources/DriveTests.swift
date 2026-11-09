import XCTest

@MainActor
final class DriveTests: XCTestCase {
    private var app: XCUIApplication!

    private enum Look: String {
        case light
        case dark
        case xl
    }

    private var device: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    private func launch(_ look: Look, _ environment: [String: String]) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "1"
        app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        let size = look == .xl ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        XCUIDevice.shared.appearance = look == .dark ? .dark : .light
        app.launch()
        sleep(4)
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        sleep(1)
        return true
    }

    private func run(_ looks: [Look], _ name: String, _ environment: [String: String], steps: (Look) -> Void) {
        for look in looks {
            launch(look, environment)
            capture("\(device)-\(name)-\(look.rawValue)-0")
            steps(look)
            app.terminate()
        }
    }

    private let all: [Look] = [.light, .dark, .xl]

    func testSortAndFilter() {
        run(all, "sortfilter", ["SOUNDING_TV_PHONE_TAB": "likes"]) { look in
            if device == "iphone" {
                _ = tap(app.staticTexts["Likes"])
                capture("\(device)-sortfilter-\(look.rawValue)-likes")
            }
            let menu = app.buttons["Sort & Filter"]
            if tap(menu) {
                capture("\(device)-sortfilter-\(look.rawValue)-menu")
            } else {
                let filter = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sort' OR label CONTAINS[c] 'filter'")).firstMatch
                if tap(filter) { capture("\(device)-sortfilter-\(look.rawValue)-menu") }
            }
        }
    }

    func testColumns() {
        run(all, "columns", ["SOUNDING_TV_PHONE_TAB": "likes"]) { look in
            let header = app.buttons["Artist"].firstMatch
            if header.waitForExistence(timeout: 6) {
                header.press(forDuration: 1.2)
                sleep(1)
                capture("\(device)-columns-\(look.rawValue)-menu")
            }
        }
    }

    func testSets() {
        run(all, "sets", ["SOUNDING_TV_PHONE_TAB": "sets", "SOUNDING_TV_FIXTURE_SET": "2h"]) { look in
            if device == "iphone" { _ = tap(app.staticTexts["Sets"]); capture("\(device)-sets-\(look.rawValue)-list") }
        }
    }

    func testPlayOnAndUpNext() {
        run([.light, .dark], "playon", ["SOUNDING_TV_PHONE_TAB": "likes", "SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_FAKE_OUTPUTS": "1"]) { look in
            let play = app.buttons["Play On"].firstMatch
            if tap(play) { capture("\(device)-playon-\(look.rawValue)-popover") }
        }
    }

    func testNowPlayingPanes() {
        for pane in ["lyrics", "upNext"] {
            run(all, "np-\(pane)", ["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": pane, "SOUNDING_TV_LYRICS_FIXTURE": "words"]) { _ in }
        }
    }

    func testLyricsStates() {
        for mode in ["consent", "off", "loading", "notFound", "instrumental", "offline", "mix", "plain"] {
            run([.light, .xl], "lyrics-\(mode)", ["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "lyrics", "SOUNDING_TV_LYRICS_FIXTURE": mode]) { _ in }
        }
    }

    func testTape() {
        run(all, "tape", ["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_FIXTURE_SET": "2h"]) { _ in }
    }

    func testAutoMix() {
        run(all, "automix", ["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_FAKE_MOVE": "1", "SOUNDING_TV_AUTOMIX_FIXTURE": "upcoming", "SOUNDING_TV_AUTOMIX_YOUR_MOVE": "1"]) { look in
            let line = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Mixing into' OR label CONTAINS 'Next mix'")).firstMatch
            if tap(line) { capture("\(device)-automix-\(look.rawValue)-plan") }
        }
    }

    func testMixHistory() {
        run(all, "mixhistory", ["SOUNDING_TV_PHONE_TAB": "mixes", "SOUNDING_TV_MIX_HISTORY_FIXTURE": "saved"]) { look in
            if device == "iphone" { _ = tap(app.staticTexts["Mixes"]); capture("\(device)-mixhistory-\(look.rawValue)-list") }
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS ' into '")).firstMatch
            if tap(row) { capture("\(device)-mixhistory-\(look.rawValue)-detail") }
        }
    }

    func testYourMoves() {
        run(all, "moves", ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "yourMoves", "SOUNDING_TV_AUTOMIX_FLAIR_FIXTURE": "1"]) { look in
            app.swipeUp()
            capture("\(device)-moves-\(look.rawValue)-scrolled")
        }
    }

    func testTiers() {
        for tier in ["free", "goPlus"] {
            run([.light, .xl], "tier-\(tier)", ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "subscription", "SOUNDING_TV_FIXTURE_TIER": tier]) { _ in }
        }
    }

    func testNetworkActivity() {
        run(all, "network", ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "networkActivity", "SOUNDING_TV_NETWORK_FIXTURE": "1"]) { look in
            let more = app.buttons["More"].firstMatch
            if tap(more) { capture("\(device)-network-\(look.rawValue)-more") }
        }
    }

    func testLocalMusic() {
        run(all, "localmusic", ["SOUNDING_TV_PHONE_TAB": "files", "SOUNDING_TV_LOCAL_MUSIC_FIXTURE": "loaded"]) { look in
            if device == "iphone" { _ = tap(app.staticTexts["Files"]); capture("\(device)-localmusic-\(look.rawValue)-files") }
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'First Light'")).firstMatch
            if row.waitForExistence(timeout: 4) {
                row.press(forDuration: 1.2)
                sleep(1)
                capture("\(device)-localmusic-\(look.rawValue)-rowmenu")
            }
        }
    }

    func testSearch() {
        run(all, "search", ["SOUNDING_TV_PHONE_TAB": "search", "SOUNDING_TV_UI_SEARCH": "night"]) { look in
            sleep(2)
            capture("\(device)-search-\(look.rawValue)-results")
        }
    }

    func testSettingsSidebar() {
        run(all, "settings", ["SOUNDING_TV_PHONE_TAB": "settings"]) { look in
            let folders = app.buttons["Music Folders"].firstMatch
            let fallback = app.staticTexts["Music Folders"].firstMatch
            if tap(folders) || tap(fallback) { capture("\(device)-settings-\(look.rawValue)-folders") }
        }
    }

    func testLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        for (name, environment) in [
            ("likes", ["SOUNDING_TV_PHONE_TAB": "likes"]),
            ("settings", ["SOUNDING_TV_PHONE_TAB": "settings"]),
            ("nowplaying", ["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_FIXTURE_SET": "2h"]),
            ("lyrics", ["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FAKE_NOWPLAYING": "1", "SOUNDING_TV_NOW_PLAYING_REVIEW": "lyrics", "SOUNDING_TV_LYRICS_FIXTURE": "words"]),
        ] {
            run([.light, .dark], "landscape-\(name)", environment) { _ in }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testSidebars() {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            run([.light], "sidebars-settings", ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_VISUAL_FIXTURES": "1"]) { _ in }
            return
        }
        let fixtures = ["SOUNDING_TV_VISUAL_FIXTURES": "1"]
        let looks = (ProcessInfo.processInfo.environment["SIDEBAR_LOOKS"] ?? "light,dark").split(separator: ",").compactMap { Look(rawValue: String($0)) }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let shape = orientation == .portrait ? "portrait" : "landscape"
            for (name, environment) in [
                ("home", ["SOUNDING_TV_PHONE_TAB": "home"]),
                ("likes", ["SOUNDING_TV_PHONE_TAB": "likes"]),
                ("account", ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "account"]),
                ("folders", ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": "musicFolders"]),
                ("playlists", ["SOUNDING_TV_PHONE_TAB": "playlists"]),
            ] {
                run(looks, "sb-\(shape)-\(name)", environment.merging(fixtures) { a, _ in a }) { look in
                    if name == "playlists" {
                        let cell = app.collectionViews.cells.element(boundBy: 0)
                        if tap(cell) { sleep(1); capture("\(device)-sb-\(shape)-playlist-detail-\(look.rawValue)") }
                    }
                    if name == "home" || name == "account" {
                        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
                        if tap(toggle) { sleep(1); capture("\(device)-sb-\(shape)-\(name)-toggled-\(look.rawValue)") }
                    }
                }
            }
        }
    }

    func testAppleSidebars() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let looks = (ProcessInfo.processInfo.environment["SIDEBAR_LOOKS"] ?? "light,dark").split(separator: ",").compactMap { Look(rawValue: String($0)) }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let shape = orientation == .portrait ? "portrait" : "landscape"
            for look in looks {
                XCUIDevice.shared.appearance = look == .dark ? .dark : .light
                for (name, bundle) in [("settings", "com.apple.Preferences"), ("files", "com.apple.DocumentsApp")] {
                    app = XCUIApplication(bundleIdentifier: bundle)
                    app.launch()
                    sleep(5)
                    capture("apple-\(name)-\(shape)-\(look.rawValue)")
                    let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
                    if tap(toggle) { sleep(1); capture("apple-\(name)-\(shape)-toggled-\(look.rawValue)") }
                    app.terminate()
                }
            }
        }
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
    }

    func testSidebarProbes() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let shape = orientation == .portrait ? "portrait" : "landscape"
            for probe in ["tabview", "split", "tabsplit"] {
                run([.light], "probe-\(shape)-\(probe)", ["SOUNDING_TV_SIDEBAR_PROBE": probe]) { look in
                    let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
                    if tap(toggle) { sleep(1); capture("\(device)-probe-\(shape)-\(probe)-toggled") }
                    if probe == "tabsplit", tap(app.buttons["Settings"].firstMatch) { sleep(1); capture("\(device)-probe-\(shape)-\(probe)-settings") }
                }
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        capture(name)
        sleep(4)
    }

    private func setSidebar(open: Bool) {
        let toggle = app.buttons[open ? "Show Sidebar" : "Hide Sidebar"].firstMatch
        guard toggle.waitForExistence(timeout: 2) else { return }
        toggle.tap()
        sleep(1)
    }

    func testSidebarShots() {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            run([.light], "shot-settings", ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_VISUAL_FIXTURES": "1"]) { _ in shot("iphone-settings-light") }
            return
        }
        sidebarShots([.landscapeLeft, .portrait])
    }

    func testSidebarShotsLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        sidebarShots([.landscapeLeft])
    }

    private func sidebarShots(_ orientations: [UIDeviceOrientation]) {
        let fixtures = ["SOUNDING_TV_VISUAL_FIXTURES": "1"]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let shape = orientation == .portrait ? "portrait" : "landscape"
            for look in [Look.light, .dark] {
                let suffix = "\(shape)-\(look.rawValue)"
                launch(look, ["SOUNDING_TV_PHONE_TAB": "home"].merging(fixtures) { a, _ in a })
                setSidebar(open: true)
                shot("home-sidebar-\(suffix)")
                setSidebar(open: false)
                shot("home-collapsed-\(suffix)")
                app.terminate()
                launch(look, ["SOUNDING_TV_PHONE_TAB": "likes"].merging(fixtures) { a, _ in a })
                setSidebar(open: true)
                shot("likes-\(suffix)")
                app.terminate()
                launch(look, ["SOUNDING_TV_PHONE_TAB": "playlists"].merging(fixtures) { a, _ in a })
                setSidebar(open: true)
                if tap(app.collectionViews.cells.element(boundBy: 0)) { sleep(1) }
                shot("playlist-detail-\(suffix)")
                app.terminate()
                for (name, deepLink) in [("account", "account"), ("music-folders", "musicFolders")] {
                    launch(look, ["SOUNDING_TV_PHONE_TAB": "settings", "SOUNDING_TV_PHONE_SETTINGS": deepLink].merging(fixtures) { a, _ in a })
                    shot("settings-\(name)-\(suffix)")
                    if name == "account" {
                        _ = tap(app.staticTexts["Playback"].firstMatch)
                        _ = tap(app.staticTexts["Account"].firstMatch)
                        shot("settings-account-tapped-\(suffix)")
                    }
                    app.terminate()
                }
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
