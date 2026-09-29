//
//  AppMenu.swift
//  SharpStream
//
//  Menu bar commands. Items extend the standard File/Edit/View menus instead of
//  creating duplicate top-level menus. Space and the arrow keys are handled by
//  AppState's key monitor (so text fields keep working); the menu items below
//  only carry modifier shortcuts.
//

import SwiftUI

struct AppMenu: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private var hasPlayer: Bool { appState.hasPlayer }
    private var seekMode: SeekMode { appState.currentSeekMode }

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Stream…") {
                NotificationCenter.default.post(name: .showNewStreamSheet, object: nil)
            }
            .keyboardShortcut("n")

            Button("Open File…") {
                appState.presentOpenFilePanel()
            }
            .keyboardShortcut("o")

            Button("Open URL from Clipboard") {
                appState.pasteStreamURL()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Menu("Open Recent") {
                // Depend on the library revision so this list rebuilds after edits.
                let _ = appState.libraryRevision
                let recents = appState.streamDatabase.getRecentStreams(limit: 10)
                if recents.isEmpty {
                    Text("No Recent Streams")
                } else {
                    ForEach(recents) { recent in
                        Button(StreamURLRedactor.redacted(recent.url)) {
                            appState.connect(urlString: recent.url)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        appState.streamDatabase.clearRecentStreams()
                        NotificationCenter.default.post(name: .recentStreamsUpdated, object: nil)
                    }
                }
            }

            Menu("Saved Streams") {
                let _ = appState.libraryRevision
                let saved = appState.streamDatabase.getAllStreams()
                if saved.isEmpty {
                    Text("No Saved Streams")
                } else {
                    ForEach(saved) { stream in
                        Button(stream.name) { appState.connect(to: stream) }
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Stream to Library…") {
                NotificationCenter.default.post(name: .saveCurrentStreamRequested, object: nil)
            }
            .disabled(!appState.hasCurrentStream)

            Button("Disconnect") {
                appState.disconnect()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!hasPlayer)

            Divider()

            Button("Save Frame As…") { appState.saveFrameAs() }
                .keyboardShortcut("e")
                .disabled(!hasPlayer)
            Button("Quick Save Frame") { appState.quickSaveFrame() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!hasPlayer)
            Button("Export Recognized Text…") { appState.exportOCRText() }
                .disabled(appState.currentOCRResult == nil)
            Button("Export Frame with Text Boxes…") { appState.exportFrameWithOCR() }
                .disabled(!hasPlayer)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Recognized Text") { appState.copyOCRText() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasPlayer)
            Button("Copy Frame") { appState.copyFrame() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasPlayer)
        }

        CommandGroup(after: .sidebar) {
            Button(appState.showOCRInspector ? "Hide Text Panel" : "Show Text Panel") {
                appState.showOCRInspector.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])

            Button("Show Statistics") {
                openWindow(id: "statistics")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Playback") {
            Button("Play / Pause   (Space)") { appState.togglePlayPause() }
                .disabled(!hasPlayer)

            Divider()

            Button("Back 10 Seconds") { appState.seek(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!seekMode.allowsRelativeSeek)
            Button("Forward 10 Seconds") { appState.seek(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!seekMode.allowsRelativeSeek)
            Button("Previous Frame   ( , )") { appState.stepFrame(backward: true) }
                .disabled(seekMode != .absolute)
            Button("Next Frame   ( . )") { appState.stepFrame(backward: false) }
                .disabled(seekMode != .absolute)
            Button("Jump to Live") { appState.jumpToLive() }
                .keyboardShortcut("l")
                .disabled(seekMode != .liveBuffered)

            Divider()

            Button("Smart Pause") { appState.smartPause() }
                .keyboardShortcut("s")
                .disabled(!hasPlayer)
            Button("Recognize Text") { appState.recognizeText() }
                .keyboardShortcut("r")
                .disabled(!hasPlayer)

            Divider()

            Menu("Speed") {
                ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                    Button(PlaybackSpeed.label(speed)) { appState.setSpeed(speed) }
                }
            }
            .disabled(!hasPlayer)
        }
    }
}

enum PlaybackSpeed {
    static let options: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0]

    static func label(_ speed: Double) -> String {
        speed == floor(speed) ? "\(Int(speed))×" : "\(speed)×"
    }
}

extension Notification.Name {
    static let saveCurrentStreamRequested = Notification.Name("SaveCurrentStreamRequested")
    static let savedStreamsUpdated = Notification.Name("SavedStreamsUpdated")
    static let showNewStreamSheet = Notification.Name("ShowNewStreamSheet")
}
