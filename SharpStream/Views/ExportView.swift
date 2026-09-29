//
//  ExportView.swift
//  SharpStream
//
//  Copy/save/export overflow menu for the control bar.
//

import SwiftUI

struct ExportMenu: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var streamManager: StreamManager
    @Environment(\.openWindow) private var openWindow
    /// In the narrowest layout, speed and other playback items live here too.
    var includePlaybackItems = false

    private var hasPlayer: Bool { streamManager.player != nil }

    var body: some View {
        Menu {
            Section("Copy") {
                Button("Copy Recognized Text  ⇧⌘C") { appState.copyOCRText() }
                    .accessibilityIdentifier("quickCopyTextButton")
                Button("Copy Frame  ⌥⌘C") { appState.copyFrame() }
                    .accessibilityIdentifier("quickCopyFrameButton")
            }
            Section("Save") {
                Button("Save Frame As…  ⌘E") { appState.saveFrameAs() }
                Button("Quick Save Frame  ⇧⌘E") { appState.quickSaveFrame() }
                    .accessibilityIdentifier("quickSaveFrameButton")
                Button("Export Recognized Text…") { appState.exportOCRText() }
                Button("Export Frame with Text Boxes…") { appState.exportFrameWithOCR() }
            }
            if includePlaybackItems {
                Section("Playback") {
                    if streamManager.seekMode == .absolute {
                        Button("Previous Frame") { appState.stepFrame(backward: true) }
                        Button("Next Frame") { appState.stepFrame(backward: false) }
                    }
                    Menu("Speed") {
                        ForEach(PlaybackSpeed.options, id: \.self) { speed in
                            Button(PlaybackSpeed.label(speed)) { appState.setSpeed(speed) }
                        }
                    }
                }
            }
            Divider()
            Button("Show Statistics") { openWindow(id: "statistics") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!hasPlayer)
        .help("Copy, save and export")
        .accessibilityIdentifier("exportMenuButton")
    }
}
