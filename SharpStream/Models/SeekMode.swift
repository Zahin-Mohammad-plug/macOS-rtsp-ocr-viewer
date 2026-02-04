//
//  SeekMode.swift
//  SharpStream
//
//  Explicit playback seek capability for current source.
//

import Foundation

enum SeekMode: String, Equatable, Codable {
    case absolute = "Absolute"
    case liveBuffered = "LiveBuffered"
    case disabled = "Disabled"

    var allowsTimelineScrubbing: Bool {
        self == .absolute
    }

    var allowsRelativeSeek: Bool {
        self == .absolute || self == .liveBuffered
    }
}
