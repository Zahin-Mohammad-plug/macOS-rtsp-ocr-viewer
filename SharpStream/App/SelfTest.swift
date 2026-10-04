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
import CoreVideo

@MainActor
enum SelfTest {
    static var reportPath: String? {
        ProcessInfo.processInfo.environment["SHARPSTREAM_SELFTEST_REPORT"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func runIfRequested(_ app: AppState) {
        guard let path = reportPath else { return }
        switch ProcessInfo.processInfo.environment["SHARPSTREAM_SELFTEST_MODE"] ?? "standard" {
        case "soak": runSoak(app, path: path)
        case "switch": runSwitch(app, path: path)
        case "ocrsweep": runOCRSweep(app, path: path)
        case "latency": runLatency(app, path: path)
        default: runStandard(app, path: path)
        }
    }

    // MARK: - Latency: decode the clock bar code (scripts/latency) from frames

    /// Each frame of the latency clock carries the epoch ms at which it was
    /// drawn as a 40-cell bar code. now - stamp = end-to-end latency up to the
    /// decoded frame. Measured while playing, then again right after Jump to
    /// Live, to separate accumulated lag from the pipeline itself.
    private static func runLatency(_ app: AppState, path: String) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let seconds = Double(env["SHARPSTREAM_SELFTEST_SECONDS"] ?? "") ?? 20
            var report: [String: Any] = ["mode": "latency", "url": StreamURLRedactor.redacted(env["SHARPSTREAM_OPEN_URL"] ?? ""),
                                         "mpvOptions": env["SHARPSTREAM_MPV_OPTIONS"] ?? ""]
            var checks: [[String: Any]] = []
            let manager = app.streamManager
            let connected = await waitUntil(timeout: 25) { manager.connectionState == .connected }
            checks.append(["name": "connects", "passed": connected, "detail": "\(manager.connectionState)"])
            guard connected, let player = app.player else { finish(report, checks, path); return }
            await sleep(4)

            func measure(for duration: TimeInterval) async -> [String: Any] {
                var latencies: [Double] = [], ahead: [Double] = [], lags: [Double] = []
                let end = Date().addingTimeInterval(duration)
                while Date() < end {
                    if let frame = await player.captureFrame(), let stamp = decodeClock(frame) {
                        latencies.append(Date().timeIntervalSince1970 * 1000 - stamp)
                    }
                    let snapshot = player.getTransportMetricsSnapshot()
                    if let cached = snapshot.cacheDurationSeconds { ahead.append(cached) }
                    lags.append(manager.liveDVRState.lagSeconds)
                    await sleep(0.25)
                }
                func median(_ values: [Double]) -> Double {
                    values.isEmpty ? -1 : values.sorted()[values.count / 2]
                }
                return ["latencyMs": median(latencies), "latencyMinMs": latencies.min() ?? -1,
                        "latencyMaxMs": latencies.max() ?? -1, "decoded": latencies.count,
                        "cacheAheadS": median(ahead), "lagS": median(lags)]
            }

            let steady = await measure(for: seconds)
            report["steady"] = steady
            app.jumpToLive()
            await sleep(2)
            report["afterJumpToLive"] = await measure(for: min(10, seconds))
            checks.append(["name": "clock decoded", "passed": (steady["decoded"] as? Int ?? 0) > 5,
                           "detail": "\(steady["decoded"] ?? 0) frames"])
            finish(report, checks, path)
        }
    }

    /// Bar code: 40 cells x 16 px on row 324 of a 640x360 frame, MSB first.
    nonisolated private static func decodeClock(_ frame: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetWidth(frame) == 640, CVPixelBufferGetHeight(frame) == 360 else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = base + 324 * CVPixelBufferGetBytesPerRow(frame)
        var value: Int64 = 0
        for cell in 0..<40 {
            value = (value << 1) | (row[(cell * 16 + 8) * 4 + 1] < 128 ? 1 : 0)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var stamp = (now & ~((Int64(1) << 40) - 1)) | value
        if stamp > now + 1000 { stamp -= Int64(1) << 40 }
        let latency = now - stamp
        return latency >= 0 && latency < 60_000 ? Double(stamp) : nil
    }

    // MARK: - OCR sweep: Smart Pause vs. recognizing whatever is on screen

    /// Paired trials at random moments: OCR the frame on screen right now (what
    /// Recognize Text gets you), then Smart Pause and OCR its pick. With
    /// SHARPSTREAM_SELFTEST_EXPECT_TEXT it scores hits; otherwise it compares
    /// how many characters each read with confidence >= 0.5.
    private static func runOCRSweep(_ app: AppState, path: String) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let trials = Int(env["SHARPSTREAM_SELFTEST_TRIALS"] ?? "") ?? 12
            let expected = env["SHARPSTREAM_SELFTEST_EXPECT_TEXT"].flatMap { $0.isEmpty ? nil : $0 }
            var report: [String: Any] = ["mode": "ocrsweep", "url": StreamURLRedactor.redacted(env["SHARPSTREAM_OPEN_URL"] ?? ""),
                                         "trials": trials]
            var checks: [[String: Any]] = []
            let manager = app.streamManager
            let connected = await waitUntil(timeout: 25) { manager.connectionState == .connected }
            checks.append(["name": "connects", "passed": connected, "detail": "\(manager.connectionState)"])
            guard connected, let player = app.player else { finish(report, checks, path); return }
            report["samplingFPS"] = manager.smartPauseSamplingFPS

            func confidentChars(_ result: OCRResult?) -> Int {
                (result?.lines ?? []).filter { $0.confidence >= 0.5 }.reduce(0) { $0 + $1.text.count }
            }
            func hit(_ result: OCRResult?) -> Bool {
                guard let expected else { return false }
                return (result?.text ?? "").localizedCaseInsensitiveContains(expected)
            }

            var rows: [[String: Any]] = []
            await sleep(4)
            for _ in 0..<trials {
                player.play()
                await sleep(Double.random(in: 3.5...5.5))
                // Baseline: the frame on screen, recognized as-is.
                let baselineScore = app.focusScorer.getCurrentScore() ?? 0
                var baseline: OCRResult?
                if let frame = await player.captureFrame() {
                    baseline = await app.ocrEngine.recognizeText(in: frame)
                }
                // Smart Pause (auto OCR on its pick).
                app.smartPause()
                _ = await waitUntil(timeout: 25) { !app.isPerformingSmartPause && !app.isRecognizingText }
                let picked = app.analyzedFrame?.ocrResult
                rows.append([
                    "baselineHit": hit(baseline), "smartHit": hit(picked),
                    "baselineChars": confidentChars(baseline), "smartChars": confidentChars(picked),
                    "baselineScore": baselineScore, "smartScore": app.smartPauseSelection?.score ?? 0,
                    "smartAge": app.smartPauseSelection?.frameAge ?? -1
                ])
                app.dismissAnalysis()
                if manager.seekMode == .liveBuffered { app.jumpToLive() } else { player.play() }
                await sleep(1)
            }
            report["rows"] = rows

            let n = Double(max(1, rows.count))
            func mean(_ key: String) -> Double { rows.reduce(0) { $0 + (($1[key] as? Double) ?? Double($1[key] as? Int ?? 0)) } / n }
            func rate(_ key: String) -> Double { Double(rows.filter { $0[key] as? Bool == true }.count) / n }
            report["baselineChars"] = mean("baselineChars")
            report["smartChars"] = mean("smartChars")
            if expected != nil {
                let baselineRate = rate("baselineHit"), smartRate = rate("smartHit")
                report["baselineHitRate"] = baselineRate
                report["smartHitRate"] = smartRate
                checks.append(["name": "Smart Pause reads the text at least as often as plain OCR",
                               "passed": smartRate >= baselineRate,
                               "detail": String(format: "Smart Pause %.0f%%, plain %.0f%%", smartRate * 100, baselineRate * 100)])
            } else {
                checks.append(["name": "Smart Pause reads at least as much text as plain OCR",
                               "passed": mean("smartChars") >= mean("baselineChars") * 0.95,
                               "detail": String(format: "Smart Pause %.0f chars, plain %.0f chars", mean("smartChars"), mean("baselineChars"))])
            }
            finish(report, checks, path)
        }
    }

    // MARK: - Soak: long playback, watch for leaks and drift

    private static func runSoak(_ app: AppState, path: String) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let seconds = Double(env["SHARPSTREAM_SELFTEST_SECONDS"] ?? "") ?? 300
            var report: [String: Any] = ["mode": "soak", "url": StreamURLRedactor.redacted(env["SHARPSTREAM_OPEN_URL"] ?? ""),
                                         "seconds": seconds]
            var checks: [[String: Any]] = []
            let manager = app.streamManager
            let connected = await waitUntil(timeout: 25) { manager.connectionState == .connected }
            checks.append(["name": "connects", "passed": connected, "detail": "\(manager.connectionState)"])
            guard connected else { finish(report, checks, path); return }

            var samples: [[String: Any]] = []
            var smartPauses = 0, smartPauseOK = 0
            let start = Date()
            var nextSmartPause = start.addingTimeInterval(60)
            while Date().timeIntervalSince(start) < seconds {
                await sleep(15)
                if Date() >= nextSmartPause {
                    nextSmartPause = Date().addingTimeInterval(60)
                    smartPauses += 1
                    app.smartPause()
                    _ = await waitUntil(timeout: 20) { !app.isPerformingSmartPause && !app.isRecognizingText }
                    if app.smartPauseSelection != nil { smartPauseOK += 1 }
                    app.dismissAnalysis()
                    if manager.seekMode == .liveBuffered { app.jumpToLive() } else { app.player?.play() }
                    await sleep(2)
                }
                samples.append([
                    "t": Int(Date().timeIntervalSince(start)),
                    "footprintMB": ProcessMetrics.footprintMB(),
                    "threads": ProcessMetrics.threadCount(),
                    "captureLoad": app.player?.capturePipelineLoad() ?? 0,
                    "samplingFPS": app.focusScorer.getScoringFPS(),
                    "rewindSeconds": manager.liveDVRState.windowSeconds,
                    "bufferMB": Double(manager.liveStore.bufferBytes ?? 0) / 1_048_576,
                    "candidateMB": Double(app.focusScorer.retainedFrameBytes()) / 1_048_576,
                    "state": "\(manager.connectionState)"
                ])
            }
            report["samples"] = samples

            // Growth after warm-up (first minute excluded; buffer fill is expected
            // and reported separately, so compare footprint minus buffer).
            let settled = samples.filter { ($0["t"] as? Int ?? 0) >= 60 }
            func appMB(_ sample: [String: Any]) -> Double {
                (sample["footprintMB"] as? Double ?? 0) - (sample["bufferMB"] as? Double ?? 0)
            }
            if let first = settled.first, let last = settled.last {
                let growth = appMB(last) - appMB(first)
                checks.append(["name": "no memory growth beyond the rewind buffer", "passed": growth < 150,
                               "detail": String(format: "%+.0f MB over %d s (excluding buffer)", growth, (last["t"] as? Int ?? 0) - (first["t"] as? Int ?? 0))])
                let threadGrowth = (last["threads"] as? Int ?? 0) - (first["threads"] as? Int ?? 0)
                checks.append(["name": "thread count stable", "passed": threadGrowth <= 4, "detail": "\(threadGrowth >= 0 ? "+" : "")\(threadGrowth) threads"])
            }
            let stayedConnected = samples.allSatisfy { ($0["state"] as? String) == "connected" }
            checks.append(["name": "stayed connected", "passed": stayedConnected, "detail": ""])
            checks.append(["name": "smart pause each minute", "passed": smartPauses > 0 && smartPauseOK == smartPauses,
                           "detail": "\(smartPauseOK)/\(smartPauses)"])
            let maxCandidates = samples.map { $0["candidateMB"] as? Double ?? 0 }.max() ?? 0
            checks.append(["name": "Smart Pause frame memory bounded", "passed": maxCandidates < 200,
                           "detail": String(format: "max %.0f MB", maxCandidates)])
            finish(report, checks, path)
        }
    }

    // MARK: - Switch: rapid source changes

    private static func runSwitch(_ app: AppState, path: String) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let urls = (env["SHARPSTREAM_SELFTEST_URLS"] ?? "").split(separator: ",").map(String.init)
            var report: [String: Any] = ["mode": "switch", "sources": urls.map(StreamURLRedactor.redacted)]
            var checks: [[String: Any]] = []
            let manager = app.streamManager
            _ = await waitUntil(timeout: 25) { manager.connectionState == .connected }
            await sleep(3)
            let baseFootprint = ProcessMetrics.footprintMB()
            let baseThreads = ProcessMetrics.threadCount()

            // Fast switches (some before the previous stream finished loading).
            for round in 0..<12 {
                app.connect(urlString: urls[round % max(1, urls.count)])
                await sleep(round % 3 == 0 ? 0.4 : 2.5)
            }
            let last = urls[11 % max(1, urls.count)]
            let connected = await waitUntil(timeout: 25) {
                manager.connectionState == .connected && manager.currentStream?.url.hasSuffix(last.components(separatedBy: "/").last ?? "") == true
            }
            checks.append(["name": "ends connected to the last source", "passed": connected, "detail": "\(manager.connectionState)"])
            await sleep(8)
            let time0 = app.player?.precisePlaybackTime ?? 0
            await sleep(2)
            checks.append(["name": "last source plays", "passed": (app.player?.precisePlaybackTime ?? 0) > time0 + 1, "detail": ""])
            app.smartPause()
            _ = await waitUntil(timeout: 20) { !app.isPerformingSmartPause && !app.isRecognizingText }
            checks.append(["name": "smart pause after switching", "passed": app.smartPauseSelection != nil,
                           "detail": app.statusMessage?.text ?? ""])
            let threads = ProcessMetrics.threadCount()
            let footprint = ProcessMetrics.footprintMB()
            report["threads"] = ["before": baseThreads, "after": threads]
            report["footprintMB"] = ["before": baseFootprint, "after": footprint]
            checks.append(["name": "no leaked player threads", "passed": threads - baseThreads <= 8,
                           "detail": "\(baseThreads) -> \(threads) threads"])
            checks.append(["name": "no leaked player memory", "passed": footprint - baseFootprint < 250,
                           "detail": String(format: "%.0f -> %.0f MB", baseFootprint, footprint)])
            finish(report, checks, path)
        }
    }

    // MARK: - Standard

    private static func runStandard(_ app: AppState, path: String) {
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
enum ProcessMetrics {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}
#endif
