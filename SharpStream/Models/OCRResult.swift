//
//  OCRResult.swift
//  SharpStream
//
//  OCR recognition result model
//

import Foundation
import CoreGraphics

struct OCRResult: Identifiable {
    let id: UUID
    let text: String
    let confidence: Double
    let boundingBoxes: [CGRect]
    let timestamp: Date
    let frameID: UUID?
    
    init(id: UUID = UUID(), text: String, confidence: Double, boundingBoxes: [CGRect] = [], timestamp: Date = Date(), frameID: UUID? = nil) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBoxes = boundingBoxes
        self.timestamp = timestamp
        self.frameID = frameID
    }
}

extension OCRResult {
    var fullText: String {
        text
    }
    
    var averageConfidence: Double {
        confidence
    }
}
