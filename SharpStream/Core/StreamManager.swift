//
//  StreamManager.swift
//  SharpStream
//
//  Multi-protocol stream connection and reconnect logic
//

import Foundation
import Combine

class StreamManager: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var streamStats = StreamStats()
    @Published var currentStream: SavedStream?
    
    var database: StreamDatabase?
    
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var reconnectDelay: TimeInterval = 1.0
    
    // MPVKit player will be integrated here
    // For now, using placeholder structure
    private var player: Any? // Will be MPVPlayer when MPVKit is added
    
    init() {
        // Initialize stream manager
    }
    
    func connect(to stream: SavedStream) {
        currentStream = stream
        connectionState = .connecting
        
        // TODO: Integrate MPVKit player
        // For now, simulate connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.connectionState = .connected
            self.streamStats.connectionStatus = .connected
            self.reconnectAttempts = 0
            self.reconnectDelay = 1.0
        }
        
        // Update last used in database
        try? database?.updateLastUsed(streamID: stream.id, date: Date())
        database?.addRecentStream(url: stream.url)
    }
    
    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectionState = .disconnected
        streamStats.connectionStatus = .disconnected
        currentStream = nil
        reconnectAttempts = 0
    }
    
    func startReconnect() {
        guard reconnectAttempts < maxReconnectAttempts,
              let stream = currentStream else {
            connectionState = .error("Max reconnect attempts reached")
            streamStats.connectionStatus = .error("Max reconnect attempts reached")
            return
        }
        
        connectionState = .reconnecting
        streamStats.connectionStatus = .reconnecting
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            self?.reconnectAttempts += 1
            self?.connect(to: stream)
            // Exponential backoff
            self?.reconnectDelay = min(self?.reconnectDelay ?? 1.0 * 2.0, 60.0)
        }
    }
    
    func updateStats(bitrate: Int?, resolution: CGSize?, frameRate: Double?) {
        streamStats.bitrate = bitrate
        streamStats.resolution = resolution
        streamStats.frameRate = frameRate
    }
}

