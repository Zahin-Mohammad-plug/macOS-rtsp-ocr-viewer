//
//  StreamManager.swift
//  SharpStream
//
//  Stream connection lifecycle, reconnect policy, live DVR state and
//  Smart Pause sampling QoS.
//
//  Buffering model: mpv's demuxer cache holds the compressed stream and is the
//  only DVR buffer (seekable back-buffer sized from "Maximum Buffer Length").
//  The app itself only keeps a few decoded frames for Smart Pause (see
//  FocusScorer) — no JPEG re-encoding, no disk frame dumps.
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

final class StreamManager: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var streamStats = StreamStats()
    @Published var currentStream: SavedStream?
    @Published var seekMode: SeekMode = .disabled
    @Published var connectionLifecycle: ConnectionLifecycleState = .idle
    @Published var reconnectAttempt: Int = 0
    @Published var smartPauseSamplingTier: SmartPauseSamplingTier = .normal
    @Published var liveDVRState: LiveDVRState = LiveDVRState.empty()
    @Published private(set) var player: MPVPlayerWrapper?

    var database: StreamDatabase?
    weak var focusScorer: FocusScorer?
    var recoveryStore: SessionRecoveryStore?

    private var reconnectTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private var metadataTimer: Timer?
    private var liveStateTimer: Timer?
    private var transportMetricsSampler = TransportMetricsSampler()
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var reconnectDelay: TimeInterval = 1.0
    private var userInitiatedDisconnect = false
    private var lastConnectRequestAt: Date = .distantPast
    private var frameSequence = 0

    // Smart Pause QoS hysteresis counters.
    private var heavyLoadCount = 0
    private var severeLoadCount = 0
    private var recoveryStableCount = 0

    struct LiveLagSample: Equatable {
        let wallClock: Date
        let playbackTime: TimeInterval
        let lagSeconds: TimeInterval
    }

    private var liveLagSample: LiveLagSample?
    private var pendingLiveResume: LiveResumeState?
    private var lastConnectWasReconnect = false
    private var lastAppliedLiveBufferSettings: MPVPlayerWrapper.LiveBufferSettings?

    private struct LiveResumeState {
        let lagSeconds: TimeInterval
        let shouldPlay: Bool
    }

    init() {
        streamStats.smartPauseSamplingFPS = smartPauseSamplingTier.fps
    }

    deinit {
        invalidateTimers()
        player?.cleanup()
    }

    // MARK: - Connect / disconnect

    func connect(to stream: SavedStream) {
        let now = Date()
        if currentStream?.url == stream.url,
           connectionState == .connecting || connectionState == .reconnecting,
           now.timeIntervalSince(lastConnectRequestAt) < 1.0 {
            return
        }
        lastConnectRequestAt = now
        performConnect(to: stream, triggeredByReconnect: false)
    }

    private func performConnect(to stream: SavedStream, triggeredByReconnect: Bool) {
        userInitiatedDisconnect = false
        lastConnectWasReconnect = triggeredByReconnect
        currentStream = stream
        connectionState = triggeredByReconnect ? .reconnecting : .connecting
        streamStats.connectionStatus = connectionState
        streamStats.streamHealth = triggeredByReconnect ? .critical : .degraded
        streamStats.streamHealthReason = triggeredByReconnect ? "Reconnecting" : "Connecting"
        if !triggeredByReconnect {
            reconnectAttempts = 0
            reconnectAttempt = 0
            reconnectDelay = 1.0
            pendingLiveResume = nil
            resetSmartPauseQoSState()
            smartPauseSamplingTier = .normal
            transportMetricsSampler.reset()
        }
        focusScorer?.reset()
        resetLiveDVRState()
        seekMode = Self.classifySeekMode(protocolType: stream.protocolType, duration: nil)
        invalidateTimers()

        // Each connection gets a fresh player (and, via the view's identity, a
        // fresh render surface). Old players are torn down asynchronously.
        player?.cleanup()

        let newPlayer = MPVPlayerWrapper()
        lastAppliedLiveBufferSettings = nil
        applyLiveBufferSettingsIfNeeded(for: stream, player: newPlayer)

        newPlayer.eventHandler = { [weak self, weak newPlayer] event in
            guard let self, let newPlayer, self.player === newPlayer else { return }
            self.handlePlayerEvent(event)
        }

        // Runs on the player's capture queue: score immediately, keep nothing else.
        newPlayer.setFrameCallback { [weak self] pixelBuffer, timestamp, playbackTime in
            guard let self, let focusScorer = self.focusScorer else { return }
            self.frameSequence &+= 1
            focusScorer.scoreFrame(
                pixelBuffer,
                timestamp: timestamp,
                playbackTime: playbackTime,
                sequenceNumber: self.frameSequence
            )
        }

        player = newPlayer
        connectionLifecycle = .playerInitialized
        applySmartPauseSampling(force: true)

        // The load is queued until the video view attaches its surface.
        connectionLifecycle = .loadCommandIssued
        newPlayer.loadStream(url: stream.url)

        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.connectionState == .connecting || self.connectionState == .reconnecting else { return }
                self.handleConnectionFailure("Connection timed out", allowReconnect: true)
            }
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        invalidateTimers()

        player?.cleanup()
        player = nil
        focusScorer?.reset()
        recoveryStore?.clear()

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
        transportMetricsSampler.reset()
        streamStats.rxRateBps = nil
        streamStats.bufferLevelSeconds = nil
        streamStats.jitterProxyMs = nil
        streamStats.packetLossProxyPct = nil
        streamStats.rttMs = nil
        streamStats.packetLossPct = nil
        streamStats.streamHealth = .critical
        streamStats.streamHealthReason = "Disconnected"
        streamStats.codecName = nil
        streamStats.resolution = nil
        streamStats.bitrate = nil
        streamStats.frameRate = nil
        streamStats.keyframeIntervalSeconds = nil
        streamStats.bufferDuration = 0
    }

    func startReconnect(reason: String) {
        guard reconnectAttempts < maxReconnectAttempts, let stream = currentStream else {
            let message = "Gave up after \(maxReconnectAttempts) reconnect attempts (\(reason))"
            connectionState = .error(message)
            streamStats.connectionStatus = .error(message)
            connectionLifecycle = .failed(message)
            seekMode = .disabled
            return
        }

        reconnectAttempts += 1
        transportMetricsSampler.markReconnectEvent()
        reconnectAttempt = reconnectAttempts
        connectionState = .reconnecting
        streamStats.connectionStatus = .reconnecting
        streamStats.streamHealth = .critical
        streamStats.streamHealthReason = "Reconnecting: \(reason)"
        connectionLifecycle = .reconnectScheduled(attempt: reconnectAttempts, delay: reconnectDelay, reason: reason)

        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connectionLifecycle = .reconnecting(attempt: self.reconnectAttempts)
                self.reconnectDelay = min(self.reconnectDelay * 2.0, 30.0)
                self.performConnect(to: stream, triggeredByReconnect: true)
            }
        }
    }

    private func invalidateTimers() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        liveStateTimer?.invalidate()
        liveStateTimer = nil
    }

    // MARK: - Player events

    private func handlePlayerEvent(_ event: MPVPlayerEvent) {
        guard !userInitiatedDisconnect else { return }

        switch event {
        case .fileLoaded:
            handleFileLoaded()

        case .loadFailed(let message):
            handleConnectionFailure(message, allowReconnect: true)

        case .endFile(let reason, let message):
            switch reason {
            case .stop, .redirect, .quit:
                // Superseded by a new loadfile or player teardown.
                return
            case .eof, .error, .unknown:
                break
            }
            let isFile = currentStream?.protocolType == .file
            let detail = message.map { ": \($0)" } ?? ""
            if connectionState == .connecting || connectionState == .reconnecting {
                if isFile {
                    handleConnectionFailure("Unable to open file\(detail)", allowReconnect: false)
                } else {
                    handleConnectionFailure("Stream failed to open\(detail)", allowReconnect: true)
                }
            } else if connectionState == .connected {
                if reason == .eof, isFile {
                    // keep-open normally prevents this; treat as a finished file.
                    return
                }
                handleConnectionFailure(reason == .eof ? "Stream ended" : "Playback error\(detail)", allowReconnect: true)
            }

        case .shutdown:
            if connectionState != .disconnected {
                handleConnectionFailure("Player shut down unexpectedly", allowReconnect: true)
            }
        }
    }

    private func handleFileLoaded() {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        connectionState = .connected
        streamStats.connectionStatus = .connected
        streamStats.streamHealth = .good
        streamStats.streamHealthReason = "Connected"
        reconnectAttempts = 0
        reconnectAttempt = 0
        reconnectDelay = 1.0
        connectionLifecycle = .fileLoaded

        guard let player else { return }
        seekMode = Self.classifySeekMode(protocolType: currentStream?.protocolType ?? .unknown, duration: player.duration)
        applyLiveBufferSettingsIfNeeded(for: currentStream, player: player)
        player.play()
        resetLiveDVRState()
        startPeriodicSampling()
        applyPendingLiveResumeIfNeeded()

        if let stream = currentStream {
            try? database?.updateLastUsed(streamID: stream.id, date: Date())
            database?.addRecentStream(url: stream.url)
            NotificationCenter.default.post(name: .recentStreamsUpdated, object: nil)
            recoveryStore?.markActive(streamURL: stream.url, streamName: stream.name)
        }
    }

    private func handleConnectionFailure(_ message: String, allowReconnect: Bool) {
        transportMetricsSampler.markFailureEvent()
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        liveStateTimer?.invalidate()
        liveStateTimer = nil
        connectionLifecycle = .failed(message)

        if allowReconnect && shouldAutoReconnect() {
            captureLiveResumeStateIfNeeded()
            startReconnect(reason: message)
            return
        }

        connectionState = .error(message)
        streamStats.connectionStatus = .error(message)
        streamStats.streamHealth = .critical
        streamStats.streamHealthReason = message
        seekMode = .disabled
    }

    // MARK: - Periodic sampling (metadata + live DVR)

    private func startPeriodicSampling() {
        guard let player else { return }
        sampleTransportMetrics(from: player)

        metadataTimer?.invalidate()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.sampleTransportMetrics(from: player)
            }
        }

        liveStateTimer?.invalidate()
        liveStateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLiveDVRState() }
        }
    }

    private func sampleTransportMetrics(from player: MPVPlayerWrapper) {
        let snapshot = player.getTransportMetricsSnapshot()
        updateStats(
            bitrate: snapshot.bitrate,
            resolution: snapshot.resolution,
            frameRate: snapshot.frameRate,
            codecName: snapshot.codecName
        )
        let newSeekMode = Self.classifySeekMode(protocolType: currentStream?.protocolType ?? .unknown, duration: player.duration)
        if newSeekMode != seekMode {
            seekMode = newSeekMode
        }
        applyLiveBufferSettingsIfNeeded(for: currentStream, player: player)

        let bufferLevelSeconds = snapshot.cacheDurationSeconds ?? snapshot.seekableWindowSeconds
        streamStats.bufferDuration = snapshot.seekableWindowSeconds ?? 0
        let sampled = transportMetricsSampler.ingest(
            isConnected: connectionState == .connected,
            isConnecting: connectionState == .connecting,
            isReconnecting: connectionState == .reconnecting,
            hasError: {
                if case .error = connectionState { return true }
                return false
            }(),
            errorMessage: {
                if case .error(let message) = connectionState { return message }
                return nil
            }(),
            isPlaying: player.isPlaying,
            lagSeconds: liveDVRState.lagSeconds,
            rxRateBps: snapshot.rawInputRateBps,
            totalBytesRead: snapshot.totalBytesRead,
            bufferLevelSeconds: bufferLevelSeconds,
            frameType: snapshot.frameType
        )

        streamStats.rxRateBps = sampled.rxRateBps
        streamStats.bufferLevelSeconds = sampled.bufferLevelSeconds
        streamStats.jitterProxyMs = sampled.jitterProxyMs
        streamStats.packetLossProxyPct = sampled.packetLossProxyPct
        streamStats.streamHealth = sampled.streamHealth
        streamStats.streamHealthReason = sampled.streamHealthReason
        streamStats.keyframeIntervalSeconds = sampled.keyframeIntervalSeconds
        streamStats.rttMs = nil
        streamStats.packetLossPct = nil
    }

    func updateStats(bitrate: Int?, resolution: CGSize?, frameRate: Double?, codecName: String?) {
        streamStats.bitrate = bitrate
        streamStats.resolution = resolution
        streamStats.frameRate = frameRate
        streamStats.codecName = codecName
    }

    private func refreshLiveDVRState() {
        guard let player else { return }
        updateLiveDVRState(
            currentPlaybackTime: player.precisePlaybackTime,
            isPlaying: player.isPlaying,
            player: player,
            maxWindowSeconds: Self.maxBufferWindowSecondsFromDefaults()
        )
    }

    // MARK: - Reconnect policy / seek mode

    private func shouldAutoReconnect() -> Bool {
        guard let stream = currentStream else { return false }
        return Self.shouldAutoReconnect(protocolType: stream.protocolType, userInitiatedDisconnect: userInitiatedDisconnect)
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

    // MARK: - Smart Pause sampling QoS

    /// Adapt the Smart Pause sampling rate to how expensive capture + scoring is.
    ///
    /// `pipelineLoad` is the fraction of the sampling interval spent capturing and
    /// scoring one frame (0.5 = half the interval). Total process CPU is *not*
    /// used: video decode alone routinely exceeds any fixed CPU threshold, which
    /// previously pinned sampling at 1 FPS and starved Smart Pause of candidates.
    func updateSmartPauseQoS(pipelineLoad: Double?, memoryPressure: MemoryPressureLevel) {
        guard connectionState == .connected || connectionState == .connecting || connectionState == .reconnecting else {
            resetSmartPauseQoSState()
            if smartPauseSamplingTier != .normal {
                setSamplingTierIfNeeded(.normal, reason: "no active playback")
            }
            return
        }

        if memoryPressure == .critical {
            setSamplingTierIfNeeded(.minimal, reason: "memory pressure critical")
            recoveryStableCount = 0
            return
        }

        let load = pipelineLoad ?? 0
        if load > 0.7 {
            severeLoadCount += 1
            heavyLoadCount += 1
        } else if load > 0.35 {
            severeLoadCount = 0
            heavyLoadCount += 1
        } else {
            severeLoadCount = 0
            heavyLoadCount = 0
        }

        if memoryPressure == .warning, smartPauseSamplingTier == .normal {
            setSamplingTierIfNeeded(.reduced, reason: "memory pressure warning")
        } else if severeLoadCount >= 3 {
            setSamplingTierIfNeeded(.minimal, reason: "capture load > 70%")
        } else if heavyLoadCount >= 3, smartPauseSamplingTier == .normal {
            setSamplingTierIfNeeded(.reduced, reason: "capture load > 35%")
        }

        if memoryPressure == .normal, load < 0.2 {
            recoveryStableCount += 1
        } else {
            recoveryStableCount = 0
        }

        if recoveryStableCount >= 10 {
            switch smartPauseSamplingTier {
            case .minimal:
                setSamplingTierIfNeeded(.reduced, reason: "load recovered")
            case .reduced:
                setSamplingTierIfNeeded(.normal, reason: "load recovered")
            case .normal:
                break
            }
            recoveryStableCount = 0
        }
    }

    private func setSamplingTierIfNeeded(_ newTier: SmartPauseSamplingTier, reason: String) {
        guard newTier != smartPauseSamplingTier else { return }
        smartPauseSamplingTier = newTier
        recoveryStableCount = 0
        heavyLoadCount = 0
        severeLoadCount = 0
        applySmartPauseSampling(force: true)
        print("🎛️ Smart Pause sampling -> \(newTier.displayName) (\(reason))")
    }

    private func applySmartPauseSampling(force: Bool = false) {
        player?.setFrameExtractionInterval(smartPauseSamplingTier.extractionInterval)
        if force || streamStats.smartPauseSamplingFPS != smartPauseSamplingTier.fps {
            streamStats.smartPauseSamplingFPS = smartPauseSamplingTier.fps
        }
    }

    private func resetSmartPauseQoSState() {
        heavyLoadCount = 0
        severeLoadCount = 0
        recoveryStableCount = 0
    }

    // MARK: - Live buffer settings

    func updateLiveBufferSettingsFromPreferences() {
        guard let player else { return }
        applyLiveBufferSettingsIfNeeded(for: currentStream, player: player, force: true)
    }

    private func applyLiveBufferSettingsIfNeeded(for stream: SavedStream?, player: MPVPlayerWrapper, force: Bool = false) {
        let mode = Self.classifySeekMode(protocolType: stream?.protocolType ?? .unknown, duration: nil)
        guard mode == .liveBuffered else { return }

        let settings = Self.resolveLiveBufferSettings(
            maxWindowSeconds: Self.maxBufferWindowSecondsFromDefaults(),
            bitrate: streamStats.bitrate,
            previousSettings: lastAppliedLiveBufferSettings,
            force: force
        )
        if !force, settings == lastAppliedLiveBufferSettings {
            return
        }
        lastAppliedLiveBufferSettings = settings
        player.applyLiveBufferSettings(maxWindowSeconds: settings.maxWindowSeconds, backBufferBytes: settings.backBufferBytes)
    }

    static func maxBufferWindowSecondsFromDefaults() -> TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: "maxBufferLength")
        return TimeInterval((minutes > 0 ? minutes : 30) * 60)
    }

    static func resolveLiveBufferSettings(
        maxWindowSeconds: TimeInterval,
        bitrate: Int?,
        previousSettings: MPVPlayerWrapper.LiveBufferSettings?,
        force: Bool
    ) -> MPVPlayerWrapper.LiveBufferSettings {
        let resolvedBackBufferBytes: Int64?
        if !force, let previousSettings, previousSettings.maxWindowSeconds == maxWindowSeconds {
            // Keep back-buffer stable for the session; bitrate jitter should not reconfigure playback.
            resolvedBackBufferBytes = previousSettings.backBufferBytes
        } else {
            resolvedBackBufferBytes = estimateBackBufferBytes(maxWindowSeconds: maxWindowSeconds, bitrate: bitrate)
        }
        return MPVPlayerWrapper.LiveBufferSettings(maxWindowSeconds: maxWindowSeconds, backBufferBytes: resolvedBackBufferBytes)
    }

    private static func estimateBackBufferBytes(maxWindowSeconds: TimeInterval, bitrate: Int?) -> Int64? {
        guard maxWindowSeconds > 0 else { return nil }
        let fallback: Int64 = 512 * 1024 * 1024
        let maxBytes: Int64 = 2 * 1024 * 1024 * 1024
        let estimated: Int64
        if let bitrate, bitrate > 0 {
            estimated = Int64(Double(bitrate) / 8.0 * maxWindowSeconds * 1.2)
        } else {
            estimated = fallback
        }
        return min(max(estimated, fallback), maxBytes)
    }

    // MARK: - Live DVR

    private func resetLiveDVRState() {
        liveLagSample = nil
        liveDVRState = LiveDVRState.empty()
    }

    private func captureLiveResumeStateIfNeeded() {
        guard seekMode == .liveBuffered, let player else { return }
        pendingLiveResume = LiveResumeState(lagSeconds: liveDVRState.lagSeconds, shouldPlay: player.isPlaying)
    }

    /// After a reconnect the old cache is gone; only restore the paused state.
    /// (Seeking back by the previous lag would land outside the new, empty cache.)
    private func applyPendingLiveResumeIfNeeded() {
        defer { pendingLiveResume = nil }
        guard lastConnectWasReconnect, seekMode == .liveBuffered, let resume = pendingLiveResume else { return }
        if !resume.shouldPlay {
            player?.pause()
        }
    }

    @discardableResult
    func seekToLiveEdge() -> Bool {
        guard seekMode == .liveBuffered, let player else { return false }
        if let edge = player.liveCacheMetrics()?.liveEdgeTime, edge.isFinite, edge > 0 {
            let ok = player.seek(to: max(0, edge - 0.5), exact: false)
            if ok { player.play() }
            return ok
        }
        let lag = liveDVRState.lagSeconds
        guard lag > 0.5 else {
            player.play()
            return true
        }
        let ok = player.seek(offset: lag, exact: false)
        if ok { player.play() }
        return ok
    }

    /// Seek to a position inside the live DVR window (0 = oldest cached, window = live edge).
    @discardableResult
    func seekLive(toWindowPosition position: TimeInterval) -> Bool {
        guard seekMode == .liveBuffered, let player else { return false }
        let window = liveDVRState.windowSeconds
        guard window > 0 else { return false }
        let clamped = max(0, min(position, window))
        if let metrics = player.liveCacheMetrics(), let start = metrics.windowStartTime, start.isFinite {
            return player.seek(to: start + clamped, exact: false)
        }
        let targetLag = window - clamped
        return player.seek(offset: liveDVRState.lagSeconds - targetLag, exact: false)
    }

    func updateLiveDVRState(
        currentPlaybackTime: TimeInterval?,
        isPlaying: Bool,
        player: MPVPlayerWrapper?,
        maxWindowSeconds: TimeInterval,
        now: Date = Date()
    ) {
        guard seekMode == .liveBuffered else {
            if liveDVRState.windowSeconds != 0 || liveLagSample != nil {
                liveDVRState = LiveDVRState.empty()
                liveLagSample = nil
            }
            return
        }

        let playbackTime = currentPlaybackTime ?? 0
        let metrics = player?.liveCacheMetrics()
        let windowSeconds = Self.resolveLiveWindowSeconds(
            mpvWindow: metrics?.windowSeconds,
            bufferDuration: 0,
            maxWindowSeconds: maxWindowSeconds
        )
        let liveEdge = metrics?.liveEdgeTime.flatMap { $0 >= playbackTime - 0.5 ? $0 : nil }

        let computed = Self.computeLiveDVRState(
            previousSample: liveLagSample,
            playbackTime: playbackTime,
            now: now,
            windowSeconds: windowSeconds,
            liveEdgeTime: liveEdge,
            isPlaying: liveEdge != nil ? true : isPlaying
        )
        liveLagSample = computed.sample
        if computed.state != liveDVRState {
            liveDVRState = computed.state
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
        let priorSample = previousSample ?? LiveLagSample(wallClock: now, playbackTime: playbackTime, lagSeconds: 0)
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
        lag = max(0, lag)
        if windowSeconds > 0 {
            lag = min(lag, windowSeconds)
        }

        let updatedSample = LiveLagSample(wallClock: now, playbackTime: playbackTime, lagSeconds: lag)
        let updatedState = LiveDVRState(
            windowSeconds: windowSeconds,
            lagSeconds: lag,
            liveEdgeDate: now,
            dvrStartDate: now.addingTimeInterval(-windowSeconds)
        )
        return (updatedState, updatedSample)
    }

    static func resolveLiveWindowSeconds(
        mpvWindow: TimeInterval?,
        bufferDuration: TimeInterval,
        maxWindowSeconds: TimeInterval
    ) -> TimeInterval {
        var windowSeconds = mpvWindow ?? max(bufferDuration, 0)
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
        return min(offset, max(0, lagSeconds))
    }
}

extension Notification.Name {
    static let recentStreamsUpdated = Notification.Name("RecentStreamsUpdated")
}
