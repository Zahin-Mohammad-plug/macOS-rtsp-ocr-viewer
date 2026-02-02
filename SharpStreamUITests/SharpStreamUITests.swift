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
        let app = XCUIApplication()
        app.launch()

        // Verify the main no-stream state is visible at startup.
        XCTAssertTrue(app.staticTexts["No Stream Connected"].waitForExistence(timeout: 5))
    }

    func testPasteStreamButtonExists() throws {
        let app = XCUIApplication()
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

    func testOptionalConnectViaPasteStreamURL() throws {
        guard let config = configuredStream() else {
            throw XCTSkip("No stream config set (SHARPSTREAM_TEST_RTSP_URL or SHARPSTREAM_TEST_VIDEO_FILE)")
        }

        let app = XCUIApplication()
        app.launch()
        pasteAndConnect(stream: config.url, app: app)

        // Wait for stream view state transition.
        let noStreamText = app.staticTexts["No Stream Connected"]
        let connectedPredicate = NSPredicate(format: "exists == false")
        expectation(for: connectedPredicate, evaluatedWith: noStreamText)
        waitForExpectations(timeout: 8)

        // Playback control smoke checks.
        let playPause = app.buttons["playPauseButton"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.tap()

        let smartPause = app.buttons["smartPauseButton"]
        XCTAssertTrue(smartPause.waitForExistence(timeout: 5))
        smartPause.tap()

        if config.isFileSource {
            let timeline = app.sliders["timelineSlider"]
            if timeline.waitForExistence(timeout: 5) {
                timeline.adjust(toNormalizedSliderPosition: 0.5)
            }
        }
    }

    private func pasteAndConnect(stream: String, app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stream, forType: .string)

        let pasteButton = app.buttons.matching(identifier: "pasteStreamToolbarButton").firstMatch
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        pasteButton.tap()
        _ = app.staticTexts["Connecting..."].waitForExistence(timeout: 3)
    }

    private func configuredStream() -> (url: String, isFileSource: Bool)? {
        var env = ProcessInfo.processInfo.environment
        if env["SHARPSTREAM_TEST_RTSP_URL"] == nil && env["SHARPSTREAM_TEST_VIDEO_FILE"] == nil {
            env.merge(loadSmokeEnvFile(), uniquingKeysWith: { current, _ in current })
        }

        if let filePath = env["SHARPSTREAM_TEST_VIDEO_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filePath.isEmpty,
           FileManager.default.fileExists(atPath: filePath) {
            return ("file://\(filePath)", true)
        }

        if let rtsp = env["SHARPSTREAM_TEST_RTSP_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rtsp.isEmpty {
            return (rtsp, false)
        }

        return nil
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
