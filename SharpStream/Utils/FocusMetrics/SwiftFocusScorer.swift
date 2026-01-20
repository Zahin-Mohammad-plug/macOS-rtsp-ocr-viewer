//
//  SwiftFocusScorer.swift
//  SharpStream
//
//  Swift-native Laplacian focus scoring using Accelerate
//

import Foundation
import Accelerate
import CoreVideo

class SwiftFocusScorer {
    private let laplacianKernel: [Float] = [
        0, -1, 0,
        -1, 4, -1,
        0, -1, 0
    ]
    
    func calculateScore(_ pixelBuffer: CVPixelBuffer) -> Double {
        // Lock pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0.0
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        // Convert to grayscale if needed
        var grayBuffer: [Float]
        
        if pixelFormat == kCVPixelFormatType_32BGRA {
            grayBuffer = convertBGRAtoGrayscale(baseAddress: baseAddress, width: width, height: height, bytesPerRow: bytesPerRow)
        } else {
            // For other formats, return 0 (would need format-specific conversion)
            return 0.0
        }
        
        // Apply Laplacian kernel
        let laplacianResult = applyLaplacian(grayBuffer, width: width, height: height)
        
        // Calculate variance
        let variance = calculateVariance(laplacianResult)
        
        return Double(variance)
    }
    
    private func convertBGRAtoGrayscale(baseAddress: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) -> [Float] {
        var grayBuffer = [Float](repeating: 0, count: width * height)
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let b = Float(buffer[offset])
                let g = Float(buffer[offset + 1])
                let r = Float(buffer[offset + 2])
                
                // Convert to grayscale using standard weights
                let gray = 0.299 * r + 0.587 * g + 0.114 * b
                grayBuffer[y * width + x] = gray
            }
        }
        
        return grayBuffer
    }
    
    private func applyLaplacian(_ input: [Float], width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height)
        
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = input[y * width + x]
                let top = input[(y - 1) * width + x]
                let bottom = input[(y + 1) * width + x]
                let left = input[y * width + (x - 1)]
                let right = input[y * width + (x + 1)]
                
                // Apply Laplacian kernel
                let laplacian = 4 * center - top - bottom - left - right
                output[y * width + x] = laplacian
            }
        }
        
        return output
    }
    
    private func calculateVariance(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        
        let count = Float(values.count)
        let mean = values.reduce(0, +) / count
        
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        let variance = squaredDiffs.reduce(0, +) / count
        
        return variance
    }
}
