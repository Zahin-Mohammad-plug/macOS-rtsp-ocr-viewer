//
//  BufferManager.swift
//  SharpStream
//
//  Hybrid RAM/disk frame buffer with crash recovery
//

import Foundation
import CoreVideo
import Combine

enum BufferSizePreset: String, CaseIterable {
    case low = "Low"      // 1 second
    case medium = "Medium" // 3 seconds (default)
    case high = "High"     // 5 seconds
    
    var duration: TimeInterval {
        switch self {
        case .low: return 1.0
        case .medium: return 3.0
        case .high: return 5.0
        }
    }
    
    var estimatedMemoryMB: Int {
        // Rough estimate for 1080p30
        switch self {
        case .low: return 70
        case .medium: return 200
        case .high: return 350
        }
    }
}

actor BufferManager {
    private var ramBuffer: [FrameData] = []
    private var ramBufferMaxSize: Int = 90 // ~3 seconds at 30fps
    private var currentSequenceNumber = 0
    
    private let diskBufferPath: URL
    private var diskBufferSegments: [BufferSegment] = []
    private let maxDiskBufferDuration: TimeInterval = 2400 // 40 minutes
    
    private var bufferIndexPath: URL
    private var indexSaveTimer: Timer?
    
    var bufferSizePreset: BufferSizePreset = .medium {
        didSet {
            updateBufferSize()
        }
    }
    
    init() {
        let tempDir = FileManager.default.temporaryDirectory
        diskBufferPath = tempDir.appendingPathComponent("SharpStreamBuffer", isDirectory: true)
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sharpStreamDir = appSupport.appendingPathComponent("SharpStream")
        bufferIndexPath = sharpStreamDir.appendingPathComponent("buffer_index.json")
        
        // Create directories
        try? FileManager.default.createDirectory(at: diskBufferPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sharpStreamDir, withIntermediateDirectories: true)
        
        updateBufferSize()
        startIndexSaveTimer()
        loadRecoveryData()
    }
    
    private func updateBufferSize() {
        // Calculate max frames based on preset (assuming 30fps)
        let fps: Double = 30.0
        ramBufferMaxSize = Int(bufferSizePreset.duration * fps)
    }
    
    func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date) {
        currentSequenceNumber += 1
        
        // Store in RAM buffer (compressed as JPEG data)
        let frameData = FrameData(
            sequenceNumber: currentSequenceNumber,
            timestamp: timestamp,
            pixelBuffer: pixelBuffer,
            jpegData: compressFrame(pixelBuffer)
        )
        
        ramBuffer.append(frameData)
        
        // Trim RAM buffer if needed
        if ramBuffer.count > ramBufferMaxSize {
            ramBuffer.removeFirst(ramBuffer.count - ramBufferMaxSize)
        }
        
        // Periodically write to disk buffer
        if currentSequenceNumber % 1800 == 0 { // Every 60 seconds at 30fps
            writeToDiskBuffer(frameData)
        }
        
        // Cleanup old disk buffers
        cleanupOldDiskBuffers()
    }
    
    func getFrame(at timestamp: Date, tolerance: TimeInterval = 0.1) -> CVPixelBuffer? {
        // First check RAM buffer
        if let frame = ramBuffer.first(where: { abs($0.timestamp.timeIntervalSince(timestamp)) < tolerance }) {
            return frame.pixelBuffer
        }
        
        // Then check disk buffer
        return loadFromDiskBuffer(timestamp: timestamp, tolerance: tolerance)
    }
    
    func getFrames(in timeRange: TimeInterval) -> [FrameData] {
        let endTime = Date()
        let startTime = endTime.addingTimeInterval(-timeRange)
        
        return ramBuffer.filter { $0.timestamp >= startTime && $0.timestamp <= endTime }
    }
    
    func getBufferDuration() -> TimeInterval {
        guard let firstFrame = ramBuffer.first,
              let lastFrame = ramBuffer.last else {
            return 0
        }
        return lastFrame.timestamp.timeIntervalSince(firstFrame.timestamp)
    }
    
    func getRAMBufferUsage() -> Int {
        // Calculate actual memory usage
        return ramBuffer.reduce(0) { $0 + ($1.jpegData?.count ?? 0) } / (1024 * 1024)
    }
    
    func getDiskBufferUsage() -> Int {
        var totalSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: diskBufferPath, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        return Int(totalSize / (1024 * 1024))
    }
    
    private func compressFrame(_ pixelBuffer: CVPixelBuffer) -> Data? {
        // Convert CVPixelBuffer to JPEG
        // This is a simplified version - in production, use proper image conversion
        // For now, return nil to save memory (we'll decompress from pixelBuffer when needed)
        return nil
    }
    
    private func writeToDiskBuffer(_ frameData: FrameData) {
        // Write frame to disk segment
        // Implementation would serialize frameData and write to disk
    }
    
    private func loadFromDiskBuffer(timestamp: Date, tolerance: TimeInterval) -> CVPixelBuffer? {
        // Load frame from disk buffer
        // Implementation would search disk segments and load frame
        return nil
    }
    
    private func cleanupOldDiskBuffers() {
        let cutoffTime = Date().addingTimeInterval(-maxDiskBufferDuration)
        
        // Remove old disk buffer files
        if let enumerator = FileManager.default.enumerator(at: diskBufferPath, includingPropertiesForKeys: [.creationDateKey]) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                   let creationDate = resourceValues.creationDate,
                   creationDate < cutoffTime {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }
    
    // MARK: - Crash Recovery
    
    private func startIndexSaveTimer() {
        // Save buffer index every 30 seconds
        indexSaveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task {
                await self?.saveBufferIndex()
            }
        }
    }
    
    private func saveBufferIndex() {
        let index = BufferIndex(
            lastStreamURL: nil, // Will be set by StreamManager
            lastTimestamp: ramBuffer.last?.timestamp,
            sequenceNumber: currentSequenceNumber,
            savedAt: Date()
        )
        
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: bufferIndexPath)
        }
    }
    
    private func loadRecoveryData() -> BufferRecoveryData? {
        guard let data = try? Data(contentsOf: bufferIndexPath),
              let index = try? JSONDecoder().decode(BufferIndex.self, from: data) else {
            return nil
        }
        
        // Check if recovery data is recent (within last hour)
        if let savedAt = index.savedAt,
           Date().timeIntervalSince(savedAt) < 3600 {
            return BufferRecoveryData(
                streamURL: index.lastStreamURL,
                lastTimestamp: index.lastTimestamp,
                sequenceNumber: index.sequenceNumber
            )
        }
        
        return nil
    }
    
    func getRecoveryData() -> BufferRecoveryData? {
        return loadRecoveryData()
    }
    
    func clearRecoveryData() {
        try? FileManager.default.removeItem(at: bufferIndexPath)
    }
}

struct FrameData {
    let sequenceNumber: Int
    let timestamp: Date
    let pixelBuffer: CVPixelBuffer
    let jpegData: Data?
}

struct BufferSegment {
    let startTime: Date
    let endTime: Date
    let filePath: URL
}

struct BufferIndex: Codable {
    let lastStreamURL: String?
    let lastTimestamp: Date?
    let sequenceNumber: Int
    let savedAt: Date?
}

struct BufferRecoveryData {
    let streamURL: String?
    let lastTimestamp: Date?
    let sequenceNumber: Int
}
