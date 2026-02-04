//
//  SavedStream.swift
//  SharpStream
//
//  Stream configuration model
//

import Foundation

struct SavedStream: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var protocolType: StreamProtocol
    var createdAt: Date
    var lastUsed: Date?
    
    init(id: UUID = UUID(), name: String, url: String, protocolType: StreamProtocol? = nil, createdAt: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.protocolType = protocolType ?? StreamProtocol.detect(from: url)
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }
}

enum StreamProtocol: String, Codable, CaseIterable {
    case rtsp = "rtsp"
    case srt = "srt"
    case udp = "udp"
    case hls = "hls"
    case http = "http"
    case https = "https"
    case file = "file"
    case unknown = "unknown"
    
    static func detect(from urlString: String) -> StreamProtocol {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if looksLikeLocalFilePath(trimmed) {
            return .file
        }

        guard let url = URL(string: trimmed) else { return .unknown }
        let scheme = url.scheme?.lowercased() ?? ""
        
        switch scheme {
        case "rtsp":
            return .rtsp
        case "srt":
            return .srt
        case "udp":
            return .udp
        case "http":
            return .http
        case "https":
            return .https
        case "file":
            return .file
        default:
            // Check if it's HLS by extension or path
            if trimmed.contains(".m3u8") || trimmed.contains("hls") {
                return .hls
            }
            return .unknown
        }
    }

    private static func looksLikeLocalFilePath(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        if lower.hasPrefix("file://") {
            return true
        }

        // Support pasted absolute/relative filesystem paths (with or without tilde expansion).
        return candidate.hasPrefix("/")
            || candidate.hasPrefix("~")
            || candidate.hasPrefix("./")
            || candidate.hasPrefix("../")
    }
    
    var displayName: String {
        switch self {
        case .rtsp: return "RTSP"
        case .srt: return "SRT"
        case .udp: return "UDP"
        case .hls: return "HLS"
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .file: return "File"
        case .unknown: return "Unknown"
        }
    }
}
