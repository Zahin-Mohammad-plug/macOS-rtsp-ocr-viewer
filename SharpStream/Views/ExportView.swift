//
//  ExportView.swift
//  SharpStream
//
//  Export/save options UI
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ExportView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("defaultExportFormat") private var defaultExportFormat: String = "PNG"
    @AppStorage("defaultJPEGQuality") private var defaultJPEGQuality: Double = 0.8
    @State private var showSavePanel = false
    @State private var exportFormat: ExportFormat = .png
    @State private var jpegQuality: Double = 0.8
    @State private var currentOCRResult: OCRResult?
    
    var body: some View {
        Menu {
            Button("Save Frame as Image...") {
                saveFrame()
            }
            
            Button("Copy Frame to Clipboard") {
                copyFrame()
            }
            
            Divider()
            
            Button("Export OCR Text...") {
                exportOCRText()
            }
            
            Button("Copy OCR Text") {
                copyOCRText()
            }
            
            Divider()
            
            Button("Export Frame with OCR...") {
                exportFrameWithOCR()
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .accessibilityIdentifier("exportMenuButton")
        .onChange(of: appState.currentOCRResult) { oldValue, newValue in
            currentOCRResult = newValue
        }
        .onAppear {
            // Initialize from preferences
            jpegQuality = defaultJPEGQuality
            exportFormat = defaultExportFormat == "JPEG" ? .jpeg(quality: CGFloat(defaultJPEGQuality)) : .png
            currentOCRResult = appState.currentOCRResult
        }
        .onChange(of: defaultExportFormat) { _, newValue in
            exportFormat = newValue == "JPEG" ? .jpeg(quality: CGFloat(defaultJPEGQuality)) : .png
        }
        .onChange(of: defaultJPEGQuality) { _, newValue in
            jpegQuality = newValue
            if case .jpeg = exportFormat {
                exportFormat = .jpeg(quality: CGFloat(newValue))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ExportCurrentFrame"))) { _ in
            saveFrame()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ExportOCRText"))) { _ in
            exportOCRText()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ExportFrameWithOCR"))) { _ in
            exportFrameWithOCR()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CopyToClipboard"))) { _ in
            copyOCRText()
        }
    }
    
    private func getCurrentFrame() async -> CVPixelBuffer? {
        if let player = appState.streamManager.player {
            var playerFrame: CVPixelBuffer?
            await MainActor.run {
                player.suspendFrameExtractionForSnapshot()
                defer { player.resumeFrameExtractionAfterSnapshot() }
                playerFrame = player.getCurrentFrame()
            }

            if let playerFrame, !isLikelyBlackFrame(playerFrame) {
                return playerFrame
            }
        }

        if let bufferedFrame = await appState.bufferManager.getFrame(at: Date(), tolerance: 0.4),
           !isLikelyBlackFrame(bufferedFrame) {
            return bufferedFrame
        }

        if let bufferedFrame = await appState.bufferManager.getFrame(at: Date(), tolerance: 1.5),
           !isLikelyBlackFrame(bufferedFrame) {
            return bufferedFrame
        }

        return nil
    }

    private func isLikelyBlackFrame(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return true
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let sampleStrideX = max(1, width / 48)
        let sampleStrideY = max(1, height / 48)

        var sampleCount = 0
        var brightSamples = 0
        var totalLuma = 0.0

        for y in stride(from: 0, to: height, by: sampleStrideY) {
            for x in stride(from: 0, to: width, by: sampleStrideX) {
                let offset = y * bytesPerRow + x * 4
                let ptr = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)

                // kCVPixelFormatType_32BGRA
                let b = Double(ptr[0])
                let g = Double(ptr[1])
                let r = Double(ptr[2])
                let luma = 0.0722 * b + 0.7152 * g + 0.2126 * r

                totalLuma += luma
                if luma > 16 { brightSamples += 1 }
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return true }
        let avgLuma = totalLuma / Double(sampleCount)
        let brightRatio = Double(brightSamples) / Double(sampleCount)
        return avgLuma < 10 && brightRatio < 0.03
    }
    
    private func saveFrame() {
        Task {
            guard let frame = await getCurrentFrame() else {
                showErrorAlert(message: "No frame available to export")
                return
            }
            
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png, .jpeg]
            savePanel.nameFieldStringValue = "frame_\(Date().timeIntervalSince1970)"
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            
            if savePanel.runModal() == .OK, let url = savePanel.url {
                do {
                    // Determine format from file extension
                    let format: ExportFormat
                    if url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" {
                        format = .jpeg(quality: CGFloat(jpegQuality))
                    } else {
                        format = .png
                    }
                    
                    try appState.exportManager.saveFrame(frame, to: url, format: format)
                    
                    // Show success notification
                    await MainActor.run {
                        showSuccessAlert(message: "Frame saved successfully")
                    }
                } catch {
                    await MainActor.run {
                        showErrorAlert(message: "Failed to save frame: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func copyFrame() {
        Task {
            guard let frame = await getCurrentFrame() else {
                showErrorAlert(message: "No frame available to copy")
                return
            }
            
            appState.exportManager.copyFrameToClipboard(frame)
            
            await MainActor.run {
                showSuccessAlert(message: "Frame copied to clipboard")
            }
        }
    }
    
    private func exportOCRText() {
        guard let ocrResult = currentOCRResult, !ocrResult.text.isEmpty else {
            showErrorAlert(message: "No OCR text available to export")
            return
        }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "ocr_text_\(Date().timeIntervalSince1970).txt"
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try appState.exportManager.exportOCRText(ocrResult.text, to: url)
                showSuccessAlert(message: "OCR text exported successfully")
            } catch {
                showErrorAlert(message: "Failed to export OCR text: \(error.localizedDescription)")
            }
        }
    }
    
    private func copyOCRText() {
        Task { @MainActor in
            guard appState.ocrEngine.isEnabled else {
                showErrorAlert(message: "OCR is disabled. Enable OCR in Preferences > OCR to copy text from frame.")
                return
            }

            guard let frame = await getCurrentFrame() else {
                showErrorAlert(message: "No frame available to copy text from.")
                return
            }

            let firstPass = await appState.ocrEngine.recognizeText(in: frame)
            var bestResult = firstPass

            if (bestResult?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               appState.streamManager.player?.isPlaying == true {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let retryFrame = await getCurrentFrame() {
                    bestResult = await appState.ocrEngine.recognizeText(in: retryFrame)
                }
            }

            guard let ocrResult = bestResult else {
                showErrorAlert(message: "No text detected in current frame.")
                return
            }

            let trimmedText = ocrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                showErrorAlert(message: "No text detected in current frame.")
                return
            }

            let normalizedResult = OCRResult(
                id: ocrResult.id,
                text: trimmedText,
                confidence: ocrResult.confidence,
                boundingBoxes: ocrResult.boundingBoxes,
                timestamp: ocrResult.timestamp,
                frameID: ocrResult.frameID
            )
            appState.currentOCRResult = normalizedResult
            currentOCRResult = normalizedResult
            appState.exportManager.copyTextToClipboard(trimmedText)
            showSuccessAlert(message: "OCR text copied to clipboard")
        }
    }
    
    private func exportFrameWithOCR() {
        Task {
            guard let frame = await getCurrentFrame() else {
                showErrorAlert(message: "No frame available to export")
                return
            }
            
            guard let ocrResult = currentOCRResult else {
                showErrorAlert(message: "No OCR result available")
                return
            }
            
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png, .jpeg]
            savePanel.nameFieldStringValue = "frame_with_ocr_\(Date().timeIntervalSince1970)"
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            
            if savePanel.runModal() == .OK, let url = savePanel.url {
                do {
                    // Determine format from file extension
                    let format: ExportFormat
                    if url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" {
                        format = .jpeg(quality: CGFloat(jpegQuality))
                    } else {
                        format = .png
                    }
                    
                    try appState.exportManager.exportFrameWithOCR(frame, ocrResult: ocrResult, to: url, format: format)
                    
                    await MainActor.run {
                        showSuccessAlert(message: "Frame with OCR exported successfully")
                    }
                } catch {
                    await MainActor.run {
                        showErrorAlert(message: "Failed to export: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func showSuccessAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
