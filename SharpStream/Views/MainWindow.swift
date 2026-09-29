//
//  MainWindow.swift
//  SharpStream
//
//  Primary player window: stream library sidebar, video + controls, and an
//  inspector column with recognized text.
//
//  Window size/position are left to AppKit/SwiftUI state restoration; the view
//  only declares minimum sizes.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var streamManager: StreamManager
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var saveDraft: SavedStream?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            StreamListView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } detail: {
            PlayerDetailView()
                .inspector(isPresented: $appState.showOCRInspector) {
                    OCRInspectorView()
                        .inspectorColumnWidth(min: 220, ideal: 280, max: 440)
                }
        }
        .frame(minWidth: 720, minHeight: 460)
        .navigationTitle(streamManager.currentStream?.name ?? "SharpStream")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.pasteStreamURL()
                } label: {
                    Label("Open URL from Clipboard", systemImage: "link.badge.plus")
                }
                .help("Open the stream URL on the clipboard (⇧⌘V)")
                .accessibilityIdentifier("pasteStreamToolbarButton")

                Button {
                    appState.presentOpenFilePanel()
                } label: {
                    Label("Open File", systemImage: "folder")
                }
                .help("Open a video file (⌘O)")

                Button {
                    openWindow(id: "statistics")
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                .help("Show stream statistics (⌥⌘I)")

                Button {
                    appState.showOCRInspector.toggle()
                } label: {
                    Label("Text Panel", systemImage: "sidebar.right")
                }
                .help("Show or hide recognized text (⌥⌘T)")
            }
        }
        .background(WindowReporter { window in
            appState.registerPlayerWindow(window)
        })
        .task {
            // Let the window finish appearing before any modal prompt.
            try? await Task.sleep(nanoseconds: 300_000_000)
            appState.checkForRecoverableSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveCurrentStreamRequested)) { _ in
            prepareSaveDraft()
        }
        .sheet(item: $saveDraft) { draft in
            StreamConfigurationView(stream: draft) { configured in
                saveStream(configured)
                saveDraft = nil
            }
        }
    }

    private var subtitle: String {
        switch streamManager.connectionState {
        case .disconnected: return ""
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .error: return "Error"
        case .connected:
            switch streamManager.seekMode {
            case .liveBuffered: return "Live"
            case .absolute: return "File"
            case .disabled: return ""
            }
        }
    }

    private func prepareSaveDraft() {
        guard let current = streamManager.currentStream else { return }
        saveDraft = appState.streamDatabase.getStream(byURL: current.url)
            ?? SavedStream(name: current.name, url: current.url, protocolType: current.protocolType, lastUsed: Date())
    }

    private func saveStream(_ stream: SavedStream) {
        do {
            _ = try appState.streamDatabase.saveOrUpdateByURL(
                name: stream.name,
                url: stream.url,
                protocolType: stream.protocolType,
                lastUsed: Date()
            )
            NotificationCenter.default.post(name: .savedStreamsUpdated, object: nil)
            appState.showStatus("Saved “\(stream.name)” to the library.")
        } catch {
            appState.showStatus("Unable to save stream: \(error.localizedDescription)", isError: true)
        }
    }
}

struct PlayerDetailView: View {
    var body: some View {
        VStack(spacing: 0) {
            VideoPlayerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            Divider()
            ControlsView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("controlsContainer")
        }
    }
}

struct VideoPlayerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var streamManager: StreamManager
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Color.black

            if let player = streamManager.player {
                MPVVideoView(player: player)
                    .id(ObjectIdentifier(player))
                    .accessibilityIdentifier("videoSurface")
            }

            if let frame = appState.analyzedFrame {
                AnalyzedFrameOverlay(frame: frame)
            }

            connectionOverlay

            if streamManager.player == nil {
                EmptyPlayerView(isDropTargeted: isDropTargeted)
            }

            Group {
                if let busyText {
                    ProgressBadge(text: busyText)
                } else if let player = streamManager.player, streamManager.connectionState == .connected {
                    BufferingIndicator(player: player)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(12)

            if let message = appState.statusMessage {
                StatusToast(message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(message.id)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: appState.statusMessage)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.isFileURL {
                appState.openFile(url: url)
            } else {
                appState.connect(urlString: url.absoluteString)
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu {
            Button("Smart Pause") { appState.smartPause() }
            Button("Recognize Text") { appState.recognizeText() }
            Divider()
            Button("Copy Frame") { appState.copyFrame() }
            Button("Copy Recognized Text") { appState.copyOCRText() }
            Button("Save Frame As…") { appState.saveFrameAs() }
            Divider()
            Button("Show Statistics") { openWindow(id: "statistics") }
        }
    }

    private var busyText: String? {
        if appState.isPerformingSmartPause { return "Finding sharpest frame…" }
        if appState.isRecognizingText { return "Recognizing text…" }
        return nil
    }

    @ViewBuilder
    private var connectionOverlay: some View {
        switch streamManager.connectionState {
        case .connecting:
            ConnectionCard(text: "Connecting…", showsProgress: true)
        case .reconnecting:
            ConnectionCard(text: "Reconnecting (attempt \(max(streamManager.reconnectAttempt, 1)))…", showsProgress: true)
        case .error(let message):
            ConnectionCard(text: message, showsProgress: false, isError: true) {
                if let stream = streamManager.currentStream {
                    Button("Retry") { appState.connect(to: stream) }
                }
                Button("Close") { appState.disconnect() }
            }
        case .connected, .disconnected:
            EmptyView()
        }
    }
}

private struct EmptyPlayerView: View {
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "play.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text(isDropTargeted ? "Drop to Play" : "No Stream Connected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("noStreamLabel")
            Text("Pick a stream in the sidebar, paste a URL (⇧⌘V), or drop a video file here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .environment(\.colorScheme, .dark)
    }
}

private struct ConnectionCard<Actions: View>: View {
    let text: String
    let showsProgress: Bool
    var isError = false
    @ViewBuilder var actions: () -> Actions

    init(text: String, showsProgress: Bool, isError: Bool = false, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.text = text
        self.showsProgress = showsProgress
        self.isError = isError
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
            }
            Text(text)
                .accessibilityIdentifier("connectionOverlayText")
                .multilineTextAlignment(.center)
                .lineLimit(4)
            HStack { actions() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(24)
    }
}

private struct ProgressBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct StatusToast: View {
    let message: StatusMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? Color.orange : Color.green)
            Text(message.text)
                .lineLimit(2)
                .accessibilityIdentifier("controlStatusMessage")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}

/// Reports the hosting NSWindow once it's available.
struct WindowReporter: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {}

    final class ReporterView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
