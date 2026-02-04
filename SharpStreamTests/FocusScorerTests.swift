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

    private func createCheckerboardPixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
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
                let value: UInt8 = bright ? 240 : 15
                data?[offset] = value
                data?[offset + 1] = value
                data?[offset + 2] = value
                data?[offset + 3] = 255
            }
        }
        return buffer
    }
}
