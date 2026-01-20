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
    
    func calculateScore(_ pixelBuffer: CVPixelBuffer, algorithm: FocusAlgorithm = .laplacian) -> Double {
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
        
        switch algorithm {
        case .laplacian:
            return calculateLaplacianScore(gray)
        case .tenengrad:
            return calculateTenengradScore(gray)
        case .sobel:
            return calculateSobelScore(gray)
        }
    }
    
    private func calculateLaplacianScore(_ gray: Mat) -> Double {
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
    
    private func calculateTenengradScore(_ gray: Mat) -> Double {
        // Tenengrad: Sum of squared gradients using Sobel operators
        let gradX = Mat()
        let gradY = Mat()
        
        // Calculate gradients using Sobel operators
        Imgproc.Sobel(src: gray, dst: gradX, ddepth: CvType.CV_64F, dx: 1, dy: 0, ksize: 3, scale: 1, delta: 0)
        Imgproc.Sobel(src: gray, dst: gradY, ddepth: CvType.CV_64F, dx: 0, dy: 1, ksize: 3, scale: 1, delta: 0)
        
        // Calculate gradient magnitude squared (Gx^2 + Gy^2)
        let gradMagnitudeSquared = Mat()
        Core.multiply(src1: gradX, src2: gradX, dst: gradMagnitudeSquared)
        let temp = Mat()
        Core.multiply(src1: gradY, src2: gradY, dst: temp)
        Core.add(src1: gradMagnitudeSquared, src2: temp, dst: gradMagnitudeSquared)
        
        // Sum all squared gradients
        let sum = Core.sumElems(src: gradMagnitudeSquared)
        return Double(sum.val[0])
    }
    
    private func calculateSobelScore(_ gray: Mat) -> Double {
        // Sobel: Variance of Sobel edge detection result
        let sobelX = Mat()
        let sobelY = Mat()
        
        // Apply Sobel operators
        Imgproc.Sobel(src: gray, dst: sobelX, ddepth: CvType.CV_64F, dx: 1, dy: 0, ksize: 3, scale: 1, delta: 0)
        Imgproc.Sobel(src: gray, dst: sobelY, ddepth: CvType.CV_64F, dx: 0, dy: 1, ksize: 3, scale: 1, delta: 0)
        
        // Calculate magnitude
        let magnitude = Mat()
        Core.magnitude(x: sobelX, y: sobelY, magnitude: magnitude)
        
        // Calculate variance
        let mean = Scalar()
        let stddev = Scalar()
        Core.meanStdDev(src: magnitude, mean: mean, stddev: stddev)
        
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
    
    func calculateScore(_ pixelBuffer: CVPixelBuffer, algorithm: FocusAlgorithm = .laplacian) -> Double {
        // Return 0 to indicate OpenCV is not available
        // FocusScorer will fall back to Swift-native implementation
        return 0.0
    }
}

#endif
