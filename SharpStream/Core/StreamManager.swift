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
    @Published var liveDVRState: LiveDVRState = LiveDVRState.empty()
    
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
    struct LiveLagSample: Equatable {
        let wallClock: Date
        let playbackTime: TimeInterval
        let lagSeconds: TimeInterval
    }

    private var liveLagSample: LiveLagSample?
    private var liveSessionStart: Date?
    private var liveWindowLastReported: TimeInterval = 0
    private var cachedLiveMetrics: MPVPlayerWrapper.LiveCacheMetrics?
    private var lastLiveMetricsSampleAt: Date?
    private var pendingLiveResume: LiveResumeState?
    private var lastConnectWasReconnect = false
    private var lastAppliedLiveBufferSettings: MPVPlayerWrapper.LiveBufferSettings?
    
    // MPVKit player wrapper
    var player: MPVPlayerWrapper?

    private struct LiveResumeState {
        let lagSeconds: TimeInterval
        let shouldPlay: Bool
    }
    
    init() {
        var initialStats = streamStats
        initialStats.smartPauseSamplingFPS = smartPauseSamplingTier.fps
        streamStats = initialStats
    }

    deinit {
        reconnectTimer?.invalidate()
        connectionTimeoutTimer?.invalidate()
        metadataTimer?.invalidate()
        reconnectTimer = nil
        connectionTimeoutTimer = nil
        metadataTimer = nil
        player?.cleanup()
        player = nil
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
        lastConnectWasReconnect = triggeredByReconnect
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
        resetLiveDVRState()
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
        lastAppliedLiveBufferSettings = nil
        applyLiveBufferSettingsIfNeeded(for: stream, player: newPlayer)
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
        applyLiveBufferSettingsIfNeeded(for: currentStream, player: player)
        
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
            self.applyLiveBufferSettingsIfNeeded(for: self.currentStream, player: player)
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
        resetLiveDVRState()
        pendingLiveResume = nil
        lastConnectWasReconnect = false
        lastAppliedLiveBufferSettings = nil
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
            if let player = player {
                applyLiveBufferSettingsIfNeeded(for: currentStream, player: player)
            }
            // Make sure playback actually starts after load for both file and network streams.
            player?.play()
            resetLiveDVRState()
            startLiveSessionIfNeeded()
            applyPendingLiveResumeIfNeeded()

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
            captureLiveResumeStateIfNeeded()
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

    private func resetLiveDVRState() {
        liveLagSample = nil
        liveSessionStart = nil
        liveWindowLastReported = 0
        cachedLiveMetrics = nil
        lastLiveMetricsSampleAt = nil
        liveDVRState = LiveDVRState.empty()
    }

    private func startLiveSessionIfNeeded(now: Date = Date()) {
        guard seekMode == .liveBuffered else { return }
        liveSessionStart = now
        liveWindowLastReported = 0
        cachedLiveMetrics = nil
        lastLiveMetricsSampleAt = nil
    }

    func updateLiveBufferSettingsFromPreferences() {
        guard let player = player else { return }
        applyLiveBufferSettingsIfNeeded(for: currentStream, player: player, force: true)
    }

    private func applyLiveBufferSettingsIfNeeded(
        for stream: SavedStream?,
        player: MPVPlayerWrapper,
        force: Bool = false
    ) {
        let mode = Self.classifySeekMode(protocolType: stream?.protocolType ?? .unknown, duration: nil)
        guard mode == .liveBuffered else { return }

        let maxWindowSeconds = Self.maxBufferWindowSecondsFromDefaults()
        let backBufferBytes = Self.estimateBackBufferBytes(
            maxWindowSeconds: maxWindowSeconds,
            bitrate: streamStats.bitrate
        )
        let settings = MPVPlayerWrapper.LiveBufferSettings(
            maxWindowSeconds: maxWindowSeconds,
            backBufferBytes: backBufferBytes
        )

        if !force, settings == lastAppliedLiveBufferSettings {
            return
        }
        lastAppliedLiveBufferSettings = settings
        player.applyLiveBufferSettings(
            maxWindowSeconds: settings.maxWindowSeconds,
            backBufferBytes: settings.backBufferBytes
        )
    }

    private static func maxBufferWindowSecondsFromDefaults() -> TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: "maxBufferLength")
        let resolvedMinutes = minutes > 0 ? minutes : 30
        return TimeInterval(resolvedMinutes * 60)
    }

    private static func estimateBackBufferBytes(
        maxWindowSeconds: TimeInterval,
        bitrate: Int?
    ) -> Int64? {
        guard maxWindowSeconds > 0 else { return nil }
        let fallback: Int64 = 512 * 1024 * 1024
        let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

        let estimated: Int64
        if let bitrate, bitrate > 0 {
            let bytesPerSecond = Double(bitrate) / 8.0
            estimated = Int64(bytesPerSecond * maxWindowSeconds)
        } else {
            estimated = fallback
        }

        let clamped = min(max(estimated, fallback), maxBytes)
        return clamped
    }

    private func captureLiveResumeStateIfNeeded() {
        guard seekMode == .liveBuffered, let player = player else { return }
        pendingLiveResume = LiveResumeState(
            lagSeconds: liveDVRState.lagSeconds,
            shouldPlay: player.isPlaying
        )
    }

    private func applyPendingLiveResumeIfNeeded() {
        guard lastConnectWasReconnect, seekMode == .liveBuffered, let resume = pendingLiveResume else {
            pendingLiveResume = nil
            return
        }
        pendingLiveResume = nil

        let targetLag = max(0, resume.lagSeconds)
        guard targetLag > 0.5 else {
            if !resume.shouldPlay {
                player?.pause()
            }
            return
        }
        guard let player = player else { return }

        let maxWindow = max(0, liveDVRState.windowSeconds)
        let clampedLag = maxWindow > 0 ? min(targetLag, maxWindow) : targetLag
        guard clampedLag > 0.5 else { return }

        Task { @MainActor in
            var attempts = 0
            let maxAttempts = 3
            while attempts < maxAttempts {
                var didSeek = false
                if let metrics = player.liveCacheMetrics(),
                   let liveEdgeTime = metrics.liveEdgeTime,
                   liveEdgeTime.isFinite {
                    cachedLiveMetrics = metrics
                    lastLiveMetricsSampleAt = Date()
                    let targetTime = max(0, liveEdgeTime - clampedLag)
                    let offset = targetTime - player.currentTime
                    if abs(offset) > 0.1 {
                        didSeek = player.seek(offset: offset)
                    }
                }
                if !didSeek {
                    didSeek = player.seek(offset: -clampedLag)
                }
                if didSeek { break }
                attempts += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            if resume.shouldPlay {
                player.play()
            } else {
                player.pause()
            }
        }
    }

    @discardableResult
    func seekToLiveEdge() -> Bool {
        guard seekMode == .liveBuffered, let player = player else { return false }
        let playbackTime = player.currentTime
        let metrics = player.liveCacheMetrics()
        if let metrics {
            cachedLiveMetrics = metrics
            lastLiveMetricsSampleAt = Date()
        }

        var offset: TimeInterval?
        if let liveEdgeTime = metrics?.liveEdgeTime, liveEdgeTime.isFinite {
            let computedOffset = liveEdgeTime - playbackTime
            if computedOffset.isFinite {
                offset = max(0, computedOffset)
            }
        }

        if offset == nil || (offset ?? 0) <= 0.5 {
            offset = liveDVRState.lagSeconds
        }

        guard let resolvedOffset = offset, resolvedOffset > 0.5 else { return false }
        return player.seek(offset: resolvedOffset)
    }

    func updateLiveDVRState(
        currentPlaybackTime: TimeInterval?,
        isPlaying: Bool,
        player: MPVPlayerWrapper?,
        maxWindowSeconds: TimeInterval,
        now: Date = Date()
    ) {
        guard seekMode == .liveBuffered else {
            if Thread.isMainThread {
                liveDVRState = LiveDVRState.empty()
                liveLagSample = nil
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.liveDVRState = LiveDVRState.empty()
                    self?.liveLagSample = nil
                }
            }
            return
        }

        let playbackTime = currentPlaybackTime ?? 0

        if let player = player {
            if cachedLiveMetrics == nil ||
                now.timeIntervalSince(lastLiveMetricsSampleAt ?? .distantPast) > 0.5 {
                cachedLiveMetrics = player.liveCacheMetrics()
                lastLiveMetricsSampleAt = now
            }
        }

        if liveSessionStart == nil {
            liveSessionStart = now
        }

        let sessionElapsed = max(0, now.timeIntervalSince(liveSessionStart ?? now))
        let metricsWindow = cachedLiveMetrics?.windowSeconds ?? 0
        let fallbackWindow = max(streamStats.bufferDuration, 0)
        let candidateWindow = max(metricsWindow, fallbackWindow, sessionElapsed, liveWindowLastReported)
        let clampedCandidate = maxWindowSeconds > 0 ? min(candidateWindow, maxWindowSeconds) : candidateWindow
        var windowSeconds = clampedCandidate
        if windowSeconds.isNaN || windowSeconds.isInfinite {
            windowSeconds = 0
        }
        liveWindowLastReported = windowSeconds

        let metricsFresh = now.timeIntervalSince(lastLiveMetricsSampleAt ?? .distantPast) < 1.0
        let liveEdgeCandidate = (isPlaying && metricsFresh) ? cachedLiveMetrics?.liveEdgeTime : nil
        let effectiveLiveEdgeTime = (liveEdgeCandidate ?? 0) >= playbackTime ? liveEdgeCandidate : nil

        let computed = Self.computeLiveDVRState(
            previousSample: liveLagSample,
            playbackTime: playbackTime,
            now: now,
            windowSeconds: windowSeconds,
            liveEdgeTime: effectiveLiveEdgeTime,
            isPlaying: isPlaying
        )

        if Thread.isMainThread {
            liveLagSample = computed.sample
            liveDVRState = computed.state
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.liveLagSample = computed.sample
                self?.liveDVRState = computed.state
            }
        }
    }

    static func computeLiveDVRState(
        previousSample: LiveLagSample?,
        playbackTime: TimeInterval,
        now: Date,
        windowSeconds: TimeInterval,
        liveEdgeTime: TimeInterval? = nil,
        isPlaying: Bool = true
    ) -> (state: LiveDVRState, sample: LiveLagSample) {
        let priorSample = previousSample ?? LiveLagSample(
            wallClock: now,
            playbackTime: playbackTime,
            lagSeconds: 0
        )
        var lag: TimeInterval
        if isPlaying, let liveEdgeTime, liveEdgeTime.isFinite {
            lag = max(0, liveEdgeTime - playbackTime)
        } else {
            let deltaWall = now.timeIntervalSince(priorSample.wallClock)
            let deltaPlay = playbackTime - priorSample.playbackTime
            lag = priorSample.lagSeconds + (deltaWall - deltaPlay)
        }
        if lag.isNaN || lag.isInfinite {
            lag = 0
        }
        if lag < 0 { lag = 0 }
        if windowSeconds > 0 {
            lag = min(lag, windowSeconds)
        }

        let updatedSample = LiveLagSample(
            wallClock: now,
            playbackTime: playbackTime,
            lagSeconds: lag
        )
        let liveEdge = now
        let dvrStart = liveEdge.addingTimeInterval(-windowSeconds)
        let updatedState = LiveDVRState(
            windowSeconds: windowSeconds,
            lagSeconds: lag,
            liveEdgeDate: liveEdge,
            dvrStartDate: dvrStart
        )

        return (updatedState, updatedSample)
    }

    static func resolveLiveWindowSeconds(
        mpvWindow: TimeInterval?,
        bufferDuration: TimeInterval,
        maxWindowSeconds: TimeInterval
    ) -> TimeInterval {
        let fallbackWindow = max(bufferDuration, 0)
        var windowSeconds = mpvWindow ?? fallbackWindow
        if maxWindowSeconds > 0 {
            windowSeconds = min(windowSeconds, maxWindowSeconds)
        }
        if windowSeconds.isNaN || windowSeconds.isInfinite {
            windowSeconds = 0
        }
        return windowSeconds
    }

    static func clampLiveSeekOffset(_ offset: TimeInterval, lagSeconds: TimeInterval) -> TimeInterval {
        guard offset > 0 else { return offset }
        let clampedLag = max(0, lagSeconds)
        return min(offset, clampedLag)
    }
}

extension Notification.Name {
    static let recentStreamsUpdated = Notification.Name("RecentStreamsUpdated")
}
