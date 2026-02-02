//
//  MainWindow.swift
//  SharpStream
//
//  Primary video player window
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var showStreamList = true
    @State private var isFullscreen = false
    @AppStorage("windowWidth") private var savedWidth: Double = 1200
    @AppStorage("windowHeight") private var savedHeight: Double = 800
    @State private var observerTokens: [NSObjectProtocol] = []
    
    var body: some View {
        HSplitView {
            if showStreamList {
                StreamListView()
                    .frame(minWidth: 250, idealWidth: 300)
            }
            
            VStack(spacing: 0) {
                // Video player area (handles drag and drop internally)
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
                .accessibilityIdentifier("pasteStreamToolbarButton")
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            
            ToolbarItem(placement: .automatic) {
                Button(action: { toggleFullscreen() }) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
        .onAppear {
            checkRecoveryData()
            restoreWindowState()
            setupWindowConstraints()
            if observerTokens.isEmpty {
                setupErrorNotifications()
                setupCommandNotifications()
            }
        }
        .onDisappear {
            removeObservers()
        }
        .frame(width: savedWidth, height: savedHeight)
        .frame(minWidth: 800, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            saveWindowState()
        }
        .background(WindowAccessor { window in
            if let window = window {
                setupWindowFrame(window: window)
            }
        })
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
                await MainActor.run {
                    showRecoveryDialog(recoveryData: recoveryData)
                }
            }
        }
    }
    
    private func showRecoveryDialog(recoveryData: BufferRecoveryData) {
        let alert = NSAlert()
        alert.messageText = "Resume Previous Stream?"
        alert.informativeText = "SharpStream detected an interrupted stream. Would you like to resume?"
        
        if let streamURL = recoveryData.streamURL {
            alert.informativeText += "\n\nStream: \(streamURL)"
        }
        
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Resume stream
            if let url = recoveryData.streamURL {
                let protocolType = StreamProtocol.detect(from: url)
                let stream = SavedStream(name: "Recovered Stream", url: url, protocolType: protocolType)
                appState.streamManager.connect(to: stream)
            }
        } else {
            // Clear recovery data
            Task {
                await appState.bufferManager.clearRecoveryData()
            }
        }
    }
    
    private func toggleFullscreen() {
        isFullscreen.toggle()
        
        // Get the window and toggle fullscreen
        if let window = NSApplication.shared.windows.first {
            window.toggleFullScreen(nil)
        }
    }
    
    private func saveWindowState() {
        // Only save window size (position is not persisted)
        if let window = NSApplication.shared.windows.first {
            savedWidth = Double(window.frame.width)
            savedHeight = Double(window.frame.height)
        }
    }
    
    private func restoreWindowState() {
        // Window size is restored via @AppStorage in frame modifier (line 64)
        // Position is not persisted - window will use system default position
    }
    
    private func setupWindowConstraints() {
        // Ensure window doesn't extend beyond screen bounds
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                setupWindowFrame(window: window)
            }
        }
    }
    
    private func setupWindowFrame(window: NSWindow) {
        guard let screen = window.screen else { return }
        
        // Get screen frame excluding dock and menu bar
        let screenFrame = screen.visibleFrame
        let currentFrame = window.frame
        
        // Constrain window to visible frame
        var newFrame = currentFrame
        
        // Ensure window fits within visible area
        if currentFrame.maxX > screenFrame.maxX {
            newFrame.origin.x = screenFrame.maxX - currentFrame.width
        }
        if currentFrame.maxY > screenFrame.maxY {
            newFrame.origin.y = screenFrame.maxY - currentFrame.height
        }
        if currentFrame.minX < screenFrame.minX {
            newFrame.origin.x = screenFrame.minX
        }
        if currentFrame.minY < screenFrame.minY {
            newFrame.origin.y = screenFrame.minY
        }
        
        // Ensure minimum size
        if newFrame.width < 800 {
            newFrame.size.width = 800
        }
        if newFrame.height < 600 {
            newFrame.size.height = 600
        }
        
        // Don't resize if already correct
        if newFrame != currentFrame {
            window.setFrame(newFrame, display: true)
        }
        
        // Update saved values
        savedWidth = Double(newFrame.width)
        savedHeight = Double(newFrame.height)
    }
    
    private func setupErrorNotifications() {
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MPVError"),
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let message = userInfo["message"] as? String {
                print("🔔 Received MPV error notification: \(message)")
                let alert = NSAlert()
                alert.messageText = "Playback Error"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        observerTokens.append(token)
    }

    private func setupCommandNotifications() {
        let center = NotificationCenter.default

        let pasteToken = center.addObserver(
            forName: NSNotification.Name("PasteStreamURL"),
            object: nil,
            queue: .main
        ) { _ in
            self.pasteStreamURL()
        }
        observerTokens.append(pasteToken)

        let sidebarToken = center.addObserver(
            forName: NSNotification.Name("ToggleSidebar"),
            object: nil,
            queue: .main
        ) { _ in
            self.showStreamList.toggle()
        }
        observerTokens.append(sidebarToken)
    }

    private func removeObservers() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}

struct VideoPlayerView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDragOver = false

    var body: some View {
        let streamManager = appState.streamManager
        let connectionState = streamManager.connectionState

        return ZStack {
            // MPVKit video player
            if connectionState == .disconnected {
                Rectangle()
                    .fill(isDragOver ? Color.gray.opacity(0.3) : Color.black)
                    .overlay(
                        VStack(spacing: 16) {
                            if isDragOver {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 48))
                                    .foregroundColor(.blue)
                                Text("Drop Video File Here")
                                    .font(.headline)
                            } else {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No Stream Connected")
                                    .foregroundColor(.secondary)
                                Text("Drag and drop a video file (MP4, MKV, MOV, etc.) to play")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                    )
                    .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                        handleFileDrop(providers: providers)
                    }
            } else if connectionState == .connecting {
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        VStack {
                            ProgressView()
                            Text("Connecting...")
                                .foregroundColor(.secondary)
                                .padding(.top)
                        }
                    )
            } else {
                // Show MPVKit video view when connected
                MPVVideoView(player: streamManager.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                        handleFileDrop(providers: providers)
                    }
            }
            
            // OCR Overlay
            if appState.ocrEngine.isEnabled {
                OCROverlayView()
            }
        }
    }
    
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        print("📥 Drag and drop: Received \(providers.count) item(s)")
        
        for provider in providers {
            print("📥 Processing provider: \(provider.registeredTypeIdentifiers)")
            
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    if let error = error {
                        print("❌ Error loading file: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            self.showErrorAlert(title: "Error Loading File", message: error.localizedDescription)
                        }
                        return
                    }
                    
                    if let data = item as? Data,
                       let urlString = String(data: data, encoding: .utf8) {
                        print("📁 File URL from data: \(urlString)")
                        if let url = URL(string: urlString) {
                            DispatchQueue.main.async {
                                self.loadVideoFile(url: url)
                            }
                        } else {
                            print("❌ Failed to create URL from string: \(urlString)")
                            DispatchQueue.main.async {
                                self.showErrorAlert(title: "Invalid URL", message: "Could not parse file URL: \(urlString)")
                            }
                        }
                    } else if let url = item as? URL {
                        print("📁 File URL direct: \(url.absoluteString)")
                        DispatchQueue.main.async {
                            self.loadVideoFile(url: url)
                        }
                    } else {
                        print("❌ Unexpected item type: \(type(of: item))")
                        DispatchQueue.main.async {
                            self.showErrorAlert(title: "Unknown File Type", message: "Could not process dropped file")
                        }
                    }
                }
                return true
            } else {
                print("⚠️ Provider does not conform to public.file-url")
            }
        }
        return false
    }
    
    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func loadVideoFile(url: URL) {
        print("   - isFileURL: \(url.isFileURL)")
        print("   - path: \(url.path)")
        print("   - absoluteString: \(url.absoluteString)")
        
        // Ensure we have a file URL
        let fileURL: URL
        if url.isFileURL {
            fileURL = url
        } else if let urlString = url.absoluteString.removingPercentEncoding,
                   urlString.hasPrefix("file://") {
            fileURL = URL(string: urlString) ?? url
        } else {
            fileURL = URL(fileURLWithPath: url.path)
        }
        
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("❌ File does not exist at path: \(fileURL.path)")
            let alert = NSAlert()
            alert.messageText = "File Not Found"
            alert.informativeText = "The file does not exist at:\n\(fileURL.path)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Get file attributes
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            if let size = attributes[.size] as? Int64 {
                print("📊 File size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }
        }
        
        // Check if it's a video file
        let videoExtensions = ["mp4", "mkv", "mov", "avi", "m4v", "ts", "mts", "webm", "flv", "wmv", "mpg", "mpeg", "3gp"]
        let fileExtension = fileURL.pathExtension.lowercased()
        
        print("📝 File extension: .\(fileExtension)")
        
        guard videoExtensions.contains(fileExtension) else {
            print("❌ Unsupported file extension: .\(fileExtension)")
            let alert = NSAlert()
            alert.messageText = "Unsupported File Type"
            alert.informativeText = "Please drop a video file (MP4, MKV, MOV, AVI, TS, etc.)\n\nFile extension: .\(fileExtension)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Create a file:// URL string
        let fileURLString = "file://\(fileURL.path)"
        
        
        
        // Create stream and connect
        let protocolType = StreamProtocol.file
        let stream = SavedStream(
            name: fileURL.lastPathComponent,
            url: fileURLString,
            protocolType: protocolType
        )
        
        print("▶️ Connecting to stream: \(stream.name)")
        print("   URL: \(stream.url)")
        
        appState.streamManager.connect(to: stream)
        
        print("✅ Stream connection initiated")
    }
}
