//
//  FocusScorer.swift
//  SharpStream
//
//  Focus scoring coordinator
//

import Foundation
import CoreVideo
import Combine

class FocusScorer: ObservableObject {
    private var openCVScorer: OpenCVFocusScorer?
    private var swiftScorer: SwiftFocusScorer
    private var useOpenCV: Bool = true
    
    @Published var algorithm: FocusAlgorithm = .laplacian
    
    private var scoreHistory: [FrameScore] = []
    private let maxHistorySize = 1000
    
    init() {
        swiftScorer = SwiftFocusScorer()
        
        // Try to initialize OpenCV (from opencv-spm package)
        openCVScorer = OpenCVFocusScorer()
        useOpenCV = true // Will fall back to Swift-native if OpenCV not available
    }
    
    func scoreFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date, sequenceNumber: Int) -> FrameScore {
        let score: Double
        
        if useOpenCV, let openCVScorer = openCVScorer {
            let openCVScore = openCVScorer.calculateScore(pixelBuffer, algorithm: algorithm)
            // If OpenCV returns 0, it might mean it's not available, fall back to Swift
            if openCVScore > 0 {
                score = openCVScore
            } else {
                // Fall back to Swift-native (only Laplacian is implemented in Swift)
                score = swiftScorer.calculateScore(pixelBuffer)
            }
        } else {
            // Use Swift-native (only Laplacian is implemented in Swift)
            score = swiftScorer.calculateScore(pixelBuffer)
        }
        
        let frameScore = FrameScore(
            timestamp: timestamp,
            score: score,
            pixelBuffer: pixelBuffer,
            sequenceNumber: sequenceNumber
        )
        
        // Add to history
        scoreHistory.append(frameScore)
        if scoreHistory.count > maxHistorySize {
            scoreHistory.removeFirst()
        }
        
        return frameScore
    }
    
    func findBestFrame(in timeRange: TimeInterval) -> FrameScore? {
        let cutoffTime = Date().addingTimeInterval(-timeRange)
        let recentFrames = scoreHistory.filter { $0.timestamp >= cutoffTime }
        
        return recentFrames.max()
    }
    
    func getCurrentScore() -> Double? {
        return scoreHistory.last?.score
    }
    
    func getScoringFPS() -> Double {
        // Calculate FPS based on recent scoring rate
        guard scoreHistory.count >= 2 else { return 0 }
        
        let recent = Array(scoreHistory.suffix(30))
        guard let first = recent.first,
              let last = recent.last else { return 0 }
        
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        return duration > 0 ? Double(recent.count) / duration : 0
    }
    
    func setAlgorithm(_ algorithm: FocusAlgorithm) {
        self.algorithm = algorithm
        // All algorithms now implemented in OpenCV
        // Tenengrad and Sobel require OpenCV, Laplacian can fall back to Swift-native
        switch algorithm {
        case .laplacian:
            useOpenCV = true // Use OpenCV if available, otherwise Swift-native
        case .tenengrad, .sobel:
            useOpenCV = true // Tenengrad and Sobel require OpenCV
        }
    }
}
