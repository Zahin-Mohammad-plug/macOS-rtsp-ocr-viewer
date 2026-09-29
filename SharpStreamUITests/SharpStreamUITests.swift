//
//  SharpStreamUITests.swift
//  SharpStreamUITests
//
//  UI smoke tests. The app runs with SHARPSTREAM_UI_TESTING=1, which gives it
//  throwaway storage (library, recents, session-recovery) and suppresses the
//  "Resume previous stream?" prompt, so runs are independent of the user's
//  data and of each other.
//
//  Stream-dependent tests are opt-in and skip when no source is configured:
//    SHARPSTREAM_TEST_VIDEO_FILE  local video (must be readable by the sandboxed
//                                 app, e.g. ~/Movies/… or ~/Downloads/…)
//    SHARPSTREAM_TEST_RTSP_URL    live RTSP camera
//  Set them in the scheme, pass them as TEST_RUNNER_<NAME>=… to xcodebuild, or
//  put NAME=value lines in /tmp/sharpstream_smoke.env (SHARPSTREAM_SMOKE_ENV_FILE).
//

import XCTest
import AppKit

final class SharpStreamUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Always-on tests

    func testLaunchShowsEmptyStateWithoutResumePrompt() throws {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["noStreamLabel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pasteStreamToolbarButton"].firstMatch.exists)
        // Regression: a stale session file used to block launch with a modal.
        XCTAssertFalse(app.dialogs.firstMatch.waitForExistence(timeout: 1.5))
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testControlsAreDisabledWithoutStream() throws {
        let app = launchApp()

        XCTAssertTrue(app.buttons["smartPauseButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["smartPauseButton"].isEnabled)
        XCTAssertFalse(app.buttons["recognizeTextButton"].isEnabled)
    }

    /// Regression: Space/arrow keys were menu key equivalents and were stolen
    /// from every text field.
    func testTextFieldsReceiveSpacesInNewStreamSheet() throws {
        let app = launchApp()
        app.typeKey("n", modifierFlags: .command)

        let nameField = app.textFields["streamNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Front Gate Cam")

        XCTAssertEqual(nameField.value as? String, "Front Gate Cam")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - File playback (opt-in)

    func testFilePlaybackSmartPauseAndTextRecognition() throws {
        let fileURL = try XCTUnwrap(configuredFileURL(), "skip")
        let app = launchApp(openURL: fileURL)
        waitForConnection(in: app)

        XCTAssertTrue(waitForTimeToAdvance(app.staticTexts["currentTimeLabel"], timeout: 10),
                      "Playback time should advance for a file")
        assertControlsFitWindow(in: app)

        // Give the sampler a couple of seconds of frames, then Smart Pause.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.buttons["smartPauseButton"].click()

        let status = app.staticTexts["controlStatusMessage"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue((status.label).hasPrefix("Sharpest frame"), "Unexpected Smart Pause status: \(status.label)")
        XCTAssertTrue(app.buttons["playPauseButton"].label.lowercased().contains("play"), "Smart Pause should pause playback")

        // Text recognition runs after Smart Pause; the overlay header reports it.
        let regions = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'text region' OR label CONTAINS[c] 'No text found'")).firstMatch
        XCTAssertTrue(regions.waitForExistence(timeout: 20), "Expected OCR to finish on the Smart Pause frame")
    }

    // MARK: - Live RTSP (opt-in)

    func testLiveRTSPConnectsAndSmartPausesFromBuffer() throws {
        guard let rtspURL = configuredValue("SHARPSTREAM_TEST_RTSP_URL"), rtspURL.hasPrefix("rtsp://") else {
            throw XCTSkip("SHARPSTREAM_TEST_RTSP_URL not set")
        }
        let app = launchApp(openURL: rtspURL)
        waitForConnection(in: app, timeout: 20)

        XCTAssertTrue(app.staticTexts["liveEdgeLabel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["jumpToLiveButton"].exists)
        assertControlsFitWindow(in: app)

        RunLoop.current.run(until: Date().addingTimeInterval(4))
        app.buttons["smartPauseButton"].click()

        let status = app.staticTexts["controlStatusMessage"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Sharpest frame"), "Unexpected Smart Pause status: \(status.label)")

        // Paused behind live: Jump to Live must be available and return us.
        let jump = app.buttons["jumpToLiveButton"]
        XCTAssertTrue(waitUntil(timeout: 5) { jump.isEnabled }, "Jump to Live should enable while behind the edge")
        jump.click()
        XCTAssertTrue(waitUntil(timeout: 8) { app.staticTexts["liveEdgeLabel"].label == "LIVE" },
                      "Expected to return to the live edge")
    }

    // MARK: - Helpers

    @discardableResult
    private func launchApp(openURL: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            // Argument-domain defaults: override without touching the user's prefs.
            "-showOCRInspector", "NO"
        ]
        app.launchEnvironment["SHARPSTREAM_UI_TESTING"] = "1"
        app.launchEnvironment["SHARPSTREAM_DISABLE_BLOCKING_ALERTS"] = "1"
        if let openURL {
            app.launchEnvironment["SHARPSTREAM_OPEN_URL"] = openURL
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Main window did not appear")
        return app
    }

    private func waitForConnection(in app: XCUIApplication, timeout: TimeInterval = 15) {
        let noStream = app.staticTexts["noStreamLabel"]
        XCTAssertTrue(waitUntil(timeout: timeout) { !noStream.exists }, "Stream did not start")
        let overlay = app.staticTexts["connectionOverlayText"]
        XCTAssertTrue(waitUntil(timeout: timeout) { !overlay.exists },
                      "Connection overlay persisted: \(overlay.exists ? overlay.label : "")")
    }

    private func assertControlsFitWindow(in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for identifier in ["playPauseButton", "smartPauseButton", "recognizeTextButton", "exportMenuButton"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) missing")
            XCTAssertTrue(window.contains(element.frame), "\(identifier) is clipped outside the window")
            XCTAssertGreaterThan(element.frame.width, 16, "\(identifier) is squashed")
        }
    }

    private func waitForTimeToAdvance(_ label: XCUIElement, timeout: TimeInterval) -> Bool {
        guard label.waitForExistence(timeout: 5) else { return false }
        let start = label.label
        return waitUntil(timeout: timeout) { label.label != start }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func configuredFileURL() -> String? {
        let candidates: [String?] = [
            configuredValue("SHARPSTREAM_TEST_VIDEO_FILE"),
            // Default fixture location readable by the sandboxed app.
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.sharpstream.SharpStream/Data/tmp/test_ocr.mp4").path
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).absoluteString
        }
        return nil
    }

    private func configuredValue(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return loadSmokeEnvFile()[key]
    }

    private func loadSmokeEnvFile() -> [String: String] {
        let path = ProcessInfo.processInfo.environment["SHARPSTREAM_SMOKE_ENV_FILE"] ?? "/tmp/sharpstream_smoke.env"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var parsed: [String: String] = [:]
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { parsed[parts[0].trimmingCharacters(in: .whitespaces)] = value }
        }
        return parsed
    }
}
