//
//  OCREngineTests.swift
//  SharpStreamTests
//
//  Deterministic tests for async OCR wrapper behavior.
//

import XCTest
import CoreVideo
@testable import SharpStream

final class OCREngineTests: XCTestCase {
    func testRecognizeTextAsyncReturnsNilWhenDisabled() async {
        let engine = OCREngine()
        engine.isEnabled = false

        let pixelBuffer = makeSolidPixelBuffer(width: 64, height: 64, value: 200)
        let result = await engine.recognizeText(in: pixelBuffer)

        XCTAssertNil(result)
    }

    private func makeSolidPixelBuffer(width: Int, height: Int, value: UInt8) -> CVPixelBuffer {
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

        guard let buffer = pixelBuffer else {
            fatalError("Failed to create test pixel buffer")
        }

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
}
