//
//  OpenCVFocusScorer.swift
//  SharpStream
//
//  OpenCV-based focus scoring
//

import Foundation
import CoreVideo

#if canImport(opencv2)
import opencv2

class OpenCVFocusScorer {
    init() {
        // OpenCV is available via opencv-spm package
    }
    
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
        
        // Convert CVPixelBuffer to OpenCV Mat
        var mat: Mat
        if pixelFormat == kCVPixelFormatType_32BGRA {
            let data = baseAddress.assumingMemoryBound(to: UInt8.self)
            mat = Mat(rows: Int32(height), cols: Int32(width), type: CvType.CV_8UC4, data: data, step: Int32(bytesPerRow))
        } else {
            // For other formats, would need conversion
            return 0.0
        }
        
        // Convert to grayscale
        let gray = Mat()
        Imgproc.cvtColor(src: mat, dst: gray, code: .COLOR_BGRA2GRAY)
        
        // Apply Laplacian
        let laplacian = Mat()
        Imgproc.Laplacian(src: gray, dst: laplacian, ddepth: CvType.CV_64F, ksize: 3, scale: 1, delta: 0)
        
        // Calculate variance (standard deviation squared)
        let mean = Scalar()
        let stddev = Scalar()
        Core.meanStdDev(src: laplacian, mean: mean, stddev: stddev)
        
        let variance = stddev.val[0] * stddev.val[0]
        return Double(variance)
    }
}

#else

// Fallback when OpenCV is not available
class OpenCVFocusScorer {
    init() {
        // OpenCV not available - will use Swift-native implementation
    }
    
    func calculateScore(_ pixelBuffer: CVPixelBuffer) -> Double {
        // Return 0 to indicate OpenCV is not available
        // FocusScorer will fall back to Swift-native implementation
        return 0.0
    }
}

#endif
