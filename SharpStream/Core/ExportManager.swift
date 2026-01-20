//
//  ExportManager.swift
//  SharpStream
//
//  Frame/image export functionality
//

import Foundation
import AppKit
import CoreVideo
import CoreImage

enum ExportFormat {
    case png
    case jpeg(quality: CGFloat)
}

class ExportManager {
    private let ciContext = CIContext()
    
    func saveFrame(_ pixelBuffer: CVPixelBuffer, to url: URL, format: ExportFormat = .png) throws {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        switch format {
        case .png:
            guard let data = ciContext.pngRepresentation(of: ciImage, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
                throw ExportError.conversionFailed
            }
            try data.write(to: url)
            
        case .jpeg(let quality):
            guard let data = ciContext.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [.compressionQuality: quality]) else {
                throw ExportError.conversionFailed
            }
            try data.write(to: url)
        }
    }
    
    func copyFrameToClipboard(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }
    
    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    func exportOCRText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    
    func exportFrameWithOCR(_ pixelBuffer: CVPixelBuffer, ocrResult: OCRResult, to url: URL, format: ExportFormat = .png) throws {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Create composite image with OCR overlay
        // This is a simplified version - in production, you'd draw text overlays
        let compositeImage = ciImage
        
        switch format {
        case .png:
            guard let data = ciContext.pngRepresentation(of: compositeImage, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
                throw ExportError.conversionFailed
            }
            try data.write(to: url)
            
        case .jpeg(let quality):
            guard let data = ciContext.jpegRepresentation(of: compositeImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [.compressionQuality: quality]) else {
                throw ExportError.conversionFailed
            }
            try data.write(to: url)
        }
    }
    
    func batchExport(frames: [CVPixelBuffer], ocrResults: [OCRResult?], to directory: URL, format: ExportFormat = .png) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        for (index, frame) in frames.enumerated() {
            let filename = String(format: "frame_%05d", index)
            let url: URL
            
            switch format {
            case .png:
                url = directory.appendingPathComponent("\(filename).png")
            case .jpeg:
                url = directory.appendingPathComponent("\(filename).jpg")
            }
            
            try saveFrame(frame, to: url, format: format)
            
            // Export OCR text if available
            if let ocrResult = ocrResults[safe: index], !ocrResult.text.isEmpty {
                let textURL = directory.appendingPathComponent("\(filename).txt")
                try exportOCRText(ocrResult.text, to: textURL)
            }
        }
    }
}

enum ExportError: Error {
    case conversionFailed
    case writeFailed
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
