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
import CoreText
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

    /// Vision loads its recognition models on first use, which can take 10+ s
    /// (longer with automatic language detection). Run one tiny request in the
    /// background so the user's first Recognize Text is fast.
    func prewarm() {
        guard isEnabled else { return }
        let level = recognitionLevel.visionLevel
        let languages = normalizedLanguages()
        let correction = usesLanguageCorrection
        processingQueue.async {
            // Real text, so both the detector and the recognizer get loaded.
            guard let buffer = Self.makeWarmupImage() else { return }
            _ = try? Self.recognize(in: buffer, level: level, languages: languages, correction: correction,
                                    minimumTextHeight: Self.defaultMinimumTextHeight)
        }
    }

    nonisolated private static func makeWarmupImage() -> CVPixelBuffer? {
        let width = 320, height = 96
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let text = NSAttributedString(string: "Warm up 123", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 16, y: 30)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return buffer
    }

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
        // Reading order: group observations into rows (vertical overlap), rows
        // top-to-bottom, each row left-to-right. (A pairwise comparator with a
        // tolerance isn't a strict weak ordering and can scramble dense text.)
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in observations.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let last = rows.last?.last,
               abs(last.boundingBox.midY - observation.boundingBox.midY)
                < min(last.boundingBox.height, observation.boundingBox.height) * 0.5 {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        let sorted = rows.flatMap { row in row.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }

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
