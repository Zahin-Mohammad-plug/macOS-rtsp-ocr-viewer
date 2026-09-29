//
//  OCREngine.swift
//  SharpStream
//
//  Vision framework OCR wrapper
//

import Foundation
import Vision
import CoreVideo
import Combine

enum OCRRecognitionLevel: String, CaseIterable {
    case fast
    case accurate

    var visionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .fast: return .fast
        case .accurate: return .accurate
        }
    }
}

final class OCREngine: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var recognitionLevel: OCRRecognitionLevel = .accurate
    @Published var languages: [String] = ["en-US"]
    /// Language correction helps prose but mangles codes, plates and IDs.
    @Published var usesLanguageCorrection: Bool = false

    private let processingQueue = DispatchQueue(label: "com.sharpstream.ocr", qos: .userInitiated)

    func recognizeText(in pixelBuffer: CVPixelBuffer) async -> OCRResult? {
        await withCheckedContinuation { continuation in
            recognizeText(in: pixelBuffer) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Completion is delivered on the main queue.
    func recognizeText(in pixelBuffer: CVPixelBuffer, completion: @escaping (OCRResult?) -> Void) {
        guard isEnabled else {
            completion(nil)
            return
        }

        let configuration = (
            level: recognitionLevel.visionLevel,
            languages: normalizedLanguages(),
            correction: usesLanguageCorrection
        )

        processingQueue.async {
            var result: OCRResult?
            do {
                result = try Self.recognize(
                    in: pixelBuffer,
                    level: configuration.level,
                    languages: configuration.languages,
                    correction: configuration.correction
                )
                // An unsupported/mismatched language list can yield nothing; retry
                // once with automatic language detection.
                if result == nil, !configuration.languages.isEmpty {
                    result = try Self.recognize(
                        in: pixelBuffer,
                        level: configuration.level,
                        languages: [],
                        correction: configuration.correction
                    )
                }
            } catch {
                print("OCR error: \(error)")
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func normalizedLanguages() -> [String] {
        languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func recognize(
        in pixelBuffer: CVPixelBuffer,
        level: VNRequestTextRecognitionLevel,
        languages: [String],
        correction: Bool
    ) throws -> OCRResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = correction
        request.minimumTextHeight = 0.01
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }

        // Frames come straight from the decoder, upright: never rotate, or the
        // returned boxes would no longer line up with the picture.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        // Reading order: top-to-bottom, then left-to-right.
        let sorted = observations.sorted { lhs, rhs in
            let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(dy) > min(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5 {
                return dy > 0
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        let lines: [OCRLine] = sorted.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, confidence: Double(candidate.confidence), boundingBox: observation.boundingBox)
        }
        guard !lines.isEmpty else { return nil }

        let averageConfidence = lines.map(\.confidence).reduce(0, +) / Double(lines.count)
        return OCRResult(
            text: lines.map(\.text).joined(separator: "\n"),
            confidence: averageConfidence,
            lines: lines,
            timestamp: Date()
        )
    }
}
