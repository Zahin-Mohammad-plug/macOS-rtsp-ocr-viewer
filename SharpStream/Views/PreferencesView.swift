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
    @AppStorage("autoOCROnSmartPause") private var autoOCROnSmartPause: Bool = true
    @AppStorage("ocrLanguage") private var ocrLanguage: String = "en-US"
    
    private var ramBufferSize: BufferSizePreset {
        get { BufferSizePreset(rawValue: ramBufferSizeRaw) ?? .medium }
        set { ramBufferSizeRaw = newValue.rawValue }
    }
    
    var body: some View {
        TabView {
            // General Settings
            Form {
                Section("Buffer Settings") {
                    Picker("RAM Buffer Size", selection: $ramBufferSize) {
                        Text("Low (1s, ~70 MB)").tag(BufferSizePreset.low)
                        Text("Medium (3s, ~200 MB)").tag(BufferSizePreset.medium)
                        Text("High (5s, ~350 MB)").tag(BufferSizePreset.high)
                    }
                    
                    Picker("Maximum Buffer Length", selection: $maxBufferLength) {
                        Text("20 minutes").tag(20)
                        Text("30 minutes").tag(30)
                        Text("40 minutes").tag(40)
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
                }
            }
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            
            // OCR Settings
            Form {
                Section("OCR Settings") {
                    Toggle("Enable OCR", isOn: $appState.ocrEngine.isEnabled)
                    
                    Picker("Recognition Level", selection: $appState.ocrEngine.recognitionLevel) {
                        Text("Fast").tag(OCRRecognitionLevel.fast)
                        Text("Accurate").tag(OCRRecognitionLevel.accurate)
                    }
                    
                    TextField("Language", text: $ocrLanguage)
                        .help("Language code (e.g., en-US, fr-FR)")
                }
            }
            .tabItem {
                Label("OCR", systemImage: "text.viewfinder")
            }
            
            // Focus Scoring
            Form {
                Section("Focus Algorithm") {
                    Picker("Algorithm", selection: $focusAlgorithm) {
                        Text("Laplacian").tag("Laplacian")
                        Text("Tenengrad").tag("Tenengrad")
                        Text("Sobel").tag("Sobel")
                    }
                }
            }
            .tabItem {
                Label("Focus", systemImage: "camera.filters")
            }
            
            // Export Settings
            Form {
                Section("Export Format") {
                    // Export format preferences would go here
                    Text("Export settings")
                        .foregroundColor(.secondary)
                }
            }
            .tabItem {
                Label("Export", systemImage: "square.and.arrow.down")
            }
        }
        .frame(width: 500, height: 400)
        .onChange(of: ramBufferSize) { newValue in
            Task {
                await appState.bufferManager.bufferSizePreset = newValue
            }
        }
    }
}
