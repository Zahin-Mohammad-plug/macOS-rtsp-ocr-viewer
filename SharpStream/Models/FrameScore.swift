//
//  FrameScore.swift
//  FrameScore
//
//  Frame with focus score data
//

import Foundation
import CoreVideo

struct FrameScore: Identifiable {
    let id: UUID
    let timestamp: Date
    let score: Double
    var pixelBuffer: CVPixelBuffer?
    let sequenceNumber: Int
    
    init(id: UUID = UUID(), timestamp: Date, score: Double, pixelBuffer: CVPixelBuffer? = nil, sequenceNumber: Int) {
        self.id = id
        self.timestamp = timestamp
        self.score = score
        self.pixelBuffer = pixelBuffer
        self.sequenceNumber = sequenceNumber
    }
}

extension FrameScore: Comparable {
    static func < (lhs: FrameScore, rhs: FrameScore) -> Bool {
        lhs.score < rhs.score
    }
}
