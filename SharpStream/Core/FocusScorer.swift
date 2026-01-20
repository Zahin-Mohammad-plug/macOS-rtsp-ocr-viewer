//
//  FocusScorer.swift
//  SharpStream
//
//  Focus scoring coordinator
//

import Foundation
import CoreVideo

class FocusScorer {
    private var openCVScorer: OpenCVFocusScorer?
    private var swiftScorer: SwiftFocusScorer
    private var useOpenCV: Bool = true
    
    private var scoreHistory: [FrameScore] = []
    private let maxHistorySize = 1000
    
    init() {
        swiftScorer = SwiftFocusScorer()
        
        // Try to initialize OpenCV
        do {
            openCVScorer = try OpenCVFocusScorer()
            useOpenCV = true
        } catch {
            print("OpenCV not available, using Swift-native implementation")
            useOpenCV = false
        }
    }
    
    func scoreFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date, sequenceNumber: Int) -> FrameScore {
        let score: Double
        
        if useOpenCV, let openCVScorer = openCVScorer {
            score = openCVScorer.calculateScore(pixelBuffer)
        } else {
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
}
