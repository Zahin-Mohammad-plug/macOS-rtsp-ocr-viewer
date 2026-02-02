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
    weak var bufferManager: BufferManager?
    weak var focusScorer: FocusScorer?
    
    private var reconnectTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private var metadataTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var reconnectDelay: TimeInterval = 1.0
    
    // MPVKit player wrapper
    var player: MPVPlayerWrapper?
    
    init() {
        // Initialize stream manager
    }
    
    func connect(to stream: SavedStream) {
        print("🔌 StreamManager.connect called")
        print("   Stream name: \(stream.name)")
        print("   Stream URL: \(stream.url)")
        print("   Protocol: \(stream.protocolType.rawValue)")
        
        currentStream = stream
        connectionState = .connecting
        streamStats.connectionStatus = .connecting
        
        print("📡 Connection state set to: connecting")
        
        // Clean up existing player
        if let oldPlayer = player {
            print("🧹 Cleaning up existing player")
            oldPlayer.cleanup()
        }
        metadataTimer?.invalidate()
        metadataTimer = nil
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        
        // Create new player instance
        print("🎮 Creating new MPVPlayerWrapper")
        let newPlayer = MPVPlayerWrapper()
        newPlayer.eventHandler = { [weak self] event in
            guard let self = self else { return }
            self.handlePlayerEvent(event)
        }
        
        // Set up frame callback for buffering and processing
        newPlayer.setFrameCallback { [weak self] pixelBuffer, timestamp in
            guard let self = self,
                  let bufferManager = self.bufferManager,
                  let focusScorer = self.focusScorer else { return }
            
            Task {
                // Add frame to buffer
                await bufferManager.addFrame(pixelBuffer, timestamp: timestamp)
                
                // Get sequence number for scoring
                let sequenceNumber = await bufferManager.getCurrentSequenceNumber()
                
                // Score frame for focus detection
                let frameScore = focusScorer.scoreFrame(pixelBuffer, timestamp: timestamp, sequenceNumber: sequenceNumber)
                
                // Update stats with current focus score
                await MainActor.run {
                    var stats = self.streamStats
                    stats.currentFocusScore = frameScore.score
                    self.streamStats = stats
                }
            }
        }
        
        // Start buffer index save timer with stream URL
        if let bufferManager = bufferManager {
            Task {
                await bufferManager.startIndexSaveTimer(streamURL: stream.url)
            }
        }
        
        // Load stream
        print("📺 Loading stream: \(stream.url)")
        newPlayer.loadStream(url: stream.url)
        print("✅ loadStream() called, waiting for connection...")
        
        self.player = newPlayer
        
        // Fail fast if player never loads the stream.
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            guard let self = self, self.connectionState == .connecting else { return }
            self.connectionState = .error("Connection timeout")
            self.streamStats.connectionStatus = .error("Connection timeout")
        }
        
        // Update last used in database
        try? database?.updateLastUsed(streamID: stream.id, date: Date())
        database?.addRecentStream(url: stream.url)
    }
    
    private func updateMetadataFromPlayer() {
        guard let player = player else { return }
        
        let metadata = player.getMetadata()
        updateStats(bitrate: metadata.bitrate, resolution: metadata.resolution, frameRate: metadata.frameRate)
        
        // Update metadata periodically
        metadataTimer?.invalidate()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self, let player = self.player else {
                timer.invalidate()
                return
            }
            let metadata = player.getMetadata()
            self.updateStats(bitrate: metadata.bitrate, resolution: metadata.resolution, frameRate: metadata.frameRate)
        }
    }
    
    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        
        // Clean up player
        player?.cleanup()
        player = nil
        Task { [weak self] in
            await self?.bufferManager?.stopIndexSaveTask()
        }
        
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
            guard let self = self else { return }
            self.reconnectAttempts += 1
            self.connect(to: stream)
            // Exponential backoff
            self.reconnectDelay = min(self.reconnectDelay * 2.0, 60.0)
        }
    }
    
    func updateStats(bitrate: Int?, resolution: CGSize?, frameRate: Double?) {
        streamStats.bitrate = bitrate
        streamStats.resolution = resolution
        streamStats.frameRate = frameRate
    }

    private func handlePlayerEvent(_ event: MPVPlayerEvent) {
        switch event {
        case .fileLoaded:
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            connectionState = .connected
            streamStats.connectionStatus = .connected
            reconnectAttempts = 0
            reconnectDelay = 1.0
            updateMetadataFromPlayer()

        case .loadFailed(let message):
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            connectionState = .error(message)
            streamStats.connectionStatus = .error(message)

        case .endFile:
            if connectionState == .connecting {
                connectionState = .error("Playback ended before stream fully loaded")
                streamStats.connectionStatus = .error("Playback ended before stream fully loaded")
            } else if connectionState == .connected {
                connectionState = .disconnected
                streamStats.connectionStatus = .disconnected
            }

        case .shutdown:
            if connectionState != .disconnected {
                connectionState = .disconnected
                streamStats.connectionStatus = .disconnected
            }
        }
    }
}
