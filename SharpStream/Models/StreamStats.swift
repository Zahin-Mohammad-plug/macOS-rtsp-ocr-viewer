//
//  StreamStats.swift
//  SharpStream
//
//  Stream statistics and metrics
//

import Foundation

enum StreamHealth: String, Equatable {
    case good = "Good"
    case degraded = "Degraded"
    case critical = "Critical"
}

struct StreamStats: Equatable {
    var connectionStatus: ConnectionState
    var bitrate: Int? // bits per second
    var rxRateBps: Int? // bytes per second
    var bufferLevelSeconds: Double?
    var jitterProxyMs: Double?
    var packetLossProxyPct: Double?
    var rttMs: Double? // reserved for exact SRT stats
    var packetLossPct: Double? // reserved for exact SRT stats
    var streamHealth: StreamHealth
    var streamHealthReason: String?
    var resolution: CGSize?
    var frameRate: Double? // actual FPS
    var codecName: String?
    var keyframeIntervalSeconds: Double?
    var expectedFrameRate: Double?
    var bufferDuration: TimeInterval // total buffer length in seconds
    var ramBufferUsage: Int // MB
    var diskBufferUsage: Int // MB
    var currentFocusScore: Double? // percentage
    var cpuUsage: Double? // percentage
    var gpuUsage: Double? // percentage
    var focusScoringFPS: Double? // frames scored per second
    var smartPauseSamplingFPS: Double // target Smart Pause sampling cadence
    var memoryPressure: MemoryPressureLevel
    
    
    init(connectionStatus: ConnectionState = .disconnected,
         bitrate: Int? = nil,
         rxRateBps: Int? = nil,
         bufferLevelSeconds: Double? = nil,
         jitterProxyMs: Double? = nil,
         packetLossProxyPct: Double? = nil,
         rttMs: Double? = nil,
         packetLossPct: Double? = nil,
         streamHealth: StreamHealth = .critical,
         streamHealthReason: String? = "Disconnected",
         resolution: CGSize? = nil,
         frameRate: Double? = nil,
         codecName: String? = nil,
         keyframeIntervalSeconds: Double? = nil,
         expectedFrameRate: Double? = nil,
         bufferDuration: TimeInterval = 0,
         ramBufferUsage: Int = 0,
         diskBufferUsage: Int = 0,
         currentFocusScore: Double? = nil,
         cpuUsage: Double? = nil,
         gpuUsage: Double? = nil,
         focusScoringFPS: Double? = nil,
         smartPauseSamplingFPS: Double = 4.0,
        memoryPressure: MemoryPressureLevel = .normal) {
        self.connectionStatus = connectionStatus
        self.bitrate = bitrate
        self.rxRateBps = rxRateBps
        self.bufferLevelSeconds = bufferLevelSeconds
        self.jitterProxyMs = jitterProxyMs
        self.packetLossProxyPct = packetLossProxyPct
        self.rttMs = rttMs
        self.packetLossPct = packetLossPct
        self.streamHealth = streamHealth
        self.streamHealthReason = streamHealthReason
        self.resolution = resolution
        self.frameRate = frameRate
        self.codecName = codecName
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.expectedFrameRate = expectedFrameRate
        self.bufferDuration = bufferDuration
        self.ramBufferUsage = ramBufferUsage
        self.diskBufferUsage = diskBufferUsage
        self.currentFocusScore = currentFocusScore
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.focusScoringFPS = focusScoringFPS
        self.smartPauseSamplingFPS = smartPauseSamplingFPS
        self.memoryPressure = memoryPressure
    }
}

enum MemoryPressureLevel: String, Equatable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
}
