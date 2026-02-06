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

enum SmartPauseSamplingTier: String, Equatable {
    case normal
    case reduced
    case minimal

    var fps: Double {
        switch self {
        case .normal: return 4.0
        case .reduced: return 2.0
        case .minimal: return 1.0
        }
    }

    var extractionInterval: TimeInterval {
        1.0 / fps
    }

    var displayName: String {
        switch self {
        case .normal: return "Normal (4 FPS)"
        case .reduced: return "Reduced (2 FPS)"
        case .minimal: return "Minimal (1 FPS)"
        }
    }
}

class StreamManager: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var streamStats = StreamStats()
    @Published var currentStream: SavedStream?
    @Published var seekMode: SeekMode = .disabled
    @Published var connectionLifecycle: ConnectionLifecycleState = .idle
    @Published var reconnectAttempt: Int = 0
    @Published var smartPauseSamplingTier: SmartPauseSamplingTier = .normal
    
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
    private var lastConnectRequestAt: Date = .distantPast
    private var cpuOver8Count = 0
    private var cpuOver12Count = 0
    private var recoveryStableCount = 0
    
    // MPVKit player wrapper
    var player: MPVPlayerWrapper?
    
    init() {
        var initialStats = streamStats
        initialStats.smartPauseSamplingFPS = smartPauseSamplingTier.fps
        streamStats = initialStats
    }
    
    func connect(to stream: SavedStream) {
        let now = Date()
        if currentStream?.url == stream.url,
           (connectionState == .connecting || connectionState == .reconnecting),
           now.timeIntervalSince(lastConnectRequestAt) < 1.0 {
            print("⏭️ Ignoring duplicate connect request while connection is already in progress: \(stream.url)")
            return
        }

        lastConnectRequestAt = now
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
            resetSmartPauseQoSState()
            smartPauseSamplingTier = .normal
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
        newPlayer.setFrameCallback { [weak self, weak newPlayer] pixelBuffer, timestamp, playbackTime in
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
                let frameScore = focusScorer.scoreFrame(
                    pixelBuffer,
                    timestamp: timestamp,
                    playbackTime: playbackTime,
                    sequenceNumber: sequenceNumber
                )
                
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
        applySmartPauseSampling(force: true)
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
        resetSmartPauseQoSState()
        smartPauseSamplingTier = .normal
        applySmartPauseSampling(force: true)
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

    func updateSmartPauseQoS(cpuUsage: Double?, memoryPressure: MemoryPressureLevel) {
        guard connectionState == .connected || connectionState == .connecting || connectionState == .reconnecting else {
            resetSmartPauseQoSState()
            if smartPauseSamplingTier != .normal {
                setSamplingTierIfNeeded(.normal, reason: "no active playback")
            }
            return
        }

        if memoryPressure == .critical {
            setSamplingTierIfNeeded(.minimal, reason: "memory pressure critical")
            return
        }

        if let cpuUsage {
            if cpuUsage > 12 {
                cpuOver12Count += 1
                cpuOver8Count += 1
            } else if cpuUsage > 8 {
                cpuOver12Count = 0
                cpuOver8Count += 1
            } else {
                cpuOver12Count = 0
                cpuOver8Count = 0
            }
        } else {
            cpuOver12Count = 0
            cpuOver8Count = 0
        }

        if memoryPressure == .warning, smartPauseSamplingTier == .normal {
            setSamplingTierIfNeeded(.reduced, reason: "memory pressure warning")
        } else if cpuOver12Count >= 3 {
            setSamplingTierIfNeeded(.minimal, reason: "cpu > 12% for 3 samples")
        } else if cpuOver8Count >= 3 {
            setSamplingTierIfNeeded(.reduced, reason: "cpu > 8% for 3 samples")
        }

        if memoryPressure == .normal, let cpuUsage, cpuUsage < 6 {
            recoveryStableCount += 1
        } else {
            recoveryStableCount = 0
        }

        if recoveryStableCount >= 10 {
            switch smartPauseSamplingTier {
            case .minimal:
                setSamplingTierIfNeeded(.reduced, reason: "stable recovery window met")
            case .reduced:
                setSamplingTierIfNeeded(.normal, reason: "stable recovery window met")
            case .normal:
                break
            }
            recoveryStableCount = 0
        }
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
                if currentStream?.protocolType == .file {
                    handleConnectionFailure(
                        "Unable to open file stream. The file may be unsupported or corrupted.",
                        allowReconnect: false
                    )
                } else {
                    handleConnectionFailure("Playback ended before stream fully loaded", allowReconnect: true)
                }
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

        switch protocolType {
        case .rtsp, .srt, .udp:
            return .liveBuffered
        case .hls, .http, .https:
            return knownDuration ? .absolute : .liveBuffered
        case .file:
            return knownDuration ? .absolute : .disabled
        case .unknown:
            return .disabled
        }
    }

    private func setSamplingTierIfNeeded(_ newTier: SmartPauseSamplingTier, reason: String) {
        guard newTier != smartPauseSamplingTier else { return }
        smartPauseSamplingTier = newTier
        recoveryStableCount = 0
        applySmartPauseSampling(force: true)
        print("🎛️ Smart Pause sampling tier -> \(newTier.displayName) (\(reason))")
    }

    private func applySmartPauseSampling(force: Bool = false) {
        player?.setFrameExtractionInterval(smartPauseSamplingTier.extractionInterval)

        if force || streamStats.smartPauseSamplingFPS != smartPauseSamplingTier.fps {
            var stats = streamStats
            stats.smartPauseSamplingFPS = smartPauseSamplingTier.fps
            streamStats = stats
        }
    }

    private func resetSmartPauseQoSState() {
        cpuOver8Count = 0
        cpuOver12Count = 0
        recoveryStableCount = 0
    }
}

extension Notification.Name {
    static let recentStreamsUpdated = Notification.Name("RecentStreamsUpdated")
}
