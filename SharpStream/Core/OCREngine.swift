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
            
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    print("OCR error: \(error)")
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                    return
                }
                
                var fullText = ""
                var boundingBoxes: [CGRect] = []
                var confidences: [Double] = []
                
                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }
                    
                    fullText += topCandidate.string + "\n"
                    boundingBoxes.append(observation.boundingBox)
                    confidences.append(Double(topCandidate.confidence))
                }
                
                let averageConfidence = confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Double(confidences.count)
                
                let result = OCRResult(
                    text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: averageConfidence,
                    boundingBoxes: boundingBoxes,
                    timestamp: Date()
                )
                
                DispatchQueue.main.async {
                    completion(result)
                }
            }
            
            request.recognitionLevel = self.recognitionLevel.visionLevel
            request.recognitionLanguages = self.languages
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
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
}
