//
//  StreamStats.swift
//  SharpStream
//
//  Stream statistics and metrics
//

import Foundation

struct StreamStats: Equatable {
    var connectionStatus: ConnectionState
    var bitrate: Int? // bits per second
    var resolution: CGSize?
    var frameRate: Double? // actual FPS
    var expectedFrameRate: Double?
    var bufferDuration: TimeInterval // total buffer length in seconds
    var ramBufferUsage: Int // MB
    var diskBufferUsage: Int // MB
    var currentFocusScore: Double?
    var cpuUsage: Double? // percentage
    var gpuUsage: Double? // percentage
    var focusScoringFPS: Double? // frames scored per second
    var memoryPressure: MemoryPressureLevel
    
    init(connectionStatus: ConnectionState = .disconnected,
         bitrate: Int? = nil,
         resolution: CGSize? = nil,
         frameRate: Double? = nil,
         expectedFrameRate: Double? = nil,
         bufferDuration: TimeInterval = 0,
         ramBufferUsage: Int = 0,
         diskBufferUsage: Int = 0,
         currentFocusScore: Double? = nil,
         cpuUsage: Double? = nil,
         gpuUsage: Double? = nil,
         focusScoringFPS: Double? = nil,
         memoryPressure: MemoryPressureLevel = .normal) {
        self.connectionStatus = connectionStatus
        self.bitrate = bitrate
        self.resolution = resolution
        self.frameRate = frameRate
        self.expectedFrameRate = expectedFrameRate
        self.bufferDuration = bufferDuration
        self.ramBufferUsage = ramBufferUsage
        self.diskBufferUsage = diskBufferUsage
        self.currentFocusScore = currentFocusScore
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.focusScoringFPS = focusScoringFPS
        self.memoryPressure = memoryPressure
    }
}

enum MemoryPressureLevel: String, Equatable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
}
