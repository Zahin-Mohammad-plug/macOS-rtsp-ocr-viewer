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
import UniformTypeIdentifiers

enum ExportFormat: Equatable {
    case png
    case jpeg(quality: CGFloat)

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

enum ExportError: LocalizedError {
    case conversionFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .conversionFailed: return "The frame could not be converted to an image."
        case .writeFailed: return "The file could not be written."
        }
    }
}

final class ExportManager {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    func saveFrame(_ pixelBuffer: CVPixelBuffer, to url: URL, format: ExportFormat = .png) throws {
        guard let image = cgImage(from: pixelBuffer) else { throw ExportError.conversionFailed }
        try write(image, to: url, format: format)
    }

    func copyFrameToClipboard(_ pixelBuffer: CVPixelBuffer) {
        guard let image = cgImage(from: pixelBuffer) else { return }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
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

    /// Saves the frame with OCR boxes and recognized text drawn on top.
    func exportFrameWithOCR(_ pixelBuffer: CVPixelBuffer, ocrResult: OCRResult, to url: URL, format: ExportFormat = .png) throws {
        guard let base = cgImage(from: pixelBuffer),
              let annotated = annotate(base, with: ocrResult) else {
            throw ExportError.conversionFailed
        }
        try write(annotated, to: url, format: format)
    }

    func annotate(_ image: CGImage, with result: OCRResult) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let lineWidth = max(2, CGFloat(width) / 640)
        let fontSize = max(12, CGFloat(height) / 45)
        let lines = result.lines.isEmpty
            ? result.boundingBoxes.map { OCRLine(text: "", confidence: 0, boundingBox: $0) }
            : result.lines

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for line in lines {
            // Vision boxes are normalized with a bottom-left origin — same as CGContext.
            let rect = CGRect(
                x: line.boundingBox.minX * CGFloat(width),
                y: line.boundingBox.minY * CGFloat(height),
                width: line.boundingBox.width * CGFloat(width),
                height: line.boundingBox.height * CGFloat(height)
            )
            context.setStrokeColor(NSColor.systemGreen.cgColor)
            context.setLineWidth(lineWidth)
            context.stroke(rect.insetBy(dx: -lineWidth, dy: -lineWidth))

            guard !line.text.isEmpty else { continue }
            let label = NSAttributedString(string: line.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            let labelSize = label.size()
            var origin = CGPoint(x: rect.minX, y: rect.maxY + lineWidth * 2)
            if origin.y + labelSize.height > CGFloat(height) {
                origin.y = rect.minY - labelSize.height - lineWidth * 2
            }
            let background = CGRect(origin: origin, size: labelSize).insetBy(dx: -4, dy: -2)
            context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            context.fill(background)
            label.draw(at: origin)
        }
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }

    private func write(_ image: CGImage, to url: URL, format: ExportFormat) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let data: Data?
        switch format {
        case .png:
            data = rep.representation(using: .png, properties: [:])
        case .jpeg(let quality):
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        guard let data else { throw ExportError.conversionFailed }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
    }
}
