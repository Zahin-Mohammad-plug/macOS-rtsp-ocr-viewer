//
//  SessionRecoveryStore.swift
//  SharpStream
//
//  Remembers the active stream so an interrupted session (crash / force quit)
//  can be resumed on next launch. A clean disconnect or quit clears it, so the
//  resume prompt only appears when the app actually died mid-stream.
//

import Foundation

struct SessionRecoveryData: Codable, Equatable {
    let streamURL: String
    let streamName: String
    let savedAt: Date
}

final class SessionRecoveryStore {
    private let fileURL: URL
    /// Recovery data older than this is ignored.
    var maxAge: TimeInterval = 6 * 3600

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = appSupport
                .appendingPathComponent("SharpStream", isDirectory: true)
                .appendingPathComponent("session_recovery.json")
        }
        try? FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func markActive(streamURL: String, streamName: String, now: Date = Date()) {
        let data = SessionRecoveryData(streamURL: streamURL, streamName: streamName, savedAt: now)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    func load(now: Date = Date()) -> SessionRecoveryData? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SessionRecoveryData.self, from: data),
              now.timeIntervalSince(decoded.savedAt) < maxAge else {
            return nil
        }
        return decoded
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
