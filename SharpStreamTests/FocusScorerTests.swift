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
        
        let score1 = focusScorer.scoreFrame(pixelBuffer1, timestamp: Date().addingTimeInterval(-2), sequenceNumber: 1)
        let score2 = focusScorer.scoreFrame(pixelBuffer2, timestamp: Date().addingTimeInterval(-1), sequenceNumber: 2)
        
        // Modify score2 to be higher
        // Note: In real test, you'd create frames with different sharpness
        
        let bestFrame = focusScorer.findBestFrame(in: 3.0)
        XCTAssertNotNil(bestFrame, "Should find best frame in time range")
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
}
