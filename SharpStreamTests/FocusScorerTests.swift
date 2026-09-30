//
//  FocusScorerTests.swift
//  SharpStreamTests
//
//  Unit tests for focus scoring algorithms
//

import XCTest
import CoreVideo
@testable import SharpStream

final class FocusScorerTests: XCTestCase {
    var focusScorer: FocusScorer!
    
    override func setUp() {
        super.setUp()
        focusScorer = FocusScorer()
    }
    
    override func tearDown() {
        focusScorer = nil
        super.tearDown()
    }
    
    func testLaplacianAlgorithm() {
        focusScorer.setAlgorithm(.laplacian)
        XCTAssertEqual(focusScorer.algorithm, .laplacian)
        
        let pixelBuffer = createTestPixelBuffer(width: 640, height: 480)
        let score = focusScorer.scoreFrame(pixelBuffer, timestamp: Date(), sequenceNumber: 1)
        
        XCTAssertGreaterThan(score.score, 0, "Laplacian score should be positive")
    }
    
    func testTenengradAlgorithm() {
        focusScorer.setAlgorithm(.tenengrad)
        XCTAssertEqual(focusScorer.algorithm, .tenengrad)
        
        let pixelBuffer = createTestPixelBuffer(width: 640, height: 480)
        let score = focusScorer.scoreFrame(pixelBuffer, timestamp: Date(), sequenceNumber: 1)
        
        XCTAssertGreaterThan(score.score, 0, "Tenengrad score should be positive")
    }
    
    func testSobelAlgorithm() {
        focusScorer.setAlgorithm(.sobel)
        XCTAssertEqual(focusScorer.algorithm, .sobel)
        
        let pixelBuffer = createTestPixelBuffer(width: 640, height: 480)
        let score = focusScorer.scoreFrame(pixelBuffer, timestamp: Date(), sequenceNumber: 1)
        
        XCTAssertGreaterThan(score.score, 0, "Sobel score should be positive")
    }
    
    func testRetainsOnlyFramesThatCanStillWin() {
        // Regression: the scorer used to keep 1000 full-resolution frames.
        let now = Date()
        let sharp = createCheckerboardPixelBuffer(width: 320, height: 240)
        let soft = createSolidPixelBuffer(width: 320, height: 240, value: 120)

        // 40 soft frames followed by one sharp frame: every soft frame is
        // beaten by a newer, sharper frame and must be released.
        for index in 0..<40 {
            focusScorer.scoreFrame(soft, timestamp: now.addingTimeInterval(-5 + Double(index) * 0.1), sequenceNumber: index)
        }
        focusScorer.scoreFrame(sharp, timestamp: now, sequenceNumber: 100)

        XCTAssertEqual(focusScorer.frame(sequenceNumber: 100)?.sequenceNumber, 100)
        XCTAssertNil(focusScorer.frame(sequenceNumber: 10))
        XCTAssertEqual(focusScorer.retainedFrameBytes(), CVPixelBufferGetDataSize(sharp))
        XCTAssertEqual(focusScorer.recentFrameCount(in: 10, now: now), 41, "Samples are still counted for stats")
    }

    func testCandidateCountIsCappedWhenSharpnessKeepsFalling() {
        // Focus drifting out at a high sampling rate: every frame is softer
        // than the one before, so each could still win some window. The store
        // must stay capped and keep the sharpest (oldest) and newest frames.
        let now = Date()
        focusScorer.maxCandidates = 8
        for index in 0..<30 {
            let frame = createCheckerboardPixelBuffer(width: 64, height: 48, contrast: UInt8(120 - index * 3))
            focusScorer.scoreFrame(frame, timestamp: now.addingTimeInterval(-3 + Double(index) * 0.1), sequenceNumber: index)
        }
        XCTAssertEqual(focusScorer.retainedFrameBytes(), 8 * CVPixelBufferGetDataSize(createTestPixelBuffer(width: 64, height: 48)))
        XCTAssertNotNil(focusScorer.frame(sequenceNumber: 0), "sharpest frame kept")
        XCTAssertNotNil(focusScorer.frame(sequenceNumber: 29), "newest frame kept")
        XCTAssertEqual(focusScorer.findBestFrame(in: 5, now: now)?.sequenceNumber, 0)
    }

    func testDropsCandidatesOutsideRetentionWindow() {
        let now = Date()
        let sharp = createCheckerboardPixelBuffer(width: 320, height: 240)
        let soft = createSolidPixelBuffer(width: 320, height: 240, value: 120)
        focusScorer.scoreFrame(sharp, timestamp: now.addingTimeInterval(-30), sequenceNumber: 1)
        focusScorer.scoreFrame(soft, timestamp: now, sequenceNumber: 2)

        XCTAssertNil(focusScorer.frame(sequenceNumber: 1))
        XCTAssertEqual(focusScorer.findBestFrame(in: 5, now: now)?.sequenceNumber, 2)
    }

    func testMetricsRankSharpAboveSoft() {
        let sharp = createCheckerboardPixelBuffer(width: 1920, height: 1080)
        let soft = createSolidPixelBuffer(width: 1920, height: 1080, value: 120)
        for algorithm in FocusAlgorithm.allCases {
            XCTAssertGreaterThan(
                SharpnessMetrics.score(sharp, algorithm: algorithm),
                SharpnessMetrics.score(soft, algorithm: algorithm),
                "\(algorithm) should rank the detailed frame higher"
            )
        }
    }

    func testFindBestFrame() {
        let pixelBuffer1 = createTestPixelBuffer(width: 640, height: 480)
        let pixelBuffer2 = createTestPixelBuffer(width: 640, height: 480)
        
        _ = focusScorer.scoreFrame(pixelBuffer1, timestamp: Date().addingTimeInterval(-2), sequenceNumber: 1)
        _ = focusScorer.scoreFrame(pixelBuffer2, timestamp: Date().addingTimeInterval(-1), sequenceNumber: 2)
        
        // Modify score2 to be higher
        // Note: In real test, you'd create frames with different sharpness
        
        let bestFrame = focusScorer.findBestFrame(in: 3.0)
        XCTAssertNotNil(bestFrame, "Should find best frame in time range")
    }

    func testFindBestFrameReturnsNilWhenWindowHasNoFrames() {
        let now = Date()
        let oldFrame = createTestPixelBuffer(width: 320, height: 240)
        _ = focusScorer.scoreFrame(oldFrame, timestamp: now.addingTimeInterval(-20), sequenceNumber: 1)

        let bestFrame = focusScorer.findBestFrame(in: 3.0, now: now)
        XCTAssertNil(bestFrame, "Should return nil when no frames are in the requested lookback window")
        XCTAssertEqual(focusScorer.recentFrameCount(in: 3.0, now: now), 0)
    }

    func testSelectBestFramePrefersHighestScoreWithinWindow() {
        let now = Date()
        let lowDetail = createSolidPixelBuffer(width: 320, height: 240, value: 120)
        let highDetail = createCheckerboardPixelBuffer(width: 320, height: 240)

        _ = focusScorer.scoreFrame(
            lowDetail,
            timestamp: now.addingTimeInterval(-1.8),
            playbackTime: 8.2,
            sequenceNumber: 1
        )
        _ = focusScorer.scoreFrame(
            highDetail,
            timestamp: now.addingTimeInterval(-0.8),
            playbackTime: 9.2,
            sequenceNumber: 2
        )

        let selection = focusScorer.selectBestFrame(
            in: 3.0,
            now: now,
            currentPlaybackTime: 10.0,
            seekMode: .absolute
        )

        XCTAssertNotNil(selection)
        XCTAssertEqual(selection?.sequenceNumber, 2)
        XCTAssertEqual(selection?.seekMode, .absolute)
        XCTAssertEqual(selection?.playbackTime ?? 0, 9.2, accuracy: 0.05)
    }

    func testSelectBestFrameFallsBackToCurrentPlaybackTimeWhenFramePlaybackTimeMissing() {
        let now = Date()
        let frame = createCheckerboardPixelBuffer(width: 320, height: 240)
        _ = focusScorer.scoreFrame(frame, timestamp: now.addingTimeInterval(-1.5), sequenceNumber: 3)

        let selection = focusScorer.selectBestFrame(
            in: 3.0,
            now: now,
            currentPlaybackTime: 10.0,
            seekMode: .absolute
        )

        XCTAssertNotNil(selection)
        XCTAssertEqual(selection?.sequenceNumber, 3)
        XCTAssertEqual(selection?.playbackTime ?? 0, 8.5, accuracy: 0.15)
    }

    func testConfigurableLookbackWindowOneVsFiveSeconds() {
        let now = Date()
        let sharpOlderFrame = createCheckerboardPixelBuffer(width: 320, height: 240)
        let newerSoftFrame = createSolidPixelBuffer(width: 320, height: 240, value: 120)

        _ = focusScorer.scoreFrame(
            sharpOlderFrame,
            timestamp: now.addingTimeInterval(-4.5),
            playbackTime: 15.5,
            sequenceNumber: 10
        )
        _ = focusScorer.scoreFrame(
            newerSoftFrame,
            timestamp: now.addingTimeInterval(-0.4),
            playbackTime: 19.6,
            sequenceNumber: 11
        )

        let shortWindowSelection = focusScorer.selectBestFrame(
            in: 1.0,
            now: now,
            currentPlaybackTime: 20.0,
            seekMode: .absolute
        )
        XCTAssertEqual(shortWindowSelection?.sequenceNumber, 11, "1s lookback should only consider recent frames")

        let longWindowSelection = focusScorer.selectBestFrame(
            in: 5.0,
            now: now,
            currentPlaybackTime: 20.0,
            seekMode: .absolute
        )
        XCTAssertEqual(longWindowSelection?.sequenceNumber, 10, "5s lookback should include older sharper frames")
    }

    func testSelectBestFrameIncludesAgeAndSeekModeMetadata() {
        let now = Date()
        let frame = createCheckerboardPixelBuffer(width: 320, height: 240)
        _ = focusScorer.scoreFrame(
            frame,
            timestamp: now.addingTimeInterval(-1.25),
            playbackTime: 42.5,
            sequenceNumber: 12
        )

        let selection = focusScorer.selectBestFrame(
            in: 3.0,
            now: now,
            currentPlaybackTime: 44.0,
            seekMode: .liveBuffered
        )

        XCTAssertNotNil(selection)
        XCTAssertEqual(selection?.sequenceNumber, 12)
        XCTAssertEqual(selection?.seekMode, .liveBuffered)
        XCTAssertEqual(selection?.playbackTime ?? 0, 42.5, accuracy: 0.05)
        XCTAssertEqual(selection?.frameAge ?? 0, 1.25, accuracy: 0.2)
    }
    
    // Helper function to create test pixel buffer
    private func createTestPixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
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
        
        XCTAssertEqual(status, kCVReturnSuccess, "Should create pixel buffer successfully")
        XCTAssertNotNil(pixelBuffer, "Pixel buffer should not be nil")
        
        // Fill with test pattern
        CVPixelBufferLockBaseAddress(pixelBuffer!, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer!, []) }
        
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer!)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer!)
        let data = baseAddress?.assumingMemoryBound(to: UInt8.self)
        
        // Create a simple gradient pattern
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                data?[offset] = UInt8((x + y) % 256)     // B
                data?[offset + 1] = UInt8((x * 2) % 256) // G
                data?[offset + 2] = UInt8((y * 2) % 256) // R
                data?[offset + 3] = 255                  // A
            }
        }
        
        return pixelBuffer!
    }

    private func createSolidPixelBuffer(width: Int, height: Int, value: UInt8) -> CVPixelBuffer {
        let buffer = createTestPixelBuffer(width: width, height: height)
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

    private func createCheckerboardPixelBuffer(width: Int, height: Int, contrast: UInt8 = 112) -> CVPixelBuffer {
        let buffer = createTestPixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
        let block = 8
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let bright = ((x / block) + (y / block)) % 2 == 0
                let value: UInt8 = bright ? 128 + min(contrast, 127) : 128 - min(contrast, 127)
                data?[offset] = value
                data?[offset + 1] = value
                data?[offset + 2] = value
                data?[offset + 3] = 255
            }
        }
        return buffer
    }
}
