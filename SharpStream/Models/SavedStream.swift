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
        guard let url = URL(string: urlString) else { return .unknown }
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
            if urlString.contains(".m3u8") || urlString.contains("hls") {
                return .hls
            }
            return .unknown
        }
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
