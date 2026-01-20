//
//  SharpStreamApp.swift
//  SharpStream
//
//  Created on macOS 14.0+
//

import SwiftUI

@main
struct SharpStreamApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        
        Settings {
            PreferencesView()
                .environmentObject(appState)
        }
    }
}

// Global app state
class AppState: ObservableObject {
    @Published var currentStream: SavedStream?
    @Published var isConnected: Bool = false
    @Published var connectionState: ConnectionState = .disconnected
    
    let streamManager = StreamManager()
    let bufferManager = BufferManager()
    let focusScorer = FocusScorer()
    let ocrEngine = OCREngine()
    let exportManager = ExportManager()
    let streamDatabase = StreamDatabase()
    let performanceMonitor = PerformanceMonitor()
    let keyboardShortcuts = KeyboardShortcuts()
    
    init() {
        // Link stream manager to database
        streamManager.database = streamDatabase
        
        // Start performance monitoring
        performanceMonitor.startMonitoring()
        
        // Update stats periodically
        startStatsUpdateTimer()
    }
    
    private func startStatsUpdateTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.updateStats()
            }
        }
    }
    
    private func updateStats() async {
        var stats = streamManager.streamStats
        stats.cpuUsage = performanceMonitor.cpuUsage
        stats.gpuUsage = performanceMonitor.gpuUsage
        stats.memoryPressure = performanceMonitor.memoryPressure
        stats.currentFocusScore = focusScorer.getCurrentScore()
        stats.focusScoringFPS = focusScorer.getScoringFPS()
        stats.bufferDuration = await bufferManager.getBufferDuration()
        stats.ramBufferUsage = await bufferManager.getRAMBufferUsage()
        stats.diskBufferUsage = await bufferManager.getDiskBufferUsage()
        
        await MainActor.run {
            streamManager.streamStats = stats
        }
    }
}

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)
}
