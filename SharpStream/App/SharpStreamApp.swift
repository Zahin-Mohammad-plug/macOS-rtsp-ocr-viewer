//
//  SharpStreamApp.swift
//  SharpStream
//
//  Created on macOS 14.0+
//

import SwiftUI
import Combine
import os.log

#if canImport(Libmpv)
import Libmpv
#endif

@main
struct SharpStreamApp: App {
    @StateObject private var appState = AppState()
    
    private static let logger = Logger(subsystem: "com.sharpstream", category: "app")
    
    init() {
        
        // Force logging to console AND unified logging
        print("🚀 ========================================")
        Self.logger.info("🚀 SharpStream App Starting")
        print("🚀 SharpStream App Starting")
        print("🚀 ========================================")
        
        // Test Libmpv availability at compile time (this is the actual C API module)
        #if canImport(Libmpv)
        Self.logger.info("✅ Libmpv: canImport(Libmpv) = TRUE")
        print("✅ Libmpv: canImport(Libmpv) = TRUE")
        print("✅ Libmpv module is available - C API accessible")
        #else
        Self.logger.error("❌ Libmpv: canImport(Libmpv) = FALSE - MODULE NOT FOUND")
        print("❌ Libmpv: canImport(Libmpv) = FALSE")
        print("   The Libmpv module is not available at compile time")
        print("   This means the Swift compiler cannot find the Libmpv module")
        print("   SOLUTIONS:")
        print("   1. In Xcode: File > Packages > Reset Package Caches")
        print("   2. Then: File > Packages > Resolve Package Versions")
        print("   3. Clean build: Product > Clean Build Folder (⇧⌘K)")
        print("   4. Rebuild: Product > Build (⌘B)")
        print("   5. Check that MPVKit package and Libmpv are properly linked")
        #endif
        
        print("📝 App initialization complete")
        Self.logger.info("📝 App initialization complete")
    }
    
    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppMenu(appState: appState)
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    // Allow multiple windows if needed
                }
                .keyboardShortcut("n")
            }
        }

        Window("Statistics", id: "statistics") {
            StatisticsWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 420, height: 680)
        
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
    @Published var currentOCRResult: OCRResult?
    @Published var lastSmartPauseDiagnostics: SmartPauseDiagnostics?

    let streamManager = StreamManager()
    let bufferManager = BufferManager()
    let focusScorer = FocusScorer()
    let ocrEngine = OCREngine()
    let exportManager = ExportManager()
    let streamDatabase = StreamDatabase()
    let performanceMonitor = PerformanceMonitor()
    let keyboardShortcuts = KeyboardShortcuts()
    lazy var smartPauseCoordinator = SmartPauseCoordinator(
        focusScorer: focusScorer,
        bufferManager: bufferManager,
        ocrEngine: ocrEngine
    )

    private var cancellables = Set<AnyCancellable>()
    private var statsUpdateTimer: Timer?

    init() {
        // Link stream manager to database and other managers
        streamManager.database = streamDatabase
        streamManager.bufferManager = bufferManager
        streamManager.focusScorer = focusScorer

        // Restore persisted OCR settings so copy/export behavior is available immediately.
        ocrEngine.isEnabled = UserDefaults.standard.bool(forKey: "ocrEnabled")
        if let storedLanguage = UserDefaults.standard.string(forKey: "ocrLanguage"),
           !storedLanguage.isEmpty {
            ocrEngine.languages = [storedLanguage]
        }

        // Subscribe to StreamManager changes and forward to AppState
        streamManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.connectionState = newState
                self?.isConnected = (newState == .connected)
            }
            .store(in: &cancellables)

        streamManager.$currentStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStream in
                self?.currentStream = newStream
            }
            .store(in: &cancellables)

        // Start performance monitoring
        performanceMonitor.startMonitoring()

        // Update stats periodically
        startStatsUpdateTimer()
    }

    deinit {
        statsUpdateTimer?.invalidate()
        statsUpdateTimer = nil
        performanceMonitor.stopMonitoring()
    }
    
    private func startStatsUpdateTimer() {
        statsUpdateTimer?.invalidate()
        statsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
            streamManager.updateSmartPauseQoS(
                cpuUsage: stats.cpuUsage,
                memoryPressure: stats.memoryPressure
            )
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)
    
    // Helper for comparison
    func isEqual(to other: ConnectionState) -> Bool {
        return self == other
    }
}
