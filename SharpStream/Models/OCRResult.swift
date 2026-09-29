//
//  OCRResult.swift
//  SharpStream
//
//  OCR recognition result model
//

import Foundation
import CoreGraphics

nonisolated struct OCRLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let confidence: Double
    /// Vision normalized box (origin bottom-left, 0...1) in the source frame.
    let boundingBox: CGRect
}

nonisolated struct OCRResult: Identifiable, Equatable {
    let id: UUID
    let text: String
    let confidence: Double
    let boundingBoxes: [CGRect]
    let lines: [OCRLine]
    let timestamp: Date
    let frameID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        boundingBoxes: [CGRect] = [],
        lines: [OCRLine] = [],
        timestamp: Date = Date(),
        frameID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBoxes = boundingBoxes.isEmpty ? lines.map(\.boundingBox) : boundingBoxes
        self.lines = lines
        self.timestamp = timestamp
        self.frameID = frameID
    }
}

nonisolated extension OCRResult {
    var fullText: String {
        text
    }

    var averageConfidence: Double {
        confidence
    }
}
