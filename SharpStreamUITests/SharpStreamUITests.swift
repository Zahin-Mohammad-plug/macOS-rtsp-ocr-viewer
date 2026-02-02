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
        app.launch()

        // Verify the main no-stream state is visible at startup.
        XCTAssertTrue(app.staticTexts["No Stream Connected"].waitForExistence(timeout: 5))
    }

    func testPasteStreamButtonExists() throws {
        let app = makeApp()
        app.launch()

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
        app.launch()
        pasteAndConnect(stream: rtspURL, app: app)

        // Wait for stream view state transition and connected controls.
        let noStreamText = app.staticTexts["No Stream Connected"]
        let connectedPredicate = NSPredicate(format: "exists == false")
        expectation(for: connectedPredicate, evaluatedWith: noStreamText)
        waitForExpectations(timeout: 12)

        let playPause = app.buttons["playPauseButton"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForOverlayToDisappear(in: app, timeout: 10))
        XCTAssertTrue(app.staticTexts["seekModeLabel"].waitForExistence(timeout: 5))
    }

    func testOptionalConnectFileViaPasteStreamURLAndTimeProgress() throws {
        guard let fileURL = configuredFileURL() else {
            throw XCTSkip("SHARPSTREAM_TEST_VIDEO_FILE not set or missing; skipping file smoke path")
        }

        let app = makeApp()
        app.launch()
        pasteAndConnect(stream: fileURL, app: app)

        let noStreamText = app.staticTexts["No Stream Connected"]
        let connectedPredicate = NSPredicate(format: "exists == false")
        expectation(for: connectedPredicate, evaluatedWith: noStreamText)
        waitForExpectations(timeout: 12)

        let playPause = app.buttons["playPauseButton"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForOverlayToDisappear(in: app, timeout: 8))

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
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHARPSTREAM_DISABLE_BLOCKING_ALERTS"] = "1"
        return app
    }

    private func pasteAndConnect(stream: String, app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stream, forType: .string)

        let pasteButton = app.buttons.matching(identifier: "pasteStreamToolbarButton").firstMatch
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        pasteButton.tap()
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
        let overlay = app.staticTexts["connectionOverlayText"]
        if !overlay.exists {
            return true
        }
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: overlay)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCurrentTimeToAdvance(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let timeLabel = app.staticTexts["currentTimeLabel"]
        guard timeLabel.waitForExistence(timeout: 5) else { return false }

        let start = readableTimeText(from: timeLabel)
        let startSeconds = parseTimeLabel(start)
        let endTime = Date().addingTimeInterval(timeout)
        while Date() < endTime {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let current = readableTimeText(from: timeLabel)
            let currentSeconds = parseTimeLabel(current)
            if current != start && currentSeconds > startSeconds {
                return true
            }
        }
        return false
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
