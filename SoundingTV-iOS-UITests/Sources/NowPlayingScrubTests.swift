import XCTest

@MainActor
final class NowPlayingScrubTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(
        _ environment: [String: String],
        contentSize: String = "UICTContentSizeCategoryL",
        fixture: Bool = true
    ) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = fixture ? "1" : "0"
        app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var scrubber: XCUIElement {
        app.otherElements.matching(NSPredicate(format: "label == 'Playback position'")).firstMatch
    }

    private var probe: XCUIElement {
        app.staticTexts["np.seek.probe"]
    }

    private static func seconds(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func position() -> (now: TimeInterval, duration: TimeInterval)? {
        guard let value = scrubber.value as? String else { return nil }
        let pieces = value.components(separatedBy: " of ")
        guard pieces.count == 2, let now = Self.seconds(pieces[0]), let duration = Self.seconds(pieces[1]) else { return nil }
        return (now, duration)
    }

    private func probeResult(timeout: TimeInterval = 8) -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let label = probe.label
            if label.hasPrefix("target=") {
                return Dictionary(uniqueKeysWithValues: label.split(separator: ";").compactMap { pair in
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    return kv.count == 2 ? (kv[0], kv[1]) : nil
                })
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return [:]
    }

    @discardableResult
    private func drag(from start: CGFloat, to end: CGFloat, name: String) -> (target: TimeInterval, samples: [TimeInterval], probe: [String: String]) {
        let frame = scrubber.frame
        let y = 18 / max(frame.height, 1)
        let origin = scrubber.coordinate(withNormalizedOffset: CGVector(dx: start, dy: y))
        let destination = scrubber.coordinate(withNormalizedOffset: CGVector(dx: end, dy: y))
        let duration = position()?.duration ?? 0
        origin.press(forDuration: 0.15, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.2)
        var samples: [TimeInterval] = []
        for _ in 0..<12 {
            if let now = position()?.now { samples.append(now) }
        }
        let result = probeResult()
        let target = result["target"].flatMap(Double.init) ?? duration * Double(end)
        note(name, "target \(target)\nsamples \(samples)\nprobe \(result)")
        return (target, samples, result)
    }

    func testReleasingTheScrubberHoldsTheReleasedPosition() {
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_SEEK_PROBE": "1"])
        XCTAssertTrue(scrubber.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)

        for (start, end) in [(0.15, 0.78), (0.8, 0.3), (0.3, 0.55)] as [(CGFloat, CGFloat)] {
            let result = drag(from: start, to: end, name: "fixture \(start)→\(end)")
            XCTAssertFalse(result.samples.isEmpty)
            for sample in result.samples {
                XCTAssertGreaterThanOrEqual(sample, result.target - 2, "snapped back after release")
                XCTAssertLessThanOrEqual(sample, result.target + 12, "jumped past the release point")
            }
            XCTAssertLessThan(Double(result.probe["snap"] ?? "9") ?? 9, 0.5)
        }
    }

    func testReleasingTheScrubberOnARealPlayer() throws {
        let host = ProcessInfo.processInfo.environment["SOUNDING_TV_STREAM_HOST"] ?? "http://127.0.0.1:8787"
        guard let health = URL(string: "\(host)/health"),
              (try? Data(contentsOf: health)) != nil else {
            throw XCTSkip("Mock SoundCloud isn't running at \(host)")
        }
        launch([
            "SOUNDING_TV_STREAM_HOST": host,
            "SOUNDING_TV_AUTOPLAY": "1",
            "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1",
            "SOUNDING_TV_SEEK_PROBE": "1",
        ], fixture: false)
        XCTAssertTrue(scrubber.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)
        if let play = app.buttons.matching(NSPredicate(format: "label == 'Play'")).allElementsBoundByIndex.first(where: \.isHittable) {
            play.tap()
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Pause'")).firstMatch.waitForExistence(timeout: 20), "the mock track never started")
        Thread.sleep(forTimeInterval: 6)
        capture("real-player-before-scrub")

        var report: [String] = []
        for (start, end) in [(0.1, 0.62), (0.65, 0.2), (0.2, 0.85), (0.85, 0.45)] as [(CGFloat, CGFloat)] {
            let result = drag(from: start, to: end, name: "real \(start)→\(end)")
            report.append(result.probe.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
            for sample in result.samples {
                XCTAssertGreaterThanOrEqual(sample, result.target - 2, "snapped back after release")
            }
            XCTAssertNotEqual(result.probe["mediaMs"], "none", "the player never confirmed the seek")
            XCTAssertLessThan(Double(result.probe["snap"] ?? "9") ?? 9, 0.5)
            Thread.sleep(forTimeInterval: 3)
        }
        note("real-player-report", report.joined(separator: "\n"))
        capture("real-player-after-scrub")
    }

    func testScrubFrameTime() {
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_FRAME_PROBE": "1"])
        XCTAssertTrue(scrubber.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            let origin = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3))
            let destination = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3))
            origin.press(forDuration: 0.1, thenDragTo: destination, withVelocity: .default, thenHoldForDuration: 0.1)
            destination.press(forDuration: 0.1, thenDragTo: origin, withVelocity: .default, thenHoldForDuration: 0.1)
        }
    }

    func testPaneTabsAndPanes() {
        let sizes = [("L", "UICTContentSizeCategoryL"), ("AXXL", "UICTContentSizeCategoryAccessibilityXL")]
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let mode = appearance == .light ? "light" : "dark"
            for (sizeName, size) in sizes {
                for (index, label) in [("3", "track"), ("0", "mix")] {
                    for pane in ["upNext", "comments", "tracklist"] {
                        launch([
                            "SOUNDING_TV_NOW_PLAYING_EXPANDED": "1",
                            "SOUNDING_TV_NOW_PLAYING_REVIEW": pane,
                            "SOUNDING_TV_FAKE_INDEX": index,
                            "SOUNDING_TV_COMMENTS_DEMO": "1",
                        ], contentSize: size)
                        Thread.sleep(forTimeInterval: 4)
                        capture("np-\(mode)-\(sizeName)-\(label)-\(pane)")
                    }
                }
            }
        }
        XCUIDevice.shared.appearance = .dark
    }

    func testScrubbingKeepsTheTimesClear() {
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1"])
        XCTAssertTrue(scrubber.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        let origin = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        let destination = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3))
        origin.press(forDuration: 0.1, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 3)
        capture("np-scrub-released")
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NP_SHOT": "scrub"])
        Thread.sleep(forTimeInterval: 4)
        capture("np-scrub-held")
        launch(["SOUNDING_TV_NOW_PLAYING_EXPANDED": "1", "SOUNDING_TV_NP_SHOT": "scrub", "SOUNDING_TV_NOW_PLAYING_REVIEW": "upNext"])
        Thread.sleep(forTimeInterval: 4)
        capture("np-scrub-held-list")
    }
}

@MainActor
final class HomeLikedByTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testLikedByPicksOpenTheirTracks() {
        continueAfterFailure = true
        let runs: [(XCUIDevice.Appearance, String)] = [
            (.light, "UICTContentSizeCategoryL"),
            (.dark, "UICTContentSizeCategoryL"),
            (.light, "UICTContentSizeCategoryAccessibilityXL"),
        ]
        for (appearance, size) in runs {
            XCUIDevice.shared.appearance = appearance
            let app = XCUIApplication()
            app.launchEnvironment["SOUNDING_TV_UI_FIXTURE"] = "1"
            app.launchEnvironment["SOUNDING_TV_DISMISS_WELCOME"] = "1"
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let name = "\(appearance == .light ? "light" : "dark")-\(size.hasSuffix("XL") ? "AXXL" : "L")"
            let card = app.buttons["Juno Vale's Picks, playlist"]
            var swipes = 0
            while !(card.exists && card.isHittable), swipes < 16 {
                app.swipeUp(velocity: .slow)
                swipes += 1
            }
            XCTAssertTrue(card.isHittable, "Liked By card isn't reachable")
            capture(app, "home-likedby-\(name)")
            card.tap()
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 8), "picks view didn't open")
            Thread.sleep(forTimeInterval: 1.5)
            capture(app, "home-likedby-detail-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .dark
    }
}
