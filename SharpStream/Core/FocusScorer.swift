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
    
    func scoreFrame(
        _ pixelBuffer: CVPixelBuffer,
        timestamp: Date,
        playbackTime: TimeInterval? = nil,
        sequenceNumber: Int
    ) -> FrameScore {
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
            playbackTime: playbackTime,
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
    
    func findBestFrame(in timeRange: TimeInterval, now: Date = Date()) -> FrameScore? {
        let cutoffTime = now.addingTimeInterval(-timeRange)
        let recentFrames = scoreHistory.filter { $0.timestamp >= cutoffTime && $0.timestamp <= now }
        
        return recentFrames.max()
    }

    func recentFrameCount(in timeRange: TimeInterval, now: Date = Date()) -> Int {
        let cutoffTime = now.addingTimeInterval(-timeRange)
        return scoreHistory.filter { $0.timestamp >= cutoffTime && $0.timestamp <= now }.count
    }

    func frame(sequenceNumber: Int) -> FrameScore? {
        scoreHistory.first(where: { $0.sequenceNumber == sequenceNumber })
    }

    func selectBestFrame(
        in timeRange: TimeInterval,
        now: Date = Date(),
        currentPlaybackTime: TimeInterval?,
        seekMode: SeekMode
    ) -> SmartPauseSelection? {
        guard let bestFrame = findBestFrame(in: timeRange, now: now) else {
            return nil
        }

        let frameAge = max(0, now.timeIntervalSince(bestFrame.timestamp))
        let playbackTarget: TimeInterval?

        if let framePlaybackTime = bestFrame.playbackTime {
            playbackTarget = framePlaybackTime
        } else if let currentPlaybackTime {
            playbackTarget = max(0, currentPlaybackTime - frameAge)
        } else {
            playbackTarget = nil
        }

        return SmartPauseSelection(
            sequenceNumber: bestFrame.sequenceNumber,
            score: bestFrame.score,
            frameTimestamp: bestFrame.timestamp,
            playbackTime: playbackTarget,
            frameAge: frameAge,
            seekMode: seekMode
        )
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
