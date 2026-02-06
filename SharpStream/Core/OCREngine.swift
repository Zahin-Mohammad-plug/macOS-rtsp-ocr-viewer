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
import ImageIO

enum OCRRecognitionLevel {
    case fast
    case accurate
    
    var visionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .fast: return .fast
        case .accurate: return .accurate
        }
    }
}

class OCREngine: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var recognitionLevel: OCRRecognitionLevel = .accurate
    @Published var languages: [String] = ["en-US"]
    
    private let processingQueue = DispatchQueue(label: "com.sharpstream.ocr", qos: .userInitiated)

    func recognizeText(in pixelBuffer: CVPixelBuffer) async -> OCRResult? {
        await withCheckedContinuation { continuation in
            recognizeText(in: pixelBuffer) { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    func recognizeText(in pixelBuffer: CVPixelBuffer, completion: @escaping (OCRResult?) -> Void) {
        guard isEnabled else {
            completion(nil)
            return
        }
        
        processingQueue.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }

            let configuredLanguages = self.normalizedLanguages()
            let attempts: [([String], CGImagePropertyOrientation)] = [
                (configuredLanguages, .up),
                ([], .up),
                (configuredLanguages, .right),
                ([], .right)
            ]

            for (languages, orientation) in attempts {
                do {
                    if let result = try self.recognizeText(
                        in: pixelBuffer,
                        orientation: orientation,
                        languages: languages
                    ) {
                        DispatchQueue.main.async {
                            completion(result)
                        }
                        return
                    }
                } catch {
                    print("OCR error: \(error)")
                }
            }

            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
    
    func recognizeTextSync(in pixelBuffer: CVPixelBuffer) -> OCRResult? {
        var result: OCRResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        recognizeText(in: pixelBuffer) { ocrResult in
            result = ocrResult
            semaphore.signal()
        }
        
        semaphore.wait()
        return result
    }

    private func normalizedLanguages() -> [String] {
        languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        languages: [String]
    ) throws -> OCRResult? {
        var recognizedText = ""
        var boundingBoxes: [CGRect] = []
        var confidences: [Double] = []

        let request = VNRecognizeTextRequest { request, error in
            if let error {
                print("OCR request error: \(error)")
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            for observation in observations {
                guard let topCandidate = observation.topCandidates(1).first else { continue }
                recognizedText += topCandidate.string + "\n"
                boundingBoxes.append(observation.boundingBox)
                confidences.append(Double(topCandidate.confidence))
            }
        }

        request.recognitionLevel = recognitionLevel.visionLevel
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.003
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])

        let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let averageConfidence = confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Double(confidences.count)
        return OCRResult(
            text: text,
            confidence: averageConfidence,
            boundingBoxes: boundingBoxes,
            timestamp: Date()
        )
    }
}
