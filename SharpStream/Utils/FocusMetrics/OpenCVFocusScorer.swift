//
//  OpenCVFocusScorer.swift
//  SharpStream
//
//  OpenCV-based focus scoring
//

import Foundation
import CoreVideo

// Placeholder for OpenCV integration
// When OpenCV SPM package is added, implement actual scoring

class OpenCVFocusScorer {
    init() throws {
        // TODO: Initialize OpenCV when package is added
        // For now, throw error to use Swift-native fallback
        throw OpenCVError.notAvailable
    }
    
    func calculateScore(_ pixelBuffer: CVPixelBuffer) -> Double {
        // TODO: Implement Laplacian variance using OpenCV
        // This is a placeholder
        return 0.0
    }
}

enum OpenCVError: Error {
    case notAvailable
}
