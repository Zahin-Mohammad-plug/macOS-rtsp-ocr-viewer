//
//  SmartPauseCoordinator.swift
//  SharpStream
//
//  Deterministic Smart Pause orchestration with recovery + diagnostics.
//

import Foundation
import CoreVideo

protocol SmartPausePlayer: AnyObject {
    var currentTime: TimeInterval { get }
    func pause()
    @discardableResult func seek(to time: TimeInterval, exact: Bool) -> Bool
    @discardableResult func seek(offset: TimeInterval, exact: Bool) -> Bool
    /// Grab the currently decoded video frame (BGRA), off the main thread.
    func captureFrame() async -> CVPixelBuffer?
}

enum SmartPauseFailureReason: String, Equatable, Codable {
    case noRecentFrames
    case staleSelection
    case seekRejected
    case seekDisabled
    case ocrFrameMissing
}

struct SmartPauseRequest {
    let lookbackSeconds: TimeInterval
    let seekMode: SeekMode
    let currentPlaybackTime: TimeInterval?
    let autoOCREnabled: Bool
}

struct SmartPauseResult {
    let selection: SmartPauseSelection?
    let statusMessage: String
    let diagnostics: SmartPauseDiagnostics
    let failureReason: SmartPauseFailureReason?
    /// The selected frame's pixels (what the player is now paused on).
    let selectedPixelBuffer: CVPixelBuffer?
    /// True when the caller should run OCR on `selectedPixelBuffer`.
    let shouldRunOCR: Bool

    var isSuccess: Bool {
        failureReason == nil
    }

    /// Kept for callers that only care about the OCR input.
    var ocrPixelBuffer: CVPixelBuffer? {
        shouldRunOCR ? selectedPixelBuffer : nil
    }
}

final class SmartPauseCoordinator {
    struct Configuration {
        var maxOnDemandScoreAttempts: Int = 3
        var onDemandRetryDelay: TimeInterval = 0.15
        var warmupDelay: TimeInterval = 0.35
        var stalenessLookbackPadding: TimeInterval = 1.0
        var stalenessFloor: TimeInterval = 8.0
        var sleep: @Sendable (TimeInterval) async -> Void = SmartPauseCoordinator.defaultSleep
    }

    private let focusScorer: FocusScorer
    private let ocrEngine: OCREngine
    private let configuration: Configuration
    private var onDemandSequence = 1_000_000_000

    init(
        focusScorer: FocusScorer,
        ocrEngine: OCREngine,
        configuration: Configuration = Configuration()
    ) {
        self.focusScorer = focusScorer
        self.ocrEngine = ocrEngine
        self.configuration = configuration
    }

    @MainActor
    func perform(request: SmartPauseRequest, player: SmartPausePlayer) async -> SmartPauseResult {
        let lookbackSeconds = min(5.0, max(1.0, request.lookbackSeconds))
        let playbackTime = request.currentPlaybackTime ?? player.currentTime

        var diagnostics = SmartPauseDiagnostics(
            lookbackSeconds: lookbackSeconds,
            seekMode: request.seekMode
        )

        let initialNow = Date()
        diagnostics.recentFrameCountBeforeRecovery = focusScorer.recentFrameCount(
            in: lookbackSeconds,
            now: initialNow
        )

        var selection = focusScorer.selectBestFrame(
            in: lookbackSeconds,
            now: initialNow,
            currentPlaybackTime: playbackTime,
            seekMode: request.seekMode
        )

        if selection == nil {
            for attempt in 1...max(1, configuration.maxOnDemandScoreAttempts) {
                diagnostics.onDemandScoreAttempts = attempt

                if await scoreOnDemandCurrentFrame(player: player) {
                    selection = focusScorer.selectBestFrame(
                        in: lookbackSeconds,
                        now: Date(),
                        currentPlaybackTime: request.currentPlaybackTime ?? player.currentTime,
                        seekMode: request.seekMode
                    )
                }

                if selection != nil {
                    break
                }

                if attempt < configuration.maxOnDemandScoreAttempts {
                    await configuration.sleep(configuration.onDemandRetryDelay)
                }
            }
        }

        if selection == nil {
            diagnostics.warmupWaitApplied = true
            await configuration.sleep(configuration.warmupDelay)
            selection = focusScorer.selectBestFrame(
                in: lookbackSeconds,
                now: Date(),
                currentPlaybackTime: request.currentPlaybackTime ?? player.currentTime,
                seekMode: request.seekMode
            )
        }

        diagnostics.recentFrameCountAfterRecovery = focusScorer.recentFrameCount(
            in: lookbackSeconds,
            now: Date()
        )

        guard let selection else {
            return failure(
                reason: .noRecentFrames,
                message: "No frames captured yet — play for a couple of seconds and try again.",
                diagnostics: diagnostics
            )
        }

        diagnostics.selectedSequenceNumber = selection.sequenceNumber
        diagnostics.selectedScore = selection.score
        diagnostics.selectedFrameAge = selection.frameAge
        diagnostics.selectedPlaybackTime = selection.playbackTime

        let maxStaleness = max(lookbackSeconds + configuration.stalenessLookbackPadding, configuration.stalenessFloor)
        guard selection.frameAge <= maxStaleness else {
            return failure(
                reason: .staleSelection,
                message: "Best frame is stale; try again while playback is active.",
                diagnostics: diagnostics,
                selection: selection
            )
        }

        guard request.seekMode != .disabled else {
            return failure(
                reason: .seekDisabled,
                message: "Smart Pause picked a frame, but this source can't seek.",
                diagnostics: diagnostics,
                selection: selection
            )
        }

        player.pause()

        // Exact seeks so the paused picture is the frame that was scored.
        let seekSucceeded: Bool
        switch request.seekMode {
        case .absolute:
            let target = selection.playbackTime
                ?? max(0, (request.currentPlaybackTime ?? player.currentTime) - selection.frameAge)
            seekSucceeded = player.seek(to: max(0, target), exact: true)
        case .liveBuffered:
            if let target = focusScorer.frame(sequenceNumber: selection.sequenceNumber)?.playbackTime {
                // Stream timestamps are stable inside mpv's cache: seek straight to the frame.
                seekSucceeded = player.seek(to: max(0, target), exact: true)
            } else {
                seekSucceeded = player.seek(offset: -selection.frameAge, exact: true)
            }
        case .disabled:
            seekSucceeded = false
        }

        diagnostics.seekSucceeded = seekSucceeded

        guard seekSucceeded else {
            return failure(
                reason: .seekRejected,
                message: "Smart Pause picked a frame but the player rejected the seek.",
                diagnostics: diagnostics,
                selection: selection
            )
        }

        let selectedPixelBuffer = focusScorer.frame(sequenceNumber: selection.sequenceNumber)?.pixelBuffer
        let shouldRunOCR = request.autoOCREnabled && ocrEngine.isEnabled
        if shouldRunOCR, selectedPixelBuffer == nil {
            return failure(
                reason: .ocrFrameMissing,
                message: "Smart Pause picked a frame but its pixels are no longer available for OCR.",
                diagnostics: diagnostics,
                selection: selection,
                seekSucceeded: true
            )
        }

        let statusMessage = String(
            format: "Sharpest frame: %.1fs ago (score %.0f)",
            selection.frameAge,
            selection.score
        )

        diagnostics.failureReason = nil
        diagnostics.statusMessage = statusMessage

        return SmartPauseResult(
            selection: selection,
            statusMessage: statusMessage,
            diagnostics: diagnostics,
            failureReason: nil,
            selectedPixelBuffer: selectedPixelBuffer,
            shouldRunOCR: shouldRunOCR
        )
    }

    @MainActor
    private func scoreOnDemandCurrentFrame(player: SmartPausePlayer) async -> Bool {
        let playbackTime = player.currentTime > 0 ? player.currentTime : nil
        guard let pixelBuffer = await player.captureFrame() else {
            return false
        }

        onDemandSequence += 1
        let sequence = onDemandSequence
        let scorer = focusScorer
        await Task.detached(priority: .userInitiated) {
            _ = scorer.scoreFrame(
                pixelBuffer,
                timestamp: Date(),
                playbackTime: playbackTime,
                sequenceNumber: sequence
            )
        }.value
        return true
    }

    private func failure(
        reason: SmartPauseFailureReason,
        message: String,
        diagnostics: SmartPauseDiagnostics,
        selection: SmartPauseSelection? = nil,
        seekSucceeded: Bool? = nil
    ) -> SmartPauseResult {
        var failureDiagnostics = diagnostics
        failureDiagnostics.failureReason = reason
        failureDiagnostics.statusMessage = message
        failureDiagnostics.seekSucceeded = seekSucceeded ?? diagnostics.seekSucceeded
        if let selection {
            failureDiagnostics.selectedSequenceNumber = selection.sequenceNumber
            failureDiagnostics.selectedScore = selection.score
            failureDiagnostics.selectedFrameAge = selection.frameAge
            failureDiagnostics.selectedPlaybackTime = selection.playbackTime
        }
        return SmartPauseResult(
            selection: selection,
            statusMessage: message,
            diagnostics: failureDiagnostics,
            failureReason: reason,
            selectedPixelBuffer: nil,
            shouldRunOCR: false
        )
    }

    private static func defaultSleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
