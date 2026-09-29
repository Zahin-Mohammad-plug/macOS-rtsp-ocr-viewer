//
//  PreferencesView.swift
//  SharpStream
//
//  Settings window. Values are stored in UserDefaults; AppState observes
//  UserDefaults and applies them to the engines, so nothing here needs to be
//  "applied" manually or only takes effect after the window was opened.
//

import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(UserDefaultsKey.lookbackWindow) private var lookbackWindow: Double = 3.0
    @AppStorage(UserDefaultsKey.maxBufferLength) private var maxBufferLength: Int = 30
    @AppStorage(UserDefaultsKey.focusAlgorithm) private var focusAlgorithm: String = FocusAlgorithm.laplacian.rawValue
    @AppStorage(UserDefaultsKey.ocrEnabled) private var ocrEnabled: Bool = true
    @AppStorage(UserDefaultsKey.autoOCROnSmartPause) private var autoOCROnSmartPause: Bool = true
    @AppStorage(UserDefaultsKey.ocrLanguage) private var ocrLanguage: String = "en-US"
    @AppStorage(UserDefaultsKey.ocrRecognitionLevel) private var ocrRecognitionLevel: String = OCRRecognitionLevel.accurate.rawValue
    @AppStorage(UserDefaultsKey.ocrLanguageCorrection) private var ocrLanguageCorrection: Bool = false
    @AppStorage(UserDefaultsKey.ocrOverlayShowText) private var ocrOverlayShowText: Bool = true
    @AppStorage(UserDefaultsKey.ocrOverlayShowBoxes) private var ocrOverlayShowBoxes: Bool = true
    @AppStorage(UserDefaultsKey.defaultExportFormat) private var defaultExportFormat: String = "PNG"
    @AppStorage(UserDefaultsKey.defaultJPEGQuality) private var defaultJPEGQuality: Double = 0.8
    @AppStorage(UserDefaultsKey.use24HourClock) private var use24HourClock: Bool = false
    @AppStorage(FileAccessStore.quickSaveFolderPathKey) private var quickSaveFolderPath: String = ""

    var body: some View {
        TabView {
            Form {
                Section("Live Buffer") {
                    Picker("Rewind window", selection: $maxBufferLength) {
                        Text("10 minutes").tag(10)
                        Text("20 minutes").tag(20)
                        Text("30 minutes").tag(30)
                        Text("40 minutes").tag(40)
                    }
                    .onChange(of: maxBufferLength) { _, _ in
                        appState.streamManager.updateLiveBufferSettingsFromPreferences()
                    }
                    Text("How far back you can rewind a live stream. The compressed stream is kept in memory by the player, sized from the stream's bitrate (up to 2 GB).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Smart Pause") {
                    LabeledContent("Lookback window") {
                        HStack {
                            Slider(value: $lookbackWindow, in: 1...5, step: 0.5)
                            Text("\(lookbackWindow, specifier: "%.1f") s")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Picker("Sharpness metric", selection: $focusAlgorithm) {
                        ForEach(FocusAlgorithm.allCases, id: \.rawValue) { algorithm in
                            Text(algorithm.displayName).tag(algorithm.rawValue)
                        }
                    }
                    Toggle("Recognize text after Smart Pause", isOn: $autoOCROnSmartPause)
                }

                Section("Display") {
                    Toggle("Use 24-hour time", isOn: $use24HourClock)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Text Recognition") {
                    Toggle("Enable text recognition", isOn: $ocrEnabled)
                    Picker("Accuracy", selection: $ocrRecognitionLevel) {
                        Text("Fast").tag(OCRRecognitionLevel.fast.rawValue)
                        Text("Accurate").tag(OCRRecognitionLevel.accurate.rawValue)
                    }
                    TextField("Languages", text: $ocrLanguage, prompt: Text("en-US, de-DE"))
                        .help("Comma-separated language codes. Leave empty to detect automatically.")
                    Toggle("Language correction", isOn: $ocrLanguageCorrection)
                        .help("Better for sentences; turn off for plates, codes and IDs.")
                }

                Section("Overlay") {
                    Toggle("Outline recognized text", isOn: $ocrOverlayShowBoxes)
                    Toggle("Show recognized text on hover", isOn: $ocrOverlayShowText)
                }
                .disabled(!ocrEnabled)
            }
            .formStyle(.grouped)
            .tabItem { Label("Text", systemImage: "text.viewfinder") }

            Form {
                Section("Quick Save") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(quickSaveFolderPath.isEmpty ? "Downloads" : (quickSaveFolderPath as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { appState.chooseQuickSaveFolder() }
                            if !quickSaveFolderPath.isEmpty {
                                Button("Reset") { appState.resetQuickSaveFolder() }
                            }
                        }
                    }
                }

                Section("Frame Export") {
                    Picker("Quick save format", selection: $defaultExportFormat) {
                        Text("PNG").tag("PNG")
                        Text("JPEG").tag("JPEG")
                    }
                    if defaultExportFormat == "JPEG" {
                        LabeledContent("JPEG quality") {
                            HStack {
                                Slider(value: $defaultJPEGQuality, in: 0.1...1.0, step: 0.1)
                                Text("\(Int(defaultJPEGQuality * 100))%")
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Export", systemImage: "square.and.arrow.down") }

            Form {
                Section("Keyboard Shortcuts") {
                    ShortcutRow(name: "Play / Pause", shortcut: "Space")
                    ShortcutRow(name: "Seek −5 s / +5 s (paused file: step a frame)", shortcut: "← / →")
                    ShortcutRow(name: "Seek −10 s / +10 s", shortcut: "⌘← / ⌘→  or  ⌥⌘← / ⌥⌘→")
                    ShortcutRow(name: "Previous / next frame", shortcut: ", / .")
                    ShortcutRow(name: "Smart Pause", shortcut: "⌘S")
                    ShortcutRow(name: "Recognize Text", shortcut: "⌘R")
                    ShortcutRow(name: "Copy Recognized Text", shortcut: "⇧⌘C")
                    ShortcutRow(name: "Copy Frame", shortcut: "⌥⌘C")
                    ShortcutRow(name: "Jump to Live", shortcut: "⌘L")
                    ShortcutRow(name: "Open URL from Clipboard", shortcut: "⇧⌘V")
                    ShortcutRow(name: "Dismiss analyzed frame", shortcut: "Esc")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 460)
    }
}

struct ShortcutRow: View {
    let name: String
    let shortcut: String

    var body: some View {
        LabeledContent(name) {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
