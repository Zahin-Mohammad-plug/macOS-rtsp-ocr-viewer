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
        // This would perform an actual connection test
        // For now, return a placeholder
        return .success
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
