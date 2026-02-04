//
//  SmartPauseCoordinatorTests.swift
//  SharpStreamTests
//
//  Deterministic tests for Smart Pause orchestration and recovery behavior.
//

import XCTest
import CoreVideo
@testable import SharpStream

@MainActor
final class SmartPauseCoordinatorTests: XCTestCase {
    func testFileModeSelectsAndSeeksAbsolute() async {
        let focusScorer = FocusScorer()
        let coordinator = makeCoordinator(focusScorer: focusScorer)
        let player = MockSmartPausePlayer(currentTime: 10.0)

        let now = Date()
        _ = focusScorer.scoreFrame(
            createSolidPixelBuffer(width: 320, height: 240, value: 120),
            timestamp: now.addingTimeInterval(-1.6),
            playbackTime: 8.4,
            sequenceNumber: 1
        )
        _ = focusScorer.scoreFrame(
            createCheckerboardPixelBuffer(width: 320, height: 240),
            timestamp: now.addingTimeInterval(-0.5),
            playbackTime: 9.5,
            sequenceNumber: 2
        )

        let result = await coordinator.perform(
            request: SmartPauseRequest(
                lookbackSeconds: 3.0,
                seekMode: .absolute,
                currentPlaybackTime: player.currentTime,
                autoOCREnabled: false
            ),
            player: player
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.selection?.sequenceNumber, 2)
        XCTAssertEqual(player.seekToCalls.count, 1)
        XCTAssertEqual(player.seekOffsetCalls.count, 0)
        XCTAssertEqual(player.pauseCalls, 1)
    }

    func testLiveModeSelectsAndSeeksRelative() async {
        let focusScorer = FocusScorer()
        let coordinator = makeCoordinator(focusScorer: focusScorer)
        let player = MockSmartPausePlayer(currentTime: 20.0)

        let now = Date()
        _ = focusScorer.scoreFrame(
            createCheckerboardPixelBuffer(width: 320, height: 240),
            timestamp: now.addingTimeInterval(-0.7),
            playbackTime: nil,
            sequenceNumber: 4
        )

        let result = await coordinator.perform(
            request: SmartPauseRequest(
                lookbackSeconds: 3.0,
                seekMode: .liveBuffered,
                currentPlaybackTime: player.currentTime,
                autoOCREnabled: false
            ),
            player: player
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(player.seekToCalls.count, 0)
        XCTAssertEqual(player.seekOffsetCalls.count, 1)
        XCTAssertLessThan(player.seekOffsetCalls[0], 0)
        XCTAssertEqual(player.pauseCalls, 1)
    }

    func testAutoRecoveryScoresOnDemandWhenHistoryEmpty() async {
        let focusScorer = FocusScorer()
        let coordinator = makeCoordinator(focusScorer: focusScorer, maxAttempts: 3)
        let player = MockSmartPausePlayer(currentTime: 15.0)
        player.frames = [createCheckerboardPixelBuffer(width: 320, height: 240)]

        let result = await coordinator.perform(
            request: SmartPauseRequest(
                lookbackSeconds: 3.0,
                seekMode: .absolute,
                currentPlaybackTime: player.currentTime,
                autoOCREnabled: false
            ),
            player: player
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertGreaterThanOrEqual(result.diagnostics.onDemandScoreAttempts, 1)
        XCTAssertGreaterThan(result.diagnostics.recentFrameCountAfterRecovery, 0)
        XCTAssertEqual(player.pauseCalls, 1)
        XCTAssertEqual(player.seekToCalls.count, 1)
    }

    func testFailsWithNoRecentFramesAfterRetries() async {
        let focusScorer = FocusScorer()
        let coordinator = makeCoordinator(focusScorer: focusScorer, maxAttempts: 2)
        let player = MockSmartPausePlayer(currentTime: 15.0)

        let result = await coordinator.perform(
            request: SmartPauseRequest(
                lookbackSeconds: 3.0,
                seekMode: .absolute,
                currentPlaybackTime: player.currentTime,
                autoOCREnabled: false
            ),
            player: player
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureReason, .noRecentFrames)
        XCTAssertEqual(result.diagnostics.onDemandScoreAttempts, 2)
        XCTAssertEqual(player.pauseCalls, 0)
    }

    func testRejectsStaleSelection() async {
        let focusScorer = FocusScorer()
        let coordinator = makeCoordinator(
            focusScorer: focusScorer,
            maxAttempts: 1,
            stalenessLookbackPadding: -4.0,
            stalenessFloor: 0.3
        )
        let player = MockSmartPausePlayer(currentTime: 42.0)

        let now = Date()
        _ = focusScorer.scoreFrame(
            createCheckerboardPixelBuffer(width: 320, height: 240),
            timestamp: now.addingTimeInterval(-1.0),
            playbackTime: 41.0,
            sequenceNumber: 11
        )

        let result = await coordinator.perform(
            request: SmartPauseRequest(
                lookbackSeconds: 3.0,
                seekMode: .absolute,
                currentPlaybackTime: player.currentTime,
                autoOCREnabled: false
            ),
            player: player
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureReason, .staleSelection)
        XCTAssertEqual(player.pauseCalls, 0)
    }

    func testSeekRejectedReturnsFailureReason() async {
        let focusScorer = FocusScorer()
        let coordinator = makeCoordinator(focusScorer: focusScorer)
        let player = MockSmartPausePlayer(currentTime: 30.0)
        player.seekToResult = false

        let now = Date()
        _ = focusScorer.scoreFrame(
            createCheckerboardPixelBuffer(width: 320, height: 240),
            timestamp: now.addingTimeInterval(-0.4),
            playbackTime: 29.6,
            sequenceNumber: 20
        )

        let result = await coordinator.perform(
            request: SmartPauseRequest(
                lookbackSeconds: 3.0,
                seekMode: .absolute,
                currentPlaybackTime: player.currentTime,
                autoOCREnabled: false
            ),
            player: player
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureReason, .seekRejected)
        XCTAssertEqual(player.pauseCalls, 1)
        XCTAssertEqual(player.seekToCalls.count, 1)
    }

    private func makeCoordinator(
        focusScorer: FocusScorer,
        maxAttempts: Int = 3,
        stalenessLookbackPadding: TimeInterval = 1.0,
        stalenessFloor: TimeInterval = 8.0
    ) -> SmartPauseCoordinator {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-pause-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        let diskPath = tempRoot.appendingPathComponent("disk", isDirectory: true)
        let indexPath = tempRoot.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let bufferManager = BufferManager(diskBufferPath: diskPath, bufferIndexPath: indexPath)
        let ocrEngine = OCREngine()
        let configuration = SmartPauseCoordinator.Configuration(
            maxOnDemandScoreAttempts: maxAttempts,
            onDemandRetryDelay: 0,
            warmupDelay: 0,
            stalenessLookbackPadding: stalenessLookbackPadding,
            stalenessFloor: stalenessFloor,
            sleep: { _ in }
        )
        return SmartPauseCoordinator(
            focusScorer: focusScorer,
            bufferManager: bufferManager,
            ocrEngine: ocrEngine,
            configuration: configuration
        )
    }

    private func createSolidPixelBuffer(width: Int, height: Int, value: UInt8) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
             kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = pixelBuffer!

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                data?[offset] = value
                data?[offset + 1] = value
                data?[offset + 2] = value
                data?[offset + 3] = 255
            }
        }
        return buffer
    }

    private func createCheckerboardPixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        let buffer = createSolidPixelBuffer(width: width, height: height, value: 0)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
        let blockSize = 8
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let isBright = ((x / blockSize) + (y / blockSize)) % 2 == 0
                let value: UInt8 = isBright ? 240 : 15
                data?[offset] = value
                data?[offset + 1] = value
                data?[offset + 2] = value
                data?[offset + 3] = 255
            }
        }
        return buffer
    }
}

private final class MockSmartPausePlayer: SmartPausePlayer {
    var currentTime: TimeInterval
    var frames: [CVPixelBuffer] = []
    var seekToResult = true
    var seekOffsetResult = true

    private(set) var suspendCalls = 0
    private(set) var resumeCalls = 0
    private(set) var pauseCalls = 0
    private(set) var seekToCalls: [TimeInterval] = []
    private(set) var seekOffsetCalls: [TimeInterval] = []

    init(currentTime: TimeInterval) {
        self.currentTime = currentTime
    }

    func suspendFrameExtractionForSnapshot() {
        suspendCalls += 1
    }

    func resumeFrameExtractionAfterSnapshot() {
        resumeCalls += 1
    }

    func pause() {
        pauseCalls += 1
    }

    func seek(to time: TimeInterval) -> Bool {
        seekToCalls.append(time)
        return seekToResult
    }

    func seek(offset: TimeInterval) -> Bool {
        seekOffsetCalls.append(offset)
        return seekOffsetResult
    }

    func getCurrentFrame() -> CVPixelBuffer? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }
}
