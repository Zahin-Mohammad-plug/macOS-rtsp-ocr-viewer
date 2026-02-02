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
        // Get current playback time from player
        guard let player = appState.streamManager.player else {
            return nil
        }
        
        let currentTime = player.currentTime
        // Calculate timestamp by going back from now
        let timestamp = Date().addingTimeInterval(-currentTime)
        
        // Get frame from buffer
        return await appState.bufferManager.getFrame(at: timestamp, tolerance: 0.5)
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
        guard let ocrResult = currentOCRResult, !ocrResult.text.isEmpty else {
            showErrorAlert(message: "No OCR text available to copy")
            return
        }
        
        appState.exportManager.copyTextToClipboard(ocrResult.text)
        showSuccessAlert(message: "OCR text copied to clipboard")
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
