//
//  MainWindow.swift
//  SharpStream
//
//  Primary video player window
//

import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var showStreamList = true
    @State private var isFullscreen = false
    
    var body: some View {
        HSplitView {
            if showStreamList {
                StreamListView()
                    .frame(minWidth: 250, idealWidth: 300)
            }
            
            VStack(spacing: 0) {
                // Video player area
                VideoPlayerView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Controls
                ControlsView()
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showStreamList.toggle() }) {
                    Image(systemName: "sidebar.left")
                }
            }
            
            ToolbarItem(placement: .automatic) {
                Button("Paste Stream URL") {
                    pasteStreamURL()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .onAppear {
            checkRecoveryData()
        }
    }
    
    private func pasteStreamURL() {
        let pasteboard = NSPasteboard.general
        guard let urlString = pasteboard.string(forType: .string),
              !urlString.isEmpty else {
            return
        }
        
        // Validate and add stream
        let result = StreamURLValidator.validate(urlString)
        if result.isValid {
            // Quick connect
            let protocolType = StreamProtocol.detect(from: urlString)
            let stream = SavedStream(name: "Quick Stream", url: urlString, protocolType: protocolType)
            appState.streamManager.connect(to: stream)
        }
    }
    
    private func checkRecoveryData() {
        Task {
            if let recoveryData = await appState.bufferManager.getRecoveryData() {
                // Show recovery dialog
                await MainActor.run {
                    // In production, show alert dialog
                    print("Recovery data found: \(recoveryData)")
                }
            }
        }
    }
}

struct VideoPlayerView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            // Placeholder for MPVKit player
            Rectangle()
                .fill(Color.black)
                .overlay(
                    VStack {
                        if appState.connectionState == .disconnected {
                            Text("No Stream Connected")
                                .foregroundColor(.secondary)
                        } else if appState.connectionState == .connecting {
                            ProgressView()
                            Text("Connecting...")
                                .foregroundColor(.secondary)
                        } else {
                            Text("Video Player")
                                .foregroundColor(.secondary)
                            Text("MPVKit integration pending")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                )
            
            // OCR Overlay
            if appState.ocrEngine.isEnabled {
                OCROverlayView()
            }
        }
    }
}
