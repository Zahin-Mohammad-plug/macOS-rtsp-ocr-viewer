//
//  StreamManager.swift
//  SharpStream
//
//  Multi-protocol stream connection and reconnect logic
//

import Foundation
import Combine

enum ConnectionLifecycleState: Equatable {
    case idle
    case playerInitialized
    case loadCommandIssued
    case fileLoaded
    case reconnectScheduled(attempt: Int, delay: TimeInterval, reason: String)
    case reconnecting(attempt: Int)
    case failed(String)
}

class StreamManager: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var streamStats = StreamStats()
    @Published var currentStream: SavedStream?
    @Published var seekMode: SeekMode = .disabled
    @Published var connectionLifecycle: ConnectionLifecycleState = .idle
    @Published var reconnectAttempt: Int = 0
    
    var database: StreamDatabase?
    weak var bufferManager: BufferManager?
    weak var focusScorer: FocusScorer?
    
    private var reconnectTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private var metadataTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var reconnectDelay: TimeInterval = 1.0
    private var userInitiatedDisconnect = false
    
    // MPVKit player wrapper
    var player: MPVPlayerWrapper?
    
    init() {
        // Initialize stream manager
    }
    
    func connect(to stream: SavedStream) {
        performConnect(to: stream, triggeredByReconnect: false)
    }

    private func performConnect(to stream: SavedStream, triggeredByReconnect: Bool) {
        print("🔌 StreamManager.connect called")
        print("   Stream name: \(stream.name)")
        print("   Stream URL: \(stream.url)")
        print("   Protocol: \(stream.protocolType.rawValue)")
        
        userInitiatedDisconnect = false
        currentStream = stream
        connectionState = triggeredByReconnect ? .reconnecting : .connecting
        streamStats.connectionStatus = triggeredByReconnect ? .reconnecting : .connecting
        if !triggeredByReconnect {
            reconnectAttempts = 0
            reconnectAttempt = 0
            reconnectDelay = 1.0
        }
        seekMode = Self.classifySeekMode(protocolType: stream.protocolType, duration: player?.duration)
        
        print("📡 Connection state set to: connecting")
        
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil

        // Clean up existing player
        if let oldPlayer = player {
            print("🧹 Cleaning up existing player")
            oldPlayer.cleanup()
        }
        
        // Create new player instance
        print("🎮 Creating new MPVPlayerWrapper")
        let newPlayer = MPVPlayerWrapper()
        self.player = newPlayer
        connectionLifecycle = .playerInitialized

        newPlayer.eventHandler = { [weak self, weak newPlayer] event in
            guard let self = self,
                  let eventPlayer = newPlayer,
                  self.player === eventPlayer else { return }
            self.handlePlayerEvent(event)
        }
        
        // Set up frame callback for buffering and processing
        newPlayer.setFrameCallback { [weak self, weak newPlayer] pixelBuffer, timestamp in
            guard let self = self,
                  let eventPlayer = newPlayer,
                  self.player === eventPlayer,
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
        
        // Load stream
        print("📺 Loading stream: \(stream.url)")
        connectionLifecycle = .loadCommandIssued
        newPlayer.loadStream(url: stream.url)
        print("✅ loadStream() called, waiting for connection...")

        // Fail fast if player never loads the stream.
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            guard let self = self,
                  self.connectionState == .connecting || self.connectionState == .reconnecting else { return }
            self.handleConnectionFailure("Connection timeout", allowReconnect: true)
        }
    }
    
    private func updateMetadataFromPlayer() {
        guard let player = player else { return }
        
        let metadata = player.getMetadata()
        updateStats(bitrate: metadata.bitrate, resolution: metadata.resolution, frameRate: metadata.frameRate)
        seekMode = Self.classifySeekMode(protocolType: currentStream?.protocolType ?? .unknown, duration: player.duration)
        
        // Update metadata periodically
        metadataTimer?.invalidate()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self, let player = self.player else {
                timer.invalidate()
                return
            }
            let metadata = player.getMetadata()
            self.updateStats(bitrate: metadata.bitrate, resolution: metadata.resolution, frameRate: metadata.frameRate)
            self.seekMode = Self.classifySeekMode(protocolType: self.currentStream?.protocolType ?? .unknown, duration: player.duration)
        }
    }
    
    func disconnect() {
        userInitiatedDisconnect = true
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
        reconnectAttempt = 0
        reconnectDelay = 1.0
        seekMode = .disabled
        connectionLifecycle = .idle
    }
    
    func startReconnect(reason: String) {
        guard reconnectAttempts < maxReconnectAttempts,
              let stream = currentStream else {
            connectionState = .error("Max reconnect attempts reached")
            streamStats.connectionStatus = .error("Max reconnect attempts reached")
            connectionLifecycle = .failed("Max reconnect attempts reached")
            return
        }
        
        reconnectAttempts += 1
        reconnectAttempt = reconnectAttempts
        connectionState = .reconnecting
        streamStats.connectionStatus = .reconnecting
        connectionLifecycle = .reconnectScheduled(
            attempt: reconnectAttempts,
            delay: reconnectDelay,
            reason: reason
        )
        
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.connectionLifecycle = .reconnecting(attempt: self.reconnectAttempts)
            self.performConnect(to: stream, triggeredByReconnect: true)
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
        if userInitiatedDisconnect {
            return
        }

        switch event {
        case .fileLoaded:
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            connectionState = .connected
            streamStats.connectionStatus = .connected
            reconnectAttempts = 0
            reconnectAttempt = 0
            reconnectDelay = 1.0
            connectionLifecycle = .fileLoaded
            updateMetadataFromPlayer()
            seekMode = Self.classifySeekMode(protocolType: currentStream?.protocolType ?? .unknown, duration: player?.duration)
            // Make sure playback actually starts after load for both file and network streams.
            player?.play()

            if let stream = currentStream {
                // Persist stream history only on successful load.
                try? database?.updateLastUsed(streamID: stream.id, date: Date())
                database?.addRecentStream(url: stream.url)
                NotificationCenter.default.post(name: .recentStreamsUpdated, object: nil)
            }
            if let bufferManager = bufferManager, let streamURL = currentStream?.url {
                Task {
                    await bufferManager.startIndexSaveTimer(streamURL: streamURL)
                }
            }

        case .loadFailed(let message):
            handleConnectionFailure(message, allowReconnect: true)

        case .endFile:
            if connectionState == .connecting || connectionState == .reconnecting {
                handleConnectionFailure("Playback ended before stream fully loaded", allowReconnect: true)
            } else if connectionState == .connected {
                if shouldAutoReconnect() {
                    handleConnectionFailure("Stream ended unexpectedly", allowReconnect: true)
                } else {
                    connectionState = .disconnected
                    streamStats.connectionStatus = .disconnected
                    seekMode = .disabled
                    connectionLifecycle = .idle
                }
            } else if connectionState != .disconnected {
                connectionState = .disconnected
                streamStats.connectionStatus = .disconnected
                seekMode = .disabled
                connectionLifecycle = .idle
            }

        case .shutdown:
            if connectionState != .disconnected {
                handleConnectionFailure("Player shut down unexpectedly", allowReconnect: true)
            }
        }
    }

    private func handleConnectionFailure(_ message: String, allowReconnect: Bool) {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        connectionLifecycle = .failed(message)
        Task { [weak self] in
            await self?.bufferManager?.stopIndexSaveTask()
        }

        if allowReconnect && shouldAutoReconnect() {
            startReconnect(reason: message)
            return
        }

        connectionState = .error(message)
        streamStats.connectionStatus = .error(message)
        seekMode = .disabled
    }

    private func shouldAutoReconnect() -> Bool {
        guard let stream = currentStream else { return false }
        return Self.shouldAutoReconnect(
            protocolType: stream.protocolType,
            userInitiatedDisconnect: userInitiatedDisconnect
        )
    }

    static func shouldAutoReconnect(protocolType: StreamProtocol, userInitiatedDisconnect: Bool) -> Bool {
        if userInitiatedDisconnect {
            return false
        }

        switch protocolType {
        case .rtsp, .srt, .udp, .hls, .http, .https:
            return true
        case .file, .unknown:
            return false
        }
    }

    static func classifySeekMode(protocolType: StreamProtocol, duration: TimeInterval?) -> SeekMode {
        let knownDuration = (duration ?? 0) > 0
        if knownDuration {
            return .absolute
        }

        switch protocolType {
        case .rtsp, .srt, .udp, .hls, .http, .https:
            return .liveBuffered
        case .file:
            return .disabled
        case .unknown:
            return .disabled
        }
    }
}

extension Notification.Name {
    static let recentStreamsUpdated = Notification.Name("RecentStreamsUpdated")
}
