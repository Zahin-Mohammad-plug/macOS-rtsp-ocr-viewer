//
//  ExportView.swift
//  SharpStream
//
//  Export/save options UI
//

import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSavePanel = false
    @State private var exportFormat: ExportFormat = .png
    @State private var jpegQuality: Double = 0.8
    
    var body: some View {
        Menu {
            Button("Save Frame as Image...") {
                saveFrame()
            }
            
            Button("Copy Frame to Clipboard") {
                copyFrame()
            }
            
            Button("Export OCR Text...") {
                exportOCRText()
            }
            
            Button("Copy OCR Text") {
                copyOCRText()
            }
            
            Button("Export Frame with OCR...") {
                exportFrameWithOCR()
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
    }
    
    private func saveFrame() {
        // TODO: Get current frame from buffer
        // For now, placeholder
    }
    
    private func copyFrame() {
        // TODO: Get current frame and copy
    }
    
    private func exportOCRText() {
        // TODO: Export OCR text to file
    }
    
    private func copyOCRText() {
        // TODO: Copy OCR text to clipboard
    }
    
    private func exportFrameWithOCR() {
        // TODO: Export composite image
    }
}
