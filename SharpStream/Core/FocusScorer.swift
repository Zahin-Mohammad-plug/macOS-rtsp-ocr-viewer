//
//  FocusScorer.swift
//  SharpStream
//
//  Focus scoring coordinator and Smart Pause candidate store.
//
//  Memory model: every scored frame is recorded as a lightweight sample
//  (timestamp + score) for statistics. Full-resolution pixel buffers are kept
//  only for frames that can still be the sharpest frame of *some* lookback
//  window ending now — i.e. frames not beaten by any newer frame. That set is
//  typically a handful of frames, so memory stays bounded regardless of how
//  long the stream runs or how high its resolution is.
//
//  Thread safety: scoreFrame may be called from any thread; all state is
//  guarded by a lock. Scoring itself runs outside the lock.
//

import Foundation
import CoreVideo
import Combine

nonisolated final class FocusScorer: ObservableObject {
    @Published private(set) var algorithm: FocusAlgorithm = .laplacian

    /// Candidates older than this (relative to the newest frame) are dropped.
    var candidateRetention: TimeInterval = 8.0
    /// Score samples older than this are dropped (used for FPS / counts).
    var sampleRetention: TimeInterval = 30.0

    private struct Sample {
        let timestamp: Date
        let score: Double
    }

    private let lock = NSLock()
    private var currentAlgorithm: FocusAlgorithm = .laplacian
    private var candidates: [FrameScore] = [] // sorted by timestamp, scores strictly decreasing
    private var samples: [Sample] = []        // sorted by timestamp

    init() {}

    @discardableResult
    func scoreFrame(
        _ pixelBuffer: CVPixelBuffer,
        timestamp: Date,
        playbackTime: TimeInterval? = nil,
        sequenceNumber: Int
    ) -> FrameScore {
        let algorithm = lock.withLock { currentAlgorithm }
        let score = SharpnessMetrics.score(pixelBuffer, algorithm: algorithm)
        let frameScore = FrameScore(
            timestamp: timestamp,
            score: score,
            playbackTime: playbackTime,
            pixelBuffer: pixelBuffer,
            sequenceNumber: sequenceNumber
        )
        record(frameScore)
        return frameScore
    }

    private func record(_ frame: FrameScore) {
        lock.withLock {
            samples.append(Sample(timestamp: frame.timestamp, score: frame.score))
            if samples.count > 1, samples[samples.count - 2].timestamp > frame.timestamp {
                samples.sort { $0.timestamp < $1.timestamp }
            }

            // A candidate that is not newer and not sharper than this frame can
            // never be the best frame of a window that ends at/after this frame.
            candidates.removeAll { $0.timestamp <= frame.timestamp && $0.score <= frame.score }
            let insertIndex = candidates.firstIndex { $0.timestamp > frame.timestamp } ?? candidates.endIndex
            candidates.insert(frame, at: insertIndex)

            let newest = max(frame.timestamp, candidates.last?.timestamp ?? frame.timestamp)
            let candidateCutoff = newest.addingTimeInterval(-candidateRetention)
            candidates.removeAll { $0.timestamp < candidateCutoff }
            let sampleCutoff = newest.addingTimeInterval(-sampleRetention)
            if let firstKept = samples.firstIndex(where: { $0.timestamp >= sampleCutoff }), firstKept > 0 {
                samples.removeFirst(firstKept)
            }
        }
    }

    func findBestFrame(in timeRange: TimeInterval, now: Date = Date()) -> FrameScore? {
        let cutoff = now.addingTimeInterval(-timeRange)
        return lock.withLock {
            candidates
                .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
                .max { $0.score < $1.score }
        }
    }

    func recentFrameCount(in timeRange: TimeInterval, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-timeRange)
        return lock.withLock {
            samples.reduce(0) { $0 + (($1.timestamp >= cutoff && $1.timestamp <= now) ? 1 : 0) }
        }
    }

    func frame(sequenceNumber: Int) -> FrameScore? {
        lock.withLock { candidates.first { $0.sequenceNumber == sequenceNumber } }
    }

    func selectBestFrame(
        in timeRange: TimeInterval,
        now: Date = Date(),
        currentPlaybackTime: TimeInterval?,
        seekMode: SeekMode
    ) -> SmartPauseSelection? {
        guard let bestFrame = findBestFrame(in: timeRange, now: now) else {
            return nil
        }

        let frameAge = max(0, now.timeIntervalSince(bestFrame.timestamp))
        let playbackTarget: TimeInterval?

        if let framePlaybackTime = bestFrame.playbackTime {
            playbackTarget = framePlaybackTime
        } else if let currentPlaybackTime {
            playbackTarget = max(0, currentPlaybackTime - frameAge)
        } else {
            playbackTarget = nil
        }

        return SmartPauseSelection(
            sequenceNumber: bestFrame.sequenceNumber,
            score: bestFrame.score,
            frameTimestamp: bestFrame.timestamp,
            playbackTime: playbackTarget,
            frameAge: frameAge,
            seekMode: seekMode
        )
    }

    func getCurrentScore() -> Double? {
        lock.withLock { samples.last?.score }
    }

    func getScoringFPS(now: Date = Date()) -> Double {
        lock.withLock {
            let window: TimeInterval = 5
            let cutoff = now.addingTimeInterval(-window)
            let recent = samples.filter { $0.timestamp >= cutoff }
            guard recent.count >= 2,
                  let first = recent.first, let last = recent.last else { return 0 }
            let span = last.timestamp.timeIntervalSince(first.timestamp)
            return span > 0 ? Double(recent.count - 1) / span : 0
        }
    }

    /// Approximate memory held by retained candidate frames, in bytes.
    func retainedFrameBytes() -> Int {
        lock.withLock {
            candidates.reduce(0) { total, frame in
                guard let buffer = frame.pixelBuffer else { return total }
                return total + CVPixelBufferGetDataSize(buffer)
            }
        }
    }

    func reset() {
        lock.withLock {
            candidates.removeAll()
            samples.removeAll()
        }
    }

    func setAlgorithm(_ algorithm: FocusAlgorithm) {
        lock.withLock { currentAlgorithm = algorithm }
        if Thread.isMainThread {
            self.algorithm = algorithm
        } else {
            DispatchQueue.main.async { self.algorithm = algorithm }
        }
    }
}
