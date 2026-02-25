//
//  PreferencesView.swift
//  SharpStream
//
//  Settings window
//

import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("lookbackWindow") private var lookbackWindow: Double = 3.0
    @AppStorage("maxBufferLength") private var maxBufferLength: Int = 30
    @AppStorage("ramBufferSize") private var ramBufferSizeRaw: String = BufferSizePreset.medium.rawValue
    @AppStorage("focusAlgorithm") private var focusAlgorithm: String = "Laplacian"
    @AppStorage("ocrEnabled") private var ocrEnabled: Bool = false
    @AppStorage("autoOCROnSmartPause") private var autoOCROnSmartPause: Bool = true
    @AppStorage("ocrLanguage") private var ocrLanguage: String = "en-US"
    @AppStorage("ocrOverlayShowText") private var ocrOverlayShowText: Bool = false
    @AppStorage("ocrOverlayShowBoxes") private var ocrOverlayShowBoxes: Bool = false
    @AppStorage("defaultExportFormat") private var defaultExportFormat: String = "PNG"
    @AppStorage("defaultJPEGQuality") private var defaultJPEGQuality: Double = 0.8
    @AppStorage("use24HourClock") private var use24HourClock: Bool = false
    @AppStorage("showSuccessAlerts") private var showSuccessAlerts: Bool = false
    
    private var ramBufferSize: BufferSizePreset {
        get { BufferSizePreset(rawValue: ramBufferSizeRaw) ?? .medium }
        set { ramBufferSizeRaw = newValue.rawValue }
    }
    
    var body: some View {
        TabView {
            // General Settings
            Form {
                Section("Buffer Settings") {
                    Picker("RAM Buffer Size", selection: Binding(
                        get: { BufferSizePreset(rawValue: ramBufferSizeRaw) ?? .medium },
                        set: { ramBufferSizeRaw = $0.rawValue }
                    )) {
                        Text("Low (1s, ~70 MB)").tag(BufferSizePreset.low)
                        Text("Medium (3s, ~200 MB)").tag(BufferSizePreset.medium)
                        Text("High (5s, ~350 MB)").tag(BufferSizePreset.high)
                    }
                    .onChange(of: ramBufferSizeRaw) { _, newValue in
                        if let preset = BufferSizePreset(rawValue: newValue) {
                            Task {
                                await appState.bufferManager.setBufferSizePreset(preset)
                            }
                        }
                    }
                    
                    Picker("Maximum Buffer Length", selection: $maxBufferLength) {
                        Text("20 minutes").tag(20)
                        Text("30 minutes").tag(30)
                        Text("40 minutes").tag(40)
                    }
                    .onChange(of: maxBufferLength) { _, newValue in
                        // Update buffer manager max duration
                        Task {
                            await appState.bufferManager.setMaxBufferDuration(TimeInterval(newValue * 60))
                        }
                        appState.streamManager.updateLiveBufferSettingsFromPreferences()
                    }
                }
                
                Section("Smart Pause") {
                    Slider(value: $lookbackWindow, in: 1...5, step: 0.5) {
                        Text("Lookback Window")
                    } minimumValueLabel: {
                        Text("1s")
                    } maximumValueLabel: {
                        Text("5s")
                    }
                    
                    Text("\(lookbackWindow, specifier: "%.1f") seconds")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    
                    Toggle("Auto-OCR on Smart Pause", isOn: $autoOCROnSmartPause)
                        .onChange(of: autoOCROnSmartPause) { _, newValue in
                            // This preference is used in ControlsView.performSmartPause()
                            // No direct action needed here, just stored for use
                        }
                }

                Section("Display") {
                    Toggle("Use 24-hour time", isOn: $use24HourClock)
                }
            }
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            
            // OCR Settings
            Form {
                Section("OCR Settings") {
                    Toggle("Enable OCR", isOn: $ocrEnabled)
                        .onChange(of: ocrEnabled) { _, newValue in
                            appState.ocrEngine.isEnabled = newValue
                        }

                    Toggle("Show OCR Text Overlay", isOn: $ocrOverlayShowText)
                    Toggle("Show OCR Bounding Boxes", isOn: $ocrOverlayShowBoxes)
                    
                    Picker("Recognition Level", selection: Binding(
                        get: { appState.ocrEngine.recognitionLevel },
                        set: { appState.ocrEngine.recognitionLevel = $0 }
                    )) {
                        Text("Fast").tag(OCRRecognitionLevel.fast)
                        Text("Accurate").tag(OCRRecognitionLevel.accurate)
                    }
                    
                    TextField("Language", text: $ocrLanguage)
                        .help("Language code (e.g., en-US, fr-FR)")
                        .onChange(of: ocrLanguage) { _, newValue in
                            // Update OCR engine languages
                            appState.ocrEngine.languages = [newValue]
                        }
                }
            }
            .tabItem {
                Label("OCR", systemImage: "text.viewfinder")
            }
            
            // Focus Scoring
            Form {
                Section("Focus Algorithm") {
                    Picker("Algorithm", selection: Binding(
                        get: { FocusAlgorithm(rawValue: focusAlgorithm) ?? .laplacian },
                        set: { focusAlgorithm = $0.rawValue }
                    )) {
                        ForEach(FocusAlgorithm.allCases, id: \.self) { algo in
                            Text(algo.displayName).tag(algo)
                        }
                    }
                    .onChange(of: focusAlgorithm) { _, newValue in
                        if let algo = FocusAlgorithm(rawValue: newValue) {
                            appState.focusScorer.setAlgorithm(algo)
                        }
                    }
                }
            }
            .tabItem {
                Label("Focus", systemImage: "camera.filters")
            }
            
            // Export Settings
            Form {
                Section("Export Format") {
                    Picker("Default Format", selection: $defaultExportFormat) {
                        Text("PNG").tag("PNG")
                        Text("JPEG").tag("JPEG")
                    }
                    .help("Default format for frame exports")
                    
                    if defaultExportFormat == "JPEG" {
                        Slider(value: $defaultJPEGQuality, in: 0.1...1.0, step: 0.1) {
                            Text("JPEG Quality")
                        } minimumValueLabel: {
                            Text("Low")
                        } maximumValueLabel: {
                            Text("High")
                        }
                        
                        Text("\(defaultJPEGQuality, specifier: "%.1f")")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Section("Export Alerts") {
                    Toggle("Show success alerts", isOn: $showSuccessAlerts)
                }
            }
            .tabItem {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            
            // Keyboard Shortcuts
            Form {
                Section("Keyboard Shortcuts") {
                    VStack(alignment: .leading, spacing: 12) {
                        ShortcutRow(name: "Play/Pause", shortcut: "Space")
                        ShortcutRow(name: "Rewind 10s", shortcut: "⌘←")
                        ShortcutRow(name: "Forward 10s", shortcut: "⌘→")
                        ShortcutRow(name: "Frame Backward", shortcut: "←")
                        ShortcutRow(name: "Frame Forward", shortcut: "→")
                        ShortcutRow(name: "Smart Pause", shortcut: "⌘Space, ⌘S")
                        ShortcutRow(name: "Paste Stream URL", shortcut: "⌘⇧N")
                        ShortcutRow(name: "Toggle Fullscreen", shortcut: "⌘⌃F")
                    }
                    
                    Text("Keyboard shortcuts customization coming soon")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .tabItem {
                Label("Shortcuts", systemImage: "keyboard")
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            // Initialize preferences from app state
            if let algo = FocusAlgorithm(rawValue: focusAlgorithm) {
                appState.focusScorer.setAlgorithm(algo)
            }
            appState.ocrEngine.isEnabled = ocrEnabled
            appState.ocrEngine.languages = [ocrLanguage]
        }
    }
}

struct ShortcutRow: View {
    let name: String
    let shortcut: String
    
    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(shortcut)
                .foregroundColor(.secondary)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }
}
