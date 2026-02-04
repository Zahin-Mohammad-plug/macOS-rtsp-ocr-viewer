//
//  SmartPauseDiagnostics.swift
//  SharpStream
//
//  Structured diagnostics payload for Smart Pause runs.
//

import Foundation

struct SmartPauseDiagnostics: Equatable, Codable {
    var timestamp: Date = Date()
    var lookbackSeconds: TimeInterval
    var seekMode: SeekMode
    var recentFrameCountBeforeRecovery: Int = 0
    var recentFrameCountAfterRecovery: Int = 0
    var onDemandScoreAttempts: Int = 0
    var warmupWaitApplied: Bool = false
    var selectedSequenceNumber: Int?
    var selectedScore: Double?
    var selectedFrameAge: TimeInterval?
    var selectedPlaybackTime: TimeInterval?
    var seekSucceeded: Bool?
    var failureReason: SmartPauseFailureReason?
    var statusMessage: String = ""

    var compactSummary: String {
        let reason = failureReason?.rawValue ?? "none"
        let seq = selectedSequenceNumber.map(String.init) ?? "none"
        let seek = seekSucceeded.map { $0 ? "ok" : "failed" } ?? "none"
        return "reason=\(reason);before=\(recentFrameCountBeforeRecovery);after=\(recentFrameCountAfterRecovery);attempts=\(onDemandScoreAttempts);warmup=\(warmupWaitApplied);seq=\(seq);seek=\(seek)"
    }

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let encoded = String(data: data, encoding: .utf8) else {
            return compactSummary
        }
        return encoded
    }
}
