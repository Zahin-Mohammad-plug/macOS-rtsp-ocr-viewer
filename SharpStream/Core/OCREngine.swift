//
//  OCREngine.swift
//  SharpStream
//
//  Vision framework OCR wrapper
//

import Foundation
import Vision
import CoreVideo
import CoreImage
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
    /// Smallest text to look for, as a fraction of frame height (0 = Vision default).
    @Published var minimumTextHeight: Float = OCREngine.defaultMinimumTextHeight

    nonisolated static let defaultMinimumTextHeight: Float = 0.01

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
            correction: usesLanguageCorrection,
            minimumTextHeight: minimumTextHeight
        )

        processingQueue.async {
            var result: OCRResult?
            do {
                result = try Self.recognize(
                    in: pixelBuffer,
                    level: configuration.level,
                    languages: configuration.languages,
                    correction: configuration.correction,
                    minimumTextHeight: configuration.minimumTextHeight
                )
                // An unsupported/mismatched language list can yield nothing; retry
                // once with automatic language detection.
                if result == nil, !configuration.languages.isEmpty {
                    result = try Self.recognize(
                        in: pixelBuffer,
                        level: configuration.level,
                        languages: [],
                        correction: configuration.correction,
                        minimumTextHeight: configuration.minimumTextHeight
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

    /// Vision downsamples large inputs internally, so small print in frames
    /// below ~1600 px tall loses detail. Measured with scripts/ocr_bench on the
    /// test page: 1.5x raises 720p from 5 to 7 of 12 lines (14 pt -> 12 pt
    /// smallest reliable) and makes 12 pt consistent on live 1080p frames
    /// (9/12 -> 12/12 frames), for ~10 ms.
    nonisolated static func upscaleFactor(forHeight height: Int) -> Double {
        height > 0 && height < 1600 ? 1.5 : 1
    }

    /// Synchronous recognition with explicit parameters (used by the engine and
    /// by the OCR benchmark harness in scripts/ocr_bench).
    nonisolated static func recognize(
        in pixelBuffer: CVPixelBuffer,
        level: VNRequestTextRecognitionLevel,
        languages: [String],
        correction: Bool,
        minimumTextHeight: Float
    ) throws -> OCRResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = correction
        request.minimumTextHeight = minimumTextHeight
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }

        // Frames come straight from the decoder, upright: never rotate, or the
        // returned boxes would no longer line up with the picture. Boxes are
        // normalized, so upscaling doesn't affect them either.
        let factor = upscaleFactor(forHeight: CVPixelBufferGetHeight(pixelBuffer))
        let handler: VNImageRequestHandler
        if factor > 1 {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: factor,
                    kCIInputAspectRatioKey: 1.0
                ])
            handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        } else {
            handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        }
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
