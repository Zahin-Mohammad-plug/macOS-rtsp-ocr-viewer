//
//  StreamURLValidator.swift
//  SharpStream
//
//  URL validation with helpful error messages
//

import Foundation

struct StreamURLValidator {
    static func validate(_ urlString: String) -> ValidationResult {
        // Check if URL is empty
        guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("URL cannot be empty")
        }
        
        // Check if it's a valid URL
        guard let url = URL(string: urlString) else {
            return .invalid("Invalid URL format")
        }
        
        // Check protocol
        let protocolType = StreamProtocol.detect(from: urlString)
        
        if protocolType == .unknown {
            return .invalid("Unsupported protocol. Supported: RTSP, SRT, UDP, HLS, HTTP, HTTPS, File")
        }
        
        // Protocol-specific validation
        switch protocolType {
        case .rtsp:
            if !urlString.hasPrefix("rtsp://") {
                return .invalid("RTSP URL must start with 'rtsp://'")
            }
            if url.host == nil {
                return .invalid("RTSP URL must include a host address")
            }
            
        case .srt:
            if !urlString.hasPrefix("srt://") {
                return .invalid("SRT URL must start with 'srt://'")
            }
            if url.host == nil {
                return .invalid("SRT URL must include a host address")
            }
            
        case .udp:
            if !urlString.hasPrefix("udp://") {
                return .invalid("UDP URL must start with 'udp://'")
            }
            if url.host == nil {
                return .invalid("UDP URL must include a host address")
            }
            
        case .hls:
            if !urlString.contains(".m3u8") && !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
                return .invalid("HLS URL should be an HTTP/HTTPS URL with .m3u8 extension")
            }
            
        case .http, .https:
            if url.host == nil {
                return .invalid("HTTP/HTTPS URL must include a host address")
            }
            
        case .file:
            let fileURL = URL(fileURLWithPath: urlString.replacingOccurrences(of: "file://", with: ""))
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                return .invalid("File does not exist at the specified path")
            }
            
        case .unknown:
            return .invalid("Unknown protocol")
        }
        
        return .valid
    }
    
    static func testConnection(to urlString: String, timeout: TimeInterval = 5.0) async -> ConnectionTestResult {
        let validation = validate(urlString)
        guard validation.isValid else {
            return .invalidURL
        }

        let testPlayer = MPVPlayerWrapper(headless: true)
        defer { testPlayer.cleanup() }

        guard testPlayer.initializeForHeadlessIfNeeded() else {
            return .unknownError("Failed to initialize probe player")
        }

        let eventStream = AsyncStream<MPVPlayerEvent> { continuation in
            testPlayer.eventHandler = { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in
                testPlayer.eventHandler = nil
            }
        }

        testPlayer.loadStream(url: urlString)

        let timeoutNanos = UInt64(max(1, timeout) * 1_000_000_000)
        return await withTaskGroup(of: ConnectionTestResult.self) { group in
            group.addTask {
                for await event in eventStream {
                    switch event {
                    case .fileLoaded:
                        return .success
                    case .loadFailed(let message):
                        return mapProbeError(message)
                    case .endFile:
                        return .unknownError("Playback ended before stream became active")
                    case .shutdown:
                        return .unknownError("Probe player shut down unexpectedly")
                    }
                }
                return .unknownError("No probe events received")
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return .timeout
            }

            let result = await group.next() ?? .unknownError("Probe returned no result")
            group.cancelAll()
            return result
        }
    }

    private static func mapProbeError(_ message: String) -> ConnectionTestResult {
        let lower = message.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return .timeout
        }
        if lower.contains("refused") || lower.contains("unreachable") || lower.contains("route") {
            return .connectionRefused
        }
        if lower.contains("auth") || lower.contains("permission") || lower.contains("401") || lower.contains("403") {
            return .authenticationRequired
        }
        return .unknownError(message)
    }
}

enum ValidationResult {
    case valid
    case invalid(String)
    
    var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }
    
    var errorMessage: String? {
        if case .invalid(let message) = self {
            return message
        }
        return nil
    }
}

enum ConnectionTestResult: Equatable {
    case success
    case timeout
    case authenticationRequired
    case connectionRefused
    case invalidURL
    case unknownError(String)
    
    var errorMessage: String {
        switch self {
        case .success:
            return "Connection successful"
        case .timeout:
            return "Connection timeout - check network and URL"
        case .authenticationRequired:
            return "Authentication required - check username/password in URL"
        case .connectionRefused:
            return "Connection refused - check if stream server is running"
        case .invalidURL:
            return "Invalid URL format"
        case .unknownError(let message):
            return "Connection error: \(message)"
        }
    }
}
