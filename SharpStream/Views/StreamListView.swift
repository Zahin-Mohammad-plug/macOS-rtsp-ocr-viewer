//
//  StreamListView.swift
//  SharpStream
//
//  Sidebar with saved streams
//

import SwiftUI

struct StreamListView: View {
    @EnvironmentObject var appState: AppState
    @State private var streams: [SavedStream] = []
    @State private var recentStreams: [RecentStream] = []
    @State private var showStreamSheet = false
    @State private var sheetStream: SavedStream?
    @State private var sheetUsesURLUpsert = true

    var body: some View {
        List {
            // Recent Streams Section
            if !recentStreams.isEmpty {
                Section("Recent") {
                    ForEach(recentStreams) { recent in
                        Button(action: {
                            connectToURL(recent.url)
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recent.url)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Used \(recent.useCount) times")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Connect") {
                                connectToURL(recent.url)
                            }
                            Button("Save to Saved Streams...") {
                                presentSaveSheet(for: streamFromRecent(recent), preferExistingByURL: true)
                            }
                        }
                    }
                }
            }

            // Saved Streams Section
            Section("Saved Streams") {
                ForEach(streams) { stream in
                    StreamRow(stream: stream) {
                        connectToStream(stream)
                    } onEdit: {
                        presentSaveSheet(for: stream, preferExistingByURL: false)
                    } onDelete: {
                        deleteStream(stream)
                    }
                    .contextMenu {
                        Button("Connect") {
                            connectToStream(stream)
                        }
                        Button("Edit") {
                            presentSaveSheet(for: stream, preferExistingByURL: false)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteStream(stream)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    sheetStream = nil
                    sheetUsesURLUpsert = true
                    showStreamSheet = true
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showStreamSheet) {
            StreamConfigurationView(stream: sheetStream) { stream in
                persistConfiguredStream(stream)
                showStreamSheet = false
            }
        }
        .onAppear {
            loadStreams()
            loadRecentStreams()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowNewStreamDialog"))) { _ in
            sheetStream = nil
            sheetUsesURLUpsert = true
            showStreamSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentStreamsUpdated)) { _ in
            loadRecentStreams()
        }
        .onReceive(NotificationCenter.default.publisher(for: .savedStreamsUpdated)) { _ in
            loadStreams()
        }
        .onReceive(appState.streamManager.$connectionState) { state in
            if state == .connected || state == .disconnected {
                loadRecentStreams()
            }
        }
    }

    private func loadStreams() {
        streams = appState.streamDatabase.getAllStreams()
    }

    private func loadRecentStreams() {
        recentStreams = appState.streamDatabase.getRecentStreams(limit: 5)
    }

    private func connectToStream(_ stream: SavedStream) {
        appState.streamManager.connect(to: stream)
    }

    private func connectToURL(_ url: String) {
        let protocolType = StreamProtocol.detect(from: url)
        let stream = SavedStream(name: "Quick Stream", url: url, protocolType: protocolType)
        connectToStream(stream)
    }

    private func streamFromRecent(_ recent: RecentStream) -> SavedStream {
        let protocolType = StreamProtocol.detect(from: recent.url)
        let name = existingSavedName(for: recent.url) ?? defaultStreamName(for: recent.url)
        return SavedStream(name: name, url: recent.url, protocolType: protocolType, lastUsed: Date())
    }

    private func existingSavedName(for url: String) -> String? {
        appState.streamDatabase.getStream(byURL: url)?.name
    }

    private func defaultStreamName(for url: String) -> String {
        if let parsed = URL(string: url), parsed.isFileURL {
            return parsed.lastPathComponent
        }

        if let host = URL(string: url)?.host, !host.isEmpty {
            return host
        }

        return "Saved Stream"
    }

    private func presentSaveSheet(for stream: SavedStream, preferExistingByURL: Bool) {
        if preferExistingByURL, let existing = appState.streamDatabase.getStream(byURL: stream.url) {
            sheetStream = existing
        } else {
            sheetStream = stream
        }
        sheetUsesURLUpsert = preferExistingByURL
        showStreamSheet = true
    }

    private func persistConfiguredStream(_ stream: SavedStream) {
        do {
            if sheetUsesURLUpsert {
                _ = try appState.streamDatabase.saveOrUpdateByURL(
                    name: stream.name,
                    url: stream.url,
                    protocolType: stream.protocolType,
                    lastUsed: stream.lastUsed ?? Date()
                )
            } else {
                try appState.streamDatabase.saveStream(stream)
            }

            NotificationCenter.default.post(name: .savedStreamsUpdated, object: nil)
            NotificationCenter.default.post(name: .recentStreamsUpdated, object: nil)
            loadStreams()
            loadRecentStreams()
        } catch {
            print("Error saving stream: \(error)")
        }
    }

    private func deleteStream(_ stream: SavedStream) {
        do {
            try appState.streamDatabase.deleteStream(byID: stream.id)
            NotificationCenter.default.post(name: .savedStreamsUpdated, object: nil)
            loadStreams()
        } catch {
            print("Error deleting stream: \(error)")
        }
    }
}

struct StreamRow: View {
    let stream: SavedStream
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.name)
                    .font(.headline)
                Text(stream.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stream.protocolType.displayName)
                    .font(.caption2)
                    .foregroundColor(.blue)
            }

            Spacer()

            Menu {
                Button("Connect", action: onConnect)
                Button("Edit", action: onEdit)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onConnect()
        }
    }
}
