//
//  SharpStreamUITests.swift
//  SharpStreamUITests
//
//  Minimal smoke tests for launch and optional env-driven stream connect flow.
//

import XCTest
import AppKit

final class SharpStreamUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchSmoke() throws {
        let app = makeApp()
        launchApp(app)

        // Verify the main no-stream state is visible at startup.
        XCTAssertTrue(app.staticTexts["No Stream Connected"].waitForExistence(timeout: 5))
    }

    func testPasteStreamButtonExists() throws {
        let app = makeApp()
        launchApp(app)

        let pasteButton = app.buttons.matching(identifier: "pasteStreamToolbarButton").firstMatch
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
    }

    func testOptionalRTSPEnvConfiguration() throws {
        var env = ProcessInfo.processInfo.environment
        if env["SHARPSTREAM_TEST_RTSP_URL"] == nil {
            env.merge(loadSmokeEnvFile(), uniquingKeysWith: { current, _ in current })
        }
        let config = env["SHARPSTREAM_TEST_RTSP_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let config, !config.isEmpty else {
            throw XCTSkip("SHARPSTREAM_TEST_RTSP_URL not set; skipping stream-dependent smoke path")
        }

        XCTAssertTrue(config.hasPrefix("rtsp://"), "SHARPSTREAM_TEST_RTSP_URL should use rtsp://")
    }

    func testOptionalConnectRTSPViaPasteStreamURL() throws {
        guard let rtspURL = configuredRTSPURL() else {
            throw XCTSkip("SHARPSTREAM_TEST_RTSP_URL not set; skipping RTSP smoke path")
        }

        let app = makeApp()
        launchApp(app)
        pasteAndConnect(stream: rtspURL, app: app)

        // Wait for stream view state transition and connected controls.
        let noStreamText = app.staticTexts["No Stream Connected"]
        let connectedPredicate = NSPredicate(format: "exists == false")
        expectation(for: connectedPredicate, evaluatedWith: noStreamText)
        waitForExpectations(timeout: 12)

        let playPause = assertPlayPauseExists(in: app)
        XCTAssertTrue(waitForOverlayToDisappear(in: app, timeout: 10))
        XCTAssertTrue(app.staticTexts["seekModeLabel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["liveEdgeLabel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["jumpToLiveButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["quickCopyTextButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["quickCopyFrameButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["quickSaveFrameButton"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.otherElements["videoSurface"].waitForExistence(timeout: 5))
        assertSidebarToggleResizesVideo(in: app)
        assertControlsBarNotClipped(in: app)
        assertJumpToLiveBehavior(in: app)

        let smartPause = app.buttons["smartPauseButton"]
        XCTAssertTrue(smartPause.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForSmartPauseReadiness(in: app, timeout: 8), "Expected Smart Pause readiness before trigger")
        assertSmartPauseWorks(
            in: app,
            expectTimelineMarker: false,
            scenarioName: "RTSP live stream"
        )
    }

    func testOptionalConnectFileViaPasteStreamURLAndTimeProgress() throws {
        guard let fileURL = configuredFileURL() else {
            throw XCTSkip("SHARPSTREAM_TEST_VIDEO_FILE not set or missing; skipping file smoke path")
        }

        let app = makeApp()
        launchApp(app)
        pasteAndConnect(stream: fileURL, app: app)

        let noStreamText = app.staticTexts["No Stream Connected"]
        let connectedPredicate = NSPredicate(format: "exists == false")
        expectation(for: connectedPredicate, evaluatedWith: noStreamText)
        waitForExpectations(timeout: 12)

        let playPause = assertPlayPauseExists(in: app)
        let overlayCleared = waitForOverlayToDisappear(in: app, timeout: 8)
        if !overlayCleared {
            XCTContext.runActivity(named: "Connection overlay persisted; continuing with playback readiness checks") { _ in }
        }
        XCTAssertTrue(app.buttons["quickCopyTextButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["quickCopyFrameButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["quickSaveFrameButton"].waitForExistence(timeout: 5))

        // Confirm playback is actually moving in file mode.
        var advancedWithoutToggle = waitForCurrentTimeToAdvance(in: app, timeout: 4)
        var toggleAttempts = 0
        while !advancedWithoutToggle && toggleAttempts < 3 {
            playPause.tap()
            toggleAttempts += 1
            advancedWithoutToggle = waitForCurrentTimeToAdvance(in: app, timeout: 4)
        }
        XCTAssertTrue(
            advancedWithoutToggle || waitForCurrentTimeToAdvance(in: app, timeout: 10),
            "Expected current time label to advance for file playback"
        )

        let smartPause = app.buttons["smartPauseButton"]
        XCTAssertTrue(smartPause.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForSmartPauseReadiness(in: app, timeout: 8), "Expected Smart Pause readiness before trigger")
        assertSmartPauseWorks(
            in: app,
            expectTimelineMarker: true,
            scenarioName: "File playback"
        )
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHARPSTREAM_DISABLE_BLOCKING_ALERTS"] = "1"
        app.launchEnvironment["SHARPSTREAM_ENABLE_SMART_PAUSE_DIAGNOSTICS"] = "1"
        app.launchEnvironment["SHARPSTREAM_UI_TESTING"] = "1"
        return app
    }

    private func launchApp(_ app: XCUIApplication) {
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 5) {
            attachAccessibilityDump(in: app, title: "Main window missing after launch")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func pasteAndConnect(stream: String, app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stream, forType: .string)

        let pasteButton = app.buttons.matching(identifier: "pasteStreamToolbarButton").firstMatch
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        pasteButton.tap()
    }

    private func assertJumpToLiveBehavior(in app: XCUIApplication) {
        let playPause = assertPlayPauseExists(in: app)
        let jumpToLive = app.buttons["jumpToLiveButton"]
        XCTAssertTrue(jumpToLive.waitForExistence(timeout: 5))

        playPause.tap()

        let liveEdgeLabel = app.staticTexts["liveEdgeLabel"]
        if liveEdgeLabel.waitForExistence(timeout: 2) {
            let initialTime = readableTimeText(from: liveEdgeLabel)
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
            let updatedTime = readableTimeText(from: liveEdgeLabel)
            XCTAssertNotEqual(initialTime, updatedTime, "Live edge label should advance while paused")
        }

        let enableDeadline = Date().addingTimeInterval(6)
        while Date() < enableDeadline && !jumpToLive.isEnabled {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(jumpToLive.isEnabled, "Jump to Live should enable after pausing to build lag")

        jumpToLive.tap()
        let disableDeadline = Date().addingTimeInterval(6)
        while Date() < disableDeadline && jumpToLive.isEnabled {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(jumpToLive.isEnabled, "Jump to Live should disable after returning to live edge")

        playPause.tap()
    }

    private func assertSidebarToggleResizesVideo(in app: XCUIApplication) {
        let videoSurface = app.otherElements["videoSurface"]
        XCTAssertTrue(videoSurface.waitForExistence(timeout: 5))
        let initialFrame = videoSurface.frame

        toggleSidebar(in: app)
        let expandedFrame = videoSurface.frame

        toggleSidebar(in: app)
        let restoredFrame = videoSurface.frame

        XCTAssertGreaterThan(
            abs(expandedFrame.width - initialFrame.width),
            20,
            "Expected video surface width to change when toggling sidebar"
        )
        XCTAssertLessThan(
            abs(restoredFrame.width - initialFrame.width),
            10,
            "Expected video surface width to restore after toggling sidebar twice"
        )
    }

    private func assertControlsBarNotClipped(in app: XCUIApplication) {
        let controls = app.otherElements["controlsContainer"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let controlsFrame = controls.frame
        let windowFrame = window.frame

        XCTAssertGreaterThanOrEqual(
            controlsFrame.minY + 1,
            windowFrame.minY,
            "Controls bar appears clipped at the bottom"
        )
        XCTAssertLessThanOrEqual(
            controlsFrame.maxY - 1,
            windowFrame.maxY,
            "Controls bar appears clipped at the top"
        )

        XCTAssertTrue(playPauseButton(in: app).isHittable)
        XCTAssertTrue(app.buttons["quickSaveFrameButton"].isHittable)
    }

    private func playPauseButton(in app: XCUIApplication) -> XCUIElement {
        let controls = app.otherElements["controlsContainer"]
        if controls.waitForExistence(timeout: 2) {
            let button = controls.buttons["playPauseButton"]
            if button.exists {
                return button
            }
        }
        return app.buttons["playPauseButton"]
    }

    @discardableResult
    private func assertPlayPauseExists(in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
        let button = playPauseButton(in: app)
        if !button.waitForExistence(timeout: timeout) {
            attachAccessibilityDump(in: app, title: "Missing playPauseButton")
            XCTFail("Expected playPauseButton to exist")
        }
        return button
    }

    private func attachAccessibilityDump(in app: XCUIApplication, title: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let screenshotAttachment = XCTAttachment(screenshot: screenshot)
        screenshotAttachment.name = title
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        let dump = app.debugDescription
        print("=== \(title) accessibility dump start ===")
        print(dump)
        print("=== \(title) accessibility dump end ===")
        let playPauseMatches = app.descendants(matching: .any).matching(identifier: "playPauseButton")
        print("=== \(title) playPauseButton matches: \(playPauseMatches.count) ===")
        let dumpAttachment = XCTAttachment(string: dump)
        dumpAttachment.name = "\(title) accessibility dump"
        dumpAttachment.lifetime = .keepAlways
        add(dumpAttachment)
    }

    private func toggleSidebar(in app: XCUIApplication) {
        let toggleButton = app.buttons["toggleSidebarToolbarButton"]
        if toggleButton.exists {
            toggleButton.tap()
        } else {
            app.typeKey("s", modifierFlags: [.command, .control])
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func configuredRTSPURL() -> String? {
        var env = ProcessInfo.processInfo.environment
        if env["SHARPSTREAM_TEST_RTSP_URL"] == nil {
            env.merge(loadSmokeEnvFile(), uniquingKeysWith: { current, _ in current })
        }
        guard let rtsp = env["SHARPSTREAM_TEST_RTSP_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rtsp.isEmpty else {
            return nil
        }
        return rtsp
    }

    private func configuredFileURL() -> String? {
        var env = ProcessInfo.processInfo.environment
        if env["SHARPSTREAM_TEST_VIDEO_FILE"] == nil {
            env.merge(loadSmokeEnvFile(), uniquingKeysWith: { current, _ in current })
        }

        if let filePath = env["SHARPSTREAM_TEST_VIDEO_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filePath.isEmpty,
           FileManager.default.fileExists(atPath: filePath) {
            return URL(fileURLWithPath: filePath).absoluteString
        }

        return nil
    }

    private func waitForOverlayToDisappear(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.staticTexts["connectionOverlayText"].exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !app.staticTexts["connectionOverlayText"].exists
    }

    private func waitForCurrentTimeToAdvance(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let timeLabel = app.staticTexts["currentTimeLabel"]
        let liveEdgeLabel = app.staticTexts["liveEdgeLabel"]
        let activeLabel = timeLabel.waitForExistence(timeout: 2) ? timeLabel : liveEdgeLabel
        guard activeLabel.waitForExistence(timeout: 5) else { return false }

        let start = readableTimeText(from: activeLabel)
        let startSeconds = parseTimeLabel(start)
        let endTime = Date().addingTimeInterval(timeout)
        while Date() < endTime {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let current = readableTimeText(from: activeLabel)
            let currentSeconds = parseTimeLabel(current)
            if current != start && currentSeconds > startSeconds {
                return true
            }
        }
        return false
    }

    private func waitForSmartPauseReadiness(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if waitForCurrentTimeToAdvance(in: app, timeout: min(timeout, 5)) {
            return true
        }

        let timeLabel = app.staticTexts["currentTimeLabel"]
        let liveEdgeLabel = app.staticTexts["liveEdgeLabel"]
        let activeLabel = timeLabel.waitForExistence(timeout: 2) ? timeLabel : liveEdgeLabel
        guard activeLabel.waitForExistence(timeout: 2) else { return false }

        let baselineSeconds = parseTimeLabel(readableTimeText(from: activeLabel))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if parseTimeLabel(readableTimeText(from: activeLabel)) > baselineSeconds {
                return true
            }
        }
        return false
    }

    private enum SmartPauseOutcome {
        case success
        case failure(String)
        case timeout(String?)
    }

    private func assertSmartPauseWorks(
        in app: XCUIApplication,
        expectTimelineMarker: Bool,
        scenarioName: String,
        attempts: Int = 2
    ) {
        let smartPause = app.buttons["smartPauseButton"]
        XCTAssertTrue(smartPause.waitForExistence(timeout: 5), "Smart Pause button missing for \(scenarioName)")

        for attempt in 1...attempts {
            smartPause.tap()
            let outcome = waitForSmartPauseOutcome(in: app, expectTimelineMarker: expectTimelineMarker)

            switch outcome {
            case .success:
                return
            case .failure(let message):
                attachSmartPauseTrace(
                    in: app,
                    title: "Smart Pause failure (\(scenarioName), attempt \(attempt))",
                    statusMessage: message
                )
                if attempt < attempts {
                    _ = waitForCurrentTimeToAdvance(in: app, timeout: 3)
                    continue
                }
                XCTFail("Smart Pause failed for \(scenarioName): \(message)")
            case .timeout(let statusMessage):
                attachSmartPauseTrace(
                    in: app,
                    title: "Smart Pause timeout (\(scenarioName), attempt \(attempt))",
                    statusMessage: statusMessage
                )
                if attempt < attempts {
                    _ = waitForCurrentTimeToAdvance(in: app, timeout: 3)
                    continue
                }
                XCTFail("Smart Pause timed out for \(scenarioName). Last status: \(statusMessage ?? "<none>")")
            }
        }
    }

    private func waitForSmartPauseOutcome(in app: XCUIApplication, expectTimelineMarker: Bool) -> SmartPauseOutcome {
        let statusMessage = app.staticTexts["controlStatusMessage"]
        let liveBadge = app.staticTexts["smartPauseLiveBadge"]
        let markerStatus = app.staticTexts["smartPauseMarkerStatus"]
        let endTime = Date().addingTimeInterval(6)
        var lastStatusText: String?
        var sawSelectedStatus = false
        var sawExpectedIndicator = false
        let failureMarkers = [
            "found no recent frames",
            "stale",
            "seek is disabled",
            "seek was rejected",
            "pixel data is unavailable"
        ]

        while Date() < endTime {
            if statusMessage.exists {
                let statusText = elementText(statusMessage)
                lastStatusText = statusText

                if statusText.contains("Selected frame:") {
                    sawSelectedStatus = true
                }

                if failureMarkers.contains(where: { statusText.localizedCaseInsensitiveContains($0) }) {
                    return .failure(statusText)
                }
            }

            if expectTimelineMarker {
                if markerStatus.exists {
                    sawExpectedIndicator = true
                }
            } else if liveBadge.exists {
                sawExpectedIndicator = true
            }

            if sawSelectedStatus && sawExpectedIndicator {
                return .success
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return .timeout(lastStatusText)
    }

    private func attachSmartPauseTrace(in app: XCUIApplication, title: String, statusMessage: String?) {
        let screenshot = XCUIScreen.main.screenshot()
        let screenshotAttachment = XCTAttachment(screenshot: screenshot)
        screenshotAttachment.name = title
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        let currentTime = app.staticTexts["currentTimeLabel"]
        let seekMode = app.staticTexts["seekModeLabel"]
        let diagnostics = app.staticTexts["smartPauseDiagnosticsLabel"]
        let markerVisible = app.staticTexts["smartPauseMarkerStatus"].exists
        let liveBadgeVisible = app.staticTexts["smartPauseLiveBadge"].exists

        let trace = """
        Scenario: \(title)
        Status message: \(statusMessage ?? "<none>")
        Current time: \(currentTime.exists ? readableTimeText(from: currentTime) : "<missing>")
        Seek mode label: \(seekMode.exists ? elementText(seekMode) : "<missing>")
        Marker visible: \(markerVisible)
        Live badge visible: \(liveBadgeVisible)
        Diagnostics: \(diagnostics.exists ? elementText(diagnostics) : "<missing>")
        """

        let textAttachment = XCTAttachment(string: trace)
        textAttachment.name = "\(title) trace"
        textAttachment.lifetime = .keepAlways
        add(textAttachment)
    }

    private func elementText(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    private func readableTimeText(from element: XCUIElement) -> String {
        if let value = element.value as? String, parseTimeLabel(value) > 0 || value == "00:00" {
            return value
        }
        return element.label
    }

    private func parseTimeLabel(_ value: String) -> Int {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2:
            return (parts[0] * 60) + parts[1]
        case 3:
            return (parts[0] * 3600) + (parts[1] * 60) + parts[2]
        default:
            return 0
        }
    }

    private func loadSmokeEnvFile() -> [String: String] {
        let filePath = ProcessInfo.processInfo.environment["SHARPSTREAM_SMOKE_ENV_FILE"] ?? "/tmp/sharpstream_smoke.env"
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return [:]
        }

        var parsed: [String: String] = [:]
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            parsed[key] = value
        }
        return parsed
    }
}
