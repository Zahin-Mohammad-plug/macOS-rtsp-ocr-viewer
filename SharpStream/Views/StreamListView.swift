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
    @State private var showAddStreamSheet = false
    @State private var editingStream: SavedStream?
    
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
                    }
                }
            }
            
            // Saved Streams Section
            Section("Saved Streams") {
                ForEach(streams) { stream in
                    StreamRow(stream: stream) {
                        connectToStream(stream)
                    } onEdit: {
                        editingStream = stream
                        showAddStreamSheet = true
                    } onDelete: {
                        deleteStream(stream)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    editingStream = nil
                    showAddStreamSheet = true
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddStreamSheet) {
            StreamConfigurationView(stream: editingStream) { stream in
                saveStream(stream)
                showAddStreamSheet = false
            }
        }
        .onAppear {
            loadStreams()
            loadRecentStreams()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowNewStreamDialog"))) { _ in
            editingStream = nil
            showAddStreamSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentStreamsUpdated)) { _ in
            loadRecentStreams()
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
    
    private func saveStream(_ stream: SavedStream) {
        do {
            try appState.streamDatabase.saveStream(stream)
            loadStreams()
        } catch {
            print("Error saving stream: \(error)")
        }
    }
    
    private func deleteStream(_ stream: SavedStream) {
        do {
            try appState.streamDatabase.deleteStream(byID: stream.id)
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
