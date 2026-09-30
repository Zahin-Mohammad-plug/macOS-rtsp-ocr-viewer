//
//  PreferencesView.swift
//  SharpStream
//
//  Settings window. Values are stored in UserDefaults; AppState observes
//  UserDefaults and applies them to the engines, so nothing here needs to be
//  "applied" manually or only takes effect after the window was opened.
//

import SwiftUI
import Vision

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            StreamSettings()
                .tabItem { Label("Streams", systemImage: "antenna.radiowaves.left.and.right") }
            SmartPauseSettings()
                .tabItem { Label("Smart Pause", systemImage: "scope") }
            TextRecognitionSettings()
                .tabItem { Label("Text", systemImage: "text.viewfinder") }
            ExportSettings()
                .tabItem { Label("Export", systemImage: "square.and.arrow.down") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(UserDefaultsKey.use24HourClock) private var use24HourClock = false
    @AppStorage(UserDefaultsKey.rememberRecentStreams) private var rememberRecentStreams = true

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Use 24-hour time on the live timeline", isOn: $use24HourClock)
            }

            Section {
                Toggle("Remember recently opened streams", isOn: $rememberRecentStreams)
                LabeledContent("Recent streams") {
                    Button("Clear Recent Streams") { appState.clearRecentStreams() }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Saved streams in the sidebar are kept either way.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Streams

private struct StreamSettings: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(UserDefaultsKey.rtspTransport) private var rtspTransport = MPVPlayerWrapper.Options.RTSPTransport.tcp.rawValue
    @AppStorage(UserDefaultsKey.hardwareDecoding) private var hardwareDecoding = true
    @AppStorage(UserDefaultsKey.autoReconnect) private var autoReconnect = true
    @AppStorage(UserDefaultsKey.maxBufferLength) private var maxBufferLength = 30

    var body: some View {
        Form {
            Section {
                Picker("RTSP transport", selection: $rtspTransport) {
                    Text("TCP (most reliable)").tag(MPVPlayerWrapper.Options.RTSPTransport.tcp.rawValue)
                    Text("UDP (lower latency)").tag(MPVPlayerWrapper.Options.RTSPTransport.udp.rawValue)
                    Text("Automatic").tag(MPVPlayerWrapper.Options.RTSPTransport.automatic.rawValue)
                }
                Toggle("Hardware video decoding", isOn: $hardwareDecoding)
                Toggle("Reconnect automatically when a stream drops", isOn: $autoReconnect)
            } header: {
                Text("Connection")
            } footer: {
                Text("Transport and decoding apply the next time a stream connects. Turn hardware decoding off if a stream shows corrupted or green frames.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Rewind window", selection: $maxBufferLength) {
                    Text("10 minutes").tag(10)
                    Text("20 minutes").tag(20)
                    Text("30 minutes").tag(30)
                    Text("40 minutes").tag(40)
                }
                .onChange(of: maxBufferLength) { _, _ in
                    appState.streamManager.updateLiveBufferSettingsFromPreferences()
                }
            } header: {
                Text("Live Rewind")
            } footer: {
                Text("How far back you can scrub a live stream. The compressed stream is kept in memory, sized from its bitrate (up to 2 GB).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Smart Pause

private struct SmartPauseSettings: View {
    @AppStorage(UserDefaultsKey.lookbackWindow) private var lookbackWindow = 3.0
    @AppStorage(UserDefaultsKey.smartPauseSamplingRate) private var samplingRate = SmartPauseSamplingTier.defaultTargetFPS
    @AppStorage(UserDefaultsKey.focusAlgorithm) private var focusAlgorithm = FocusAlgorithm.laplacian.rawValue
    @AppStorage(UserDefaultsKey.autoOCROnSmartPause) private var autoOCROnSmartPause = true
    @AppStorage(UserDefaultsKey.ocrEnabled) private var ocrEnabled = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Look back") {
                    HStack {
                        Slider(value: $lookbackWindow, in: 1...5, step: 0.5)
                        Text("\(lookbackWindow, specifier: "%.1f") s")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Sampling rate", selection: $samplingRate) {
                    Text("Standard (4 per second)").tag(4.0)
                    Text("High (8 per second)").tag(8.0)
                }
                Picker("Sharpness metric", selection: $focusAlgorithm) {
                    ForEach(FocusAlgorithm.allCases, id: \.rawValue) { algorithm in
                        Text(algorithm.displayName).tag(algorithm.rawValue)
                    }
                }
            } header: {
                Text("Frame Selection")
            } footer: {
                Text("Smart Pause (⌘S) pauses on the sharpest frame from the last few seconds. A higher sampling rate catches sharp moments that last only a frame or two (focus hunting, a shaky hand) at the cost of more CPU; it steps down automatically under load. Laplacian is the best default metric; the others can suit very low-contrast scenes.")
                    .foregroundStyle(.secondary)
            }

            Section("After Pausing") {
                Toggle("Recognize text in the selected frame", isOn: $autoOCROnSmartPause)
                    .disabled(!ocrEnabled)
                if !ocrEnabled {
                    Text("Text recognition is turned off in the Text tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Text recognition

private struct TextRecognitionSettings: View {
    @AppStorage(UserDefaultsKey.ocrEnabled) private var ocrEnabled = true
    @AppStorage(UserDefaultsKey.ocrLanguage) private var ocrLanguage = "en-US"
    @AppStorage(UserDefaultsKey.ocrRecognitionLevel) private var ocrRecognitionLevel = OCRRecognitionLevel.accurate.rawValue
    @AppStorage(UserDefaultsKey.ocrLanguageCorrection) private var ocrLanguageCorrection = false
    @AppStorage(UserDefaultsKey.ocrOverlayShowBoxes) private var ocrOverlayShowBoxes = true
    @AppStorage(UserDefaultsKey.ocrOverlayShowText) private var ocrOverlayShowText = true
    @AppStorage(UserDefaultsKey.autoShowTextPanel) private var autoShowTextPanel = true

    private static let supportedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    /// Stored value may be a legacy comma-separated list; keep it selectable.
    private var languageOptions: [String] {
        var options = Self.supportedLanguages
        if !ocrLanguage.isEmpty, !options.contains(ocrLanguage) {
            options.insert(ocrLanguage, at: 0)
        }
        return options
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable text recognition", isOn: $ocrEnabled)
            }

            Section {
                Picker("Language", selection: $ocrLanguage) {
                    Text("Automatic").tag("")
                    Divider()
                    ForEach(languageOptions, id: \.self) { code in
                        Text(Self.displayName(for: code)).tag(code)
                    }
                }
                Picker("Accuracy", selection: $ocrRecognitionLevel) {
                    Text("Accurate").tag(OCRRecognitionLevel.accurate.rawValue)
                    Text("Fast (upright text only)").tag(OCRRecognitionLevel.fast.rawValue)
                }
                Toggle("Language correction", isOn: $ocrLanguageCorrection)
            } header: {
                Text("Recognition")
            } footer: {
                Text("Leave language correction off for plates, codes and IDs; it helps with sentences. Fast mode can't read rotated or small text.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!ocrEnabled)

            Section("Results") {
                Toggle("Outline recognized text on the frame", isOn: $ocrOverlayShowBoxes)
                Toggle("Show the text when hovering an outline", isOn: $ocrOverlayShowText)
                    .disabled(!ocrOverlayShowBoxes)
                Toggle("Open the Text panel when text is found", isOn: $autoShowTextPanel)
            }
            .disabled(!ocrEnabled)
        }
        .formStyle(.grouped)
    }

    private static func displayName(for code: String) -> String {
        if code.contains(",") { return code }
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return "\(name) (\(code))"
    }
}

// MARK: - Export

private struct ExportSettings: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(UserDefaultsKey.defaultExportFormat) private var defaultExportFormat = "PNG"
    @AppStorage(UserDefaultsKey.defaultJPEGQuality) private var defaultJPEGQuality = 0.8
    @AppStorage(FileAccessStore.quickSaveFolderPathKey) private var quickSaveFolderPath = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(quickSaveFolderPath.isEmpty ? "Downloads" : (quickSaveFolderPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { appState.chooseQuickSaveFolder() }
                        if !quickSaveFolderPath.isEmpty {
                            Button("Use Downloads") { appState.resetQuickSaveFolder() }
                        }
                    }
                }
                Picker("Format", selection: $defaultExportFormat) {
                    Text("PNG (lossless)").tag("PNG")
                    Text("JPEG (smaller)").tag("JPEG")
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
            } header: {
                Text("Quick Save (⇧⌘E)")
            } footer: {
                Text("Save Frame As… (⌘E) always asks where to save and picks the format from the file name.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section("Playback") {
                ShortcutRow(name: "Play / Pause", shortcut: "Space")
                ShortcutRow(name: "Seek −5 s / +5 s (paused file: step a frame)", shortcut: "← / →")
                ShortcutRow(name: "Seek −10 s / +10 s", shortcut: "⌘← / ⌘→")
                ShortcutRow(name: "Previous / next frame", shortcut: ", / .")
                ShortcutRow(name: "Jump to Live", shortcut: "⌘L")
            }
            Section("Analysis") {
                ShortcutRow(name: "Smart Pause", shortcut: "⌘S")
                ShortcutRow(name: "Recognize Text", shortcut: "⌘R")
                ShortcutRow(name: "Dismiss analyzed frame", shortcut: "Esc")
                ShortcutRow(name: "Show / hide Text panel", shortcut: "⌥⌘T")
            }
            Section("Copy & Save") {
                ShortcutRow(name: "Copy recognized text", shortcut: "⇧⌘C")
                ShortcutRow(name: "Copy frame", shortcut: "⌥⌘C")
                ShortcutRow(name: "Save frame as…", shortcut: "⌘E")
                ShortcutRow(name: "Quick save frame", shortcut: "⇧⌘E")
            }
            Section("Streams") {
                ShortcutRow(name: "New stream", shortcut: "⌘N")
                ShortcutRow(name: "Open file", shortcut: "⌘O")
                ShortcutRow(name: "Open URL from clipboard", shortcut: "⇧⌘V")
                ShortcutRow(name: "Statistics", shortcut: "⌥⌘I")
            }
        }
        .formStyle(.grouped)
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
