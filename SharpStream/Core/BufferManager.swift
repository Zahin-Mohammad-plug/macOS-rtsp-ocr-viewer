//
//  BufferManager.swift
//  SharpStream
//
//  Hybrid RAM/disk frame buffer with crash recovery
//

import Foundation
import CoreVideo
import CoreImage
import AppKit
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
    private var maxDiskBufferDuration: TimeInterval = 2400 // 40 minutes
    
    func setMaxBufferDuration(_ duration: TimeInterval) {
        maxDiskBufferDuration = duration
    }
    
    private let bufferIndexPath: URL
    private var indexSaveTask: Task<Void, Never>?
    
    private(set) var bufferSizePreset: BufferSizePreset = .medium
    
    func setBufferSizePreset(_ preset: BufferSizePreset) {
        bufferSizePreset = preset
        updateBufferSize()
    }
    
    init(diskBufferPath: URL? = nil, bufferIndexPath: URL? = nil) {
        let tempDir = FileManager.default.temporaryDirectory
        self.diskBufferPath = diskBufferPath ?? tempDir.appendingPathComponent("SharpStreamBuffer", isDirectory: true)

        if let bufferIndexPath {
            self.bufferIndexPath = bufferIndexPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let sharpStreamDir = appSupport.appendingPathComponent("SharpStream", isDirectory: true)
            self.bufferIndexPath = sharpStreamDir.appendingPathComponent("buffer_index.json")
        }
        
        // Create directories
        try? FileManager.default.createDirectory(at: self.diskBufferPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: self.bufferIndexPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Initialize buffer size based on default preset
        // Use direct value to avoid actor isolation issues in init
        let fps: Double = 30.0
        let mediumDuration: TimeInterval = 3.0 // BufferSizePreset.medium.duration
        ramBufferMaxSize = Int(mediumDuration * fps)
        // Note: Timer and file operations will be handled when actor is accessed
    }
    
    private func updateBufferSize() {
        // Calculate max frames based on preset (assuming 30fps)
        let fps: Double = 30.0
        // Access duration directly from the enum case to avoid actor isolation issues
        let duration: TimeInterval
        switch bufferSizePreset {
        case .low: duration = 1.0
        case .medium: duration = 3.0
        case .high: duration = 5.0
        }
        ramBufferMaxSize = Int(duration * fps)
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
        
        // Periodically write to disk buffer (every frame for now, can be optimized)
        // Write every 30 frames (~1 second at 30fps) to reduce disk I/O
        if currentSequenceNumber % 30 == 0 {
            writeToDiskBuffer(frameData)
        }
        
        // Cleanup old disk buffers
        cleanupOldDiskBuffers()
    }
    
    func getCurrentSequenceNumber() -> Int {
        return currentSequenceNumber
    }
    
    func getFrame(at timestamp: Date, tolerance: TimeInterval = 0.1) -> CVPixelBuffer? {
        // First check RAM buffer (pick the closest timestamp, not the first match).
        let closestRAMFrame = ramBuffer
            .map { frame in
                (frame: frame, delta: abs(frame.timestamp.timeIntervalSince(timestamp)))
            }
            .filter { $0.delta < tolerance }
            .min { $0.delta < $1.delta }?.frame

        if let closestRAMFrame {
            // Return the pixel buffer - CVPixelBuffer is thread-safe for reading.
            return closestRAMFrame.pixelBuffer
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
        // Convert CVPixelBuffer to JPEG for efficient storage
        // Lock pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        // Create CGImage from pixel buffer
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        // Convert to NSImage for JPEG export
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        // Compress to JPEG with quality 0.8
        guard let jpegData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        
        return jpegData
    }
    
    private func writeToDiskBuffer(_ frameData: FrameData) {
        // Write frame to disk segment (organized by minute)
        let calendar = Calendar.current
        let minuteStart = calendar.dateInterval(of: .minute, for: frameData.timestamp)?.start ?? frameData.timestamp
        
        // Create segment directory if needed
        let segmentName = String(format: "segment_%d", Int(minuteStart.timeIntervalSince1970))
        let segmentDir = diskBufferPath.appendingPathComponent(segmentName, isDirectory: true)
        try? FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)
        
        // Serialize frame data
        let frameFileName = String(format: "frame_%d_%d.jpg", frameData.sequenceNumber, Int(frameData.timestamp.timeIntervalSince1970))
        let frameFileURL = segmentDir.appendingPathComponent(frameFileName)
        
        // Write JPEG data (or pixel buffer if JPEG unavailable)
        if let jpegData = frameData.jpegData {
            try? jpegData.write(to: frameFileURL)
        } else {
            // Compress on-the-fly if JPEG data not available
            // Note: pixelBuffer is not optional, so we can access it directly
            if let jpegData = compressFrame(frameData.pixelBuffer) {
                try? jpegData.write(to: frameFileURL)
            }
        }
        
        // Write metadata (JSON)
        let metadataFileName = String(format: "frame_%d_%d.json", frameData.sequenceNumber, Int(frameData.timestamp.timeIntervalSince1970))
        let metadataFileURL = segmentDir.appendingPathComponent(metadataFileName)
        
        let metadata: [String: Any] = [
            "sequenceNumber": frameData.sequenceNumber,
            "timestamp": frameData.timestamp.timeIntervalSince1970,
            "filename": frameFileName
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? jsonData.write(to: metadataFileURL)
        }
        
        // Update segments list
        let segment = BufferSegment(
            startTime: minuteStart,
            endTime: calendar.date(byAdding: .minute, value: 1, to: minuteStart) ?? minuteStart,
            filePath: segmentDir
        )
        
        // Add or update segment in list
        if let existingIndex = diskBufferSegments.firstIndex(where: { $0.startTime == segment.startTime }) {
            diskBufferSegments[existingIndex] = segment
        } else {
            diskBufferSegments.append(segment)
            diskBufferSegments.sort { $0.startTime < $1.startTime }
        }
    }
    
    private func loadFromDiskBuffer(timestamp: Date, tolerance: TimeInterval) -> CVPixelBuffer? {
        // Find segment containing this timestamp
        guard let segment = diskBufferSegments.first(where: { segment in
            timestamp >= segment.startTime && timestamp < segment.endTime
        }) else {
            return nil
        }
        
        // Find frame closest to timestamp
        var closestFrame: (url: URL, timestamp: Date)?
        var minTimeDifference = tolerance + 1.0
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: segment.filePath, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        
        for fileURL in files where fileURL.pathExtension == "jpg" {
            // Extract timestamp from filename (format: frame_N_timestamp.jpg)
            let filename = fileURL.deletingPathExtension().lastPathComponent
            let components = filename.components(separatedBy: "_")
            if components.count >= 3,
               let timestampValue = Double(components[2]),
               let fileDate = components.indices.contains(2) ? Date(timeIntervalSince1970: timestampValue) : nil {
                
                let timeDiff = abs(fileDate.timeIntervalSince(timestamp))
                if timeDiff < minTimeDifference {
                    minTimeDifference = timeDiff
                    closestFrame = (fileURL, fileDate)
                }
            }
        }
        
        guard let frame = closestFrame else {
            return nil
        }
        
        // Load JPEG and convert to CVPixelBuffer
        guard let jpegData = try? Data(contentsOf: frame.url),
              let nsImage = NSImage(data: jpegData) else {
            return nil
        }
        
        // Get CGImage from NSImage
        var rect = NSRect(origin: .zero, size: nsImage.size)
        guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        
        // Convert CGImage to CVPixelBuffer
        return cgImageToPixelBuffer(cgImage)
    }
    
    private func cgImageToPixelBuffer(_ cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
             kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
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
    
    func startIndexSaveTimer(streamURL: String? = nil, saveInterval: TimeInterval = 30.0) {
        // Cancel any existing task
        indexSaveTask?.cancel()
        // Start a new repeating task
        let url = streamURL // Capture URL for closure
        let interval = max(0.1, saveInterval)
        indexSaveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                saveBufferIndex(streamURL: url)
            }
        }
    }
    
    func stopIndexSaveTask() {
        indexSaveTask?.cancel()
        indexSaveTask = nil
    }
    
    private     func saveBufferIndex(streamURL: String? = nil) {
        // Capture values to avoid actor isolation issues
        let lastTimestamp = ramBuffer.last?.timestamp
        let sequenceNumber = currentSequenceNumber
        let path = bufferIndexPath
        let url = streamURL // Use provided URL or keep nil
        
        // Encode on a background queue to avoid actor isolation issues
        Task.detached {
            // Create a simple struct for encoding (not actor-isolated)
            struct SimpleBufferIndex: Codable {
                let lastStreamURL: String?
                let lastTimestamp: Date?
                let sequenceNumber: Int
                let savedAt: Date?
            }
            
            let index = SimpleBufferIndex(
                lastStreamURL: url,
                lastTimestamp: lastTimestamp,
                sequenceNumber: sequenceNumber,
                savedAt: Date()
            )
            
            if let data = try? JSONEncoder().encode(index) {
                try? data.write(to: path)
            }
        }
    }
    
    private func loadRecoveryData() -> BufferRecoveryData? {
        guard let data = try? Data(contentsOf: bufferIndexPath) else {
            return nil
        }
        
        // Decode synchronously - BufferIndex is a simple struct
        struct SimpleBufferIndex: Codable {
            let lastStreamURL: String?
            let lastTimestamp: Date?
            let sequenceNumber: Int
            let savedAt: Date?
        }
        
        guard let index = try? JSONDecoder().decode(SimpleBufferIndex.self, from: data) else {
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
    
    func getOCRResults() -> [OCRResult] {
        // OCR results are managed by OCREngine, not BufferManager
        // This is a placeholder - OCR results should be accessed from OCREngine
        return []
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
