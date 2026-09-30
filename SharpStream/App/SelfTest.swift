//
//  SelfTest.swift
//  SharpStream
//
//  Debug-only end-to-end self test, driven by scripts/stream_matrix.sh.
//
//  With SHARPSTREAM_OPEN_URL and SHARPSTREAM_SELFTEST_REPORT set, the app
//  connects, exercises playback, seeking / live rewind, Smart Pause (while
//  playing and after sitting paused) and text recognition, writes a JSON
//  report to the given path (inside the app's sandbox container) and quits.
//

#if DEBUG
import AppKit

@MainActor
enum SelfTest {
    static var reportPath: String? {
        ProcessInfo.processInfo.environment["SHARPSTREAM_SELFTEST_REPORT"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func runIfRequested(_ app: AppState) {
        guard let path = reportPath else { return }
        Task { @MainActor in
            var report: [String: Any] = ["url": StreamURLRedactor.redacted(ProcessInfo.processInfo.environment["SHARPSTREAM_OPEN_URL"] ?? "")]
            var checks: [[String: Any]] = []
            func check(_ name: String, _ passed: Bool, _ detail: String = "") {
                checks.append(["name": name, "passed": passed, "detail": detail])
            }

            let manager = app.streamManager

            // 1. Connect
            let connected = await waitUntil(timeout: 25) { manager.connectionState == .connected }
            check("connects", connected, "\(manager.connectionState)")
            guard connected, let player = manager.player else {
                finish(report, checks, path)
                return
            }

            // 2. Plays and reports metadata
            await sleep(6)
            let stats = manager.streamStats
            report["seekMode"] = "\(manager.seekMode)"
            report["resolution"] = stats.resolution.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown"
            report["frameRate"] = stats.frameRate ?? 0
            report["codec"] = stats.codecName ?? "unknown"
            report["samplingFPS"] = app.focusScorer.getScoringFPS()
            report["captureLoad"] = player.capturePipelineLoad()
            let time0 = player.precisePlaybackTime
            await sleep(2)
            check("playback advances", player.precisePlaybackTime > time0 + 1,
                  String(format: "%.1f -> %.1f", time0, player.precisePlaybackTime))
            check("frames sampled for Smart Pause", app.focusScorer.getScoringFPS() > 1,
                  String(format: "%.1f fps", app.focusScorer.getScoringFPS()))

            // 3. Seeking / live rewind
            switch manager.seekMode {
            case .absolute:
                let target = min(30, max(1, player.duration / 3))
                app.seek(toTimelinePosition: target, exact: true)
                await sleep(1.5)
                check("absolute seek lands", abs(player.precisePlaybackTime - target) < 2,
                      String(format: "target %.1f got %.1f", target, player.precisePlaybackTime))
            case .liveBuffered:
                await sleep(6) // build some rewind buffer
                let window = manager.liveDVRState.windowSeconds
                report["rewindWindowSeconds"] = window
                check("live rewind window reported", window > 3, String(format: "%.1f s", window))
                app.seek(by: -5)
                await sleep(2)
                let lagAfterBack = manager.liveDVRState.lagSeconds
                check("rewind 5 s behind live", lagAfterBack > 3, String(format: "lag %.1f s", lagAfterBack))
                app.jumpToLive()
                await sleep(3)
                let lagAfterLive = manager.liveDVRState.lagSeconds
                check("jump to live", lagAfterLive < 2.5, String(format: "lag %.1f s", lagAfterLive))
            case .disabled:
                check("seekable", false, "seek mode disabled")
            }

            // 4. Smart Pause while playing (+ auto OCR)
            player.play()
            await sleep(4)
            app.smartPause()
            _ = await waitUntil(timeout: 20) { !app.isPerformingSmartPause && !app.isRecognizingText }
            let status1 = app.statusMessage?.text ?? ""
            let ok1 = app.smartPauseSelection != nil
            check("smart pause while playing", ok1, status1)
            report["ocrLines"] = app.analyzedFrame?.ocrResult?.lines.count ?? 0
            report["ocrSample"] = (app.analyzedFrame?.ocrResult?.lines.prefix(3).map(\.text) ?? []).joined(separator: " | ")
            check("paused on selection", !player.isPlaying)
            if let expected = ProcessInfo.processInfo.environment["SHARPSTREAM_SELFTEST_EXPECT_TEXT"], !expected.isEmpty {
                let text = app.analyzedFrame?.ocrResult?.text ?? ""
                check("OCR reads \"\(expected)\"", text.localizedCaseInsensitiveContains(expected),
                      text.replacingOccurrences(of: "\n", with: " | "))
            }

            // 5. Smart Pause after sitting paused longer than the look-back.
            // Pause at a blurry moment (latest frame well below the best recent
            // score), so the right answer is a frame from before the pause.
            app.dismissAnalysis()
            player.play()
            await sleep(3)
            var bestRecent = 0.0
            _ = await waitUntil(timeout: 8) {
                let current = app.focusScorer.getCurrentScore() ?? 0
                bestRecent = max(bestRecent, current)
                return bestRecent > 0 && current < bestRecent * 0.6
            }
            player.pause()
            await sleep(6)
            app.smartPause()
            _ = await waitUntil(timeout: 20) { !app.isPerformingSmartPause && !app.isRecognizingText }
            let status2 = app.statusMessage?.text ?? ""
            let age = app.smartPauseSelection?.frameAge ?? -1
            check("smart pause while already paused", app.smartPauseSelection != nil, status2)
            report["pausedSelectionAgeSeconds"] = age
            if let expected = ProcessInfo.processInfo.environment["SHARPSTREAM_SELFTEST_EXPECT_TEXT"], !expected.isEmpty {
                // Demo clip: paused mid-blur, so the pick must predate the pause
                // and still read the text.
                report["pausedAtBlurryFrame"] = true
                check("paused pick is from before the pause", age > 0.2, String(format: "%.1f s before pause", age))
                let text = app.analyzedFrame?.ocrResult?.text ?? ""
                check("OCR after paused pick reads \"\(expected)\"", text.localizedCaseInsensitiveContains(expected),
                      text.replacingOccurrences(of: "\n", with: " | "))
            }

            finish(report, checks, path)
        }
    }

    private static func finish(_ report: [String: Any], _ checks: [[String: Any]], _ path: String) {
        var report = report
        report["checks"] = checks
        report["passed"] = checks.allSatisfy { ($0["passed"] as? Bool) == true }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.25)
        }
        return condition()
    }

    private static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
#endif
