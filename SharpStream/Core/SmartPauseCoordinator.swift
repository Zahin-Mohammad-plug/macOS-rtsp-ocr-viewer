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
    func suspendFrameExtractionForSnapshot()
    func resumeFrameExtractionAfterSnapshot()
    func pause()
    @discardableResult func seek(to time: TimeInterval) -> Bool
    @discardableResult func seek(offset: TimeInterval) -> Bool
    func getCurrentFrame() -> CVPixelBuffer?
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
    let ocrPixelBuffer: CVPixelBuffer?

    var isSuccess: Bool {
        failureReason == nil
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
    private let bufferManager: BufferManager
    private let ocrEngine: OCREngine
    private let configuration: Configuration

    init(
        focusScorer: FocusScorer,
        bufferManager: BufferManager,
        ocrEngine: OCREngine,
        configuration: Configuration = Configuration()
    ) {
        self.focusScorer = focusScorer
        self.bufferManager = bufferManager
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

        player.suspendFrameExtractionForSnapshot()
        defer { player.resumeFrameExtractionAfterSnapshot() }

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
            for attempt in 1...configuration.maxOnDemandScoreAttempts {
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
                message: "Smart Pause found no recent frames in the lookback window. Play for 2-3s and retry.",
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
                message: "Smart Pause selected a frame, but seek is disabled.",
                diagnostics: diagnostics,
                selection: selection
            )
        }

        player.pause()

        let seekSucceeded: Bool
        switch request.seekMode {
        case .absolute:
            if let targetPlaybackTime = selection.playbackTime {
                seekSucceeded = player.seek(to: max(0, targetPlaybackTime))
            } else {
                let fallbackTime = max(0, (request.currentPlaybackTime ?? player.currentTime) - selection.frameAge)
                seekSucceeded = player.seek(to: fallbackTime)
            }
        case .liveBuffered:
            seekSucceeded = player.seek(offset: -selection.frameAge)
        case .disabled:
            seekSucceeded = false
        }

        diagnostics.seekSucceeded = seekSucceeded

        guard seekSucceeded else {
            return failure(
                reason: .seekRejected,
                message: "Smart Pause selected a frame but seek was rejected by the player.",
                diagnostics: diagnostics,
                selection: selection
            )
        }

        var ocrPixelBuffer: CVPixelBuffer?
        if request.autoOCREnabled, ocrEngine.isEnabled {
            if let selectedFrame = focusScorer.frame(sequenceNumber: selection.sequenceNumber),
               let pixelBuffer = selectedFrame.pixelBuffer {
                ocrPixelBuffer = pixelBuffer
            } else {
                return failure(
                    reason: .ocrFrameMissing,
                    message: "Smart Pause selected a frame but pixel data is unavailable for OCR.",
                    diagnostics: diagnostics,
                    selection: selection,
                    seekSucceeded: true
                )
            }
        }

        let statusMessage = String(
            format: "Selected frame: -%.1fs, score %.1f (seq %d)",
            selection.frameAge,
            selection.score,
            selection.sequenceNumber
        )

        diagnostics.failureReason = nil
        diagnostics.statusMessage = statusMessage

        return SmartPauseResult(
            selection: selection,
            statusMessage: statusMessage,
            diagnostics: diagnostics,
            failureReason: nil,
            ocrPixelBuffer: ocrPixelBuffer
        )
    }

    @MainActor
    private func scoreOnDemandCurrentFrame(player: SmartPausePlayer) async -> Bool {
        guard let pixelBuffer = player.getCurrentFrame() else {
            return false
        }

        let timestamp = Date()
        await bufferManager.addFrame(pixelBuffer, timestamp: timestamp)
        let sequenceNumber = await bufferManager.getCurrentSequenceNumber()
        let playbackTime = player.currentTime > 0 ? player.currentTime : nil
        _ = focusScorer.scoreFrame(
            pixelBuffer,
            timestamp: timestamp,
            playbackTime: playbackTime,
            sequenceNumber: sequenceNumber
        )
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
            ocrPixelBuffer: nil
        )
    }

    private static func defaultSleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
