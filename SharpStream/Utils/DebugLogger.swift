//
//  DebugLogger.swift
//  SharpStream
//
//  Debug logging utility for runtime debugging
//

import Foundation
import os.log

struct DebugLogger {
    /// Log file path: set SHARPSTREAM_DEBUG_LOG_PATH in environment, or defaults to ~/Library/Application Support/SharpStream/debug.log
    private static var logPath: String {
        if let env = ProcessInfo.processInfo.environment["SHARPSTREAM_DEBUG_LOG_PATH"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("SharpStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log").path
    }
    private static let osLogger = Logger(subsystem: "com.sharpstream", category: "debug")
    private static let queue = DispatchQueue(label: "debug.logger", qos: .utility)
    
    static func log(
        location: String,
        message: String,
        data: [String: Any] = [:],
        hypothesisId: String? = nil,
        sessionId: String = "debug-session",
        runId: String = "run1"
    ) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        var logEntry: [String: Any] = [
            "id": "log_\(timestamp)_\(UUID().uuidString.prefix(8))",
            "timestamp": timestamp,
            "location": location,
            "message": message,
            "sessionId": sessionId,
            "runId": runId
        ]
        
        if !data.isEmpty {
            logEntry["data"] = data
        }
        if let hypothesisId = hypothesisId {
            logEntry["hypothesisId"] = hypothesisId
        }
        
        // Write to console (stdout) - this shows up in log stream
        print("🐛 DEBUG: \(message) @ \(location)")
        osLogger.info("🐛 [\(hypothesisId ?? "N/A")] \(message) @ \(location)")
        if !data.isEmpty {
            let dataStr = data.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            print("   Data: \(dataStr)")
            osLogger.info("   Data: \(dataStr)")
        }
        
        // Write to file as NDJSON (synchronous for debugging)
        // Also write simple text version for easy reading
        let textLog = "[\(hypothesisId ?? "N/A")] \(message) @ \(location)\n"
        
        // Write to multiple locations to ensure we capture logs
        let locations = [
            logPath,
            NSHomeDirectory() + "/Documents/sharpstream_debug.log",
            NSHomeDirectory() + "/Desktop/sharpstream_debug.log"
        ]
        
        for path in locations {
            if let fileHandle = FileHandle(forWritingAtPath: path) {
                fileHandle.seekToEndOfFile()
                if let data = textLog.data(using: .utf8) {
                    fileHandle.write(data)
                    fileHandle.synchronizeFile()
                }
                fileHandle.closeFile()
            } else {
                // Create file if it doesn't exist
                let url = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? textLog.write(toFile: path, atomically: false, encoding: .utf8)
            }
        }
        
        // Also write JSON version
        if let jsonData = try? JSONSerialization.data(withJSONObject: logEntry),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let jsonLog = jsonString + "\n"
            let jsonPath = NSHomeDirectory() + "/Documents/sharpstream_debug.json"
            if let fileHandle = FileHandle(forWritingAtPath: jsonPath) {
                fileHandle.seekToEndOfFile()
                if let data = jsonLog.data(using: .utf8) {
                    fileHandle.write(data)
                    fileHandle.synchronizeFile()
                }
                fileHandle.closeFile()
            } else {
                try? jsonLog.write(toFile: jsonPath, atomically: false, encoding: .utf8)
            }
        }
    }
}
