//
//  AppMenu.swift
//  SharpStream
//
//  Menu bar commands and menu items
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppMenu: Commands {
    @ObservedObject var appState: AppState
    @State private var showingOpenFileDialog = false
    @AppStorage("copyCommandMode") private var copyCommandModeRaw: String = CopyCommandMode.ocrText.rawValue

    private var copyCommandMode: CopyCommandMode {
        CopyCommandMode(rawValue: copyCommandModeRaw) ?? .ocrText
    }
    
    var body: some Commands {
        // File Menu
        CommandMenu("File") {
            // Open File
            Button("Open File...") {
                openFile()
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Divider()
            
            // Recent Streams
            Menu("Open Recent") {
                let recentStreams = appState.streamDatabase.getRecentStreams(limit: 10)
                if recentStreams.isEmpty {
                    Text("No recent streams")
                        .disabled(true)
                } else {
                    ForEach(recentStreams) { recent in
                        Button(recent.url) {
                            openRecentStream(recent.url)
                        }
                    }
                    
                    Divider()
                    
                    Button("Clear Recent") {
                        appState.streamDatabase.clearRecentStreams()
                        NotificationCenter.default.post(name: .recentStreamsUpdated, object: nil)
                    }
                }
            }
            
            Divider()
            
            // Saved Streams (all saved streams)
            Menu("Saved Streams") {
                let allStreams = appState.streamDatabase.getAllStreams()
                if allStreams.isEmpty {
                    Text("No saved streams")
                        .disabled(true)
                } else {
                    ForEach(allStreams) { stream in
                        Button(stream.name) {
                            appState.streamManager.connect(to: stream)
                        }
                    }
                }
            }
            
            Divider()
            
            // New Stream
            Button("New Stream...") {
                showNewStreamDialog()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Save Current Stream...") {
                saveCurrentStream()
            }
            .disabled(appState.currentStream == nil)
            
            Divider()
            
            // Export options
            Menu("Export") {
                Button("Save Current Frame...") {
                    exportCurrentFrame()
                }
                .keyboardShortcut("e", modifiers: .command)
                
                Button("Export OCR Text...") {
                    exportOCRText()
                }
                
                Button("Export Frame with OCR...") {
                    exportFrameWithOCR()
                }
            }
            
            Divider()
            
            // Close
            Button("Close") {
                NSApplication.shared.keyWindow?.close()
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        
        // Edit Menu
        CommandMenu("Edit") {
            Button("Copy") {
                copyToClipboard()
            }
            .keyboardShortcut("c", modifiers: .command)
            
            Button("Paste Stream URL") {
                pasteStreamURL()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        
        // View Menu
        CommandMenu("View") {
            Button("Toggle Sidebar") {
                toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            
            Divider()

            Button("Show Statistics") {
                showStatisticsWindow()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()
            
            Button("Enter Fullscreen") {
                enterFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        
        // Playback Menu
        CommandMenu("Playback") {
            Button("Play/Pause") {
                togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            
            Divider()
            
            Button("Rewind 10s") {
                seekBackward()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            
            Button("Forward 10s") {
                seekForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            
            Divider()
            
            Button("Frame Backward") {
                stepFrameBackward()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            
            Button("Frame Forward") {
                stepFrameForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            
            Divider()
            
            Button("Smart Pause") {
                performSmartPause()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Smart Pause (Cmd+Space)") {
                performSmartPause()
            }
            .keyboardShortcut(.space, modifiers: [.command])
            
            Divider()
            
            Menu("Playback Speed") {
                Button("0.25x") { setSpeed(0.25) }
                Button("0.5x") { setSpeed(0.5) }
                Button("1x") { setSpeed(1.0) }
                Button("1.5x") { setSpeed(1.5) }
                Button("2x") { setSpeed(2.0) }
            }
        }
        
        // Window Menu
        CommandGroup(replacing: .windowSize) {
            Button("Zoom") {
                zoomWindow()
            }
        }
        
        CommandGroup(after: .windowArrangement) {
            Button("Minimize") {
                NSApplication.shared.keyWindow?.miniaturize(nil)
            }
            .keyboardShortcut("m", modifiers: .command)
        }
    }
    
    // MARK: - Actions
    
    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.message = "Select a video file to open"
        
        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            
            let fileURL = url.absoluteString
            let protocolType = StreamProtocol.detect(from: fileURL)
            let stream = SavedStream(name: url.lastPathComponent, url: fileURL, protocolType: protocolType)
            
            appState.streamManager.connect(to: stream)
        }
    }
    
    private func openRecentStream(_ url: String) {
        let protocolType = StreamProtocol.detect(from: url)
        let stream = SavedStream(name: "Recent Stream", url: url, protocolType: protocolType)
        appState.streamManager.connect(to: stream)
    }
    
    private func showNewStreamDialog() {
        // This would show the stream configuration sheet
        // For now, trigger via notification or state
        NotificationCenter.default.post(name: NSNotification.Name("ShowNewStreamDialog"), object: nil)
    }

    private func saveCurrentStream() {
        NotificationCenter.default.post(name: .saveCurrentStreamRequested, object: nil)
    }
    
    private func exportCurrentFrame() {
        // Export current frame
        NotificationCenter.default.post(name: NSNotification.Name("ExportCurrentFrame"), object: nil)
    }
    
    private func exportOCRText() {
        NotificationCenter.default.post(name: NSNotification.Name("ExportOCRText"), object: nil)
    }
    
    private func exportFrameWithOCR() {
        NotificationCenter.default.post(name: NSNotification.Name("ExportFrameWithOCR"), object: nil)
    }
    
    private func copyToClipboard() {
        // Copy current OCR text or frame
        switch copyCommandMode {
        case .ocrText:
            NotificationCenter.default.post(name: .copyOCRTextNow, object: nil)
        case .frame:
            NotificationCenter.default.post(name: .copyFrameNow, object: nil)
        }
    }
    
    private func pasteStreamURL() {
        NotificationCenter.default.post(name: NSNotification.Name("PasteStreamURL"), object: nil)
    }
    
    private func toggleSidebar() {
        NotificationCenter.default.post(name: NSNotification.Name("ToggleSidebar"), object: nil)
    }

    private func showStatisticsWindow() {
        NotificationCenter.default.post(name: .showStatisticsWindowRequested, object: nil)
    }
    
    private func enterFullscreen() {
        NSApplication.shared.keyWindow?.toggleFullScreen(nil)
    }
    
    private func togglePlayPause() {
        NotificationCenter.default.post(name: NSNotification.Name("TogglePlayPause"), object: nil)
    }
    
    private func seekBackward() {
        NotificationCenter.default.post(name: NSNotification.Name("SeekBackward"), object: -10)
    }
    
    private func seekForward() {
        NotificationCenter.default.post(name: NSNotification.Name("SeekForward"), object: 10)
    }
    
    private func stepFrameBackward() {
        // Step frame backward - will be implemented when player is integrated
        NotificationCenter.default.post(name: NSNotification.Name("StepFrameBackward"), object: nil)
    }
    
    private func stepFrameForward() {
        // Step frame forward - will be implemented when player is integrated
        NotificationCenter.default.post(name: NSNotification.Name("StepFrameForward"), object: nil)
    }
    
    private func performSmartPause() {
        NotificationCenter.default.post(name: NSNotification.Name("SmartPause"), object: nil)
    }
    
    private func setSpeed(_ speed: Double) {
        // Set playback speed - will be implemented when player is integrated
        NotificationCenter.default.post(name: NSNotification.Name("SetPlaybackSpeed"), object: speed)
    }
    
    private func zoomWindow() {
        NSApplication.shared.keyWindow?.zoom(nil)
    }
}

extension Notification.Name {
    static let saveCurrentStreamRequested = Notification.Name("SaveCurrentStreamRequested")
    static let savedStreamsUpdated = Notification.Name("SavedStreamsUpdated")
    static let copyOCRTextNow = Notification.Name("CopyOCRTextNow")
    static let copyFrameNow = Notification.Name("CopyFrameNow")
    static let quickSaveFrame = Notification.Name("QuickSaveFrame")
    static let showStatisticsWindowRequested = Notification.Name("ShowStatisticsWindowRequested")
}
