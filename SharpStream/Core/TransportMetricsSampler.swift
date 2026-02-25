//
//  TransportMetricsSampler.swift
//  SharpStream
//
//  Lightweight (1 Hz) transport sampling and proxy health estimation.
//

import Foundation

struct TransportMetricsSampler {
    struct Output: Equatable {
        let rxRateBps: Int?
        let bufferLevelSeconds: Double?
        let jitterProxyMs: Double?
        let packetLossProxyPct: Double?
        let streamHealth: StreamHealth
        let streamHealthReason: String?
        let keyframeIntervalSeconds: Double?
    }

    private struct Sample {
        let timestamp: Date
        let rxRateBps: Int
        let bufferLevelSeconds: Double?
    }

    private var samples: [Sample] = []
    private var reconnectEvents: [Date] = []
    private var failureEvents: [Date] = []
    private var consecutiveNoRxWhilePlaying = 0
    private var lastLagSeconds: TimeInterval?
    private var lastKeyframeAt: Date?
    private var estimatedKeyframeIntervalSeconds: Double?
    private var lastTotalBytesSample: (timestamp: Date, totalBytes: Int64)?

    mutating func reset() {
        samples.removeAll()
        reconnectEvents.removeAll()
        failureEvents.removeAll()
        consecutiveNoRxWhilePlaying = 0
        lastLagSeconds = nil
        lastKeyframeAt = nil
        estimatedKeyframeIntervalSeconds = nil
        lastTotalBytesSample = nil
    }

    mutating func markReconnectEvent(at timestamp: Date = Date()) {
        reconnectEvents.append(timestamp)
        pruneEvents(now: timestamp)
    }

    mutating func markFailureEvent(at timestamp: Date = Date()) {
        failureEvents.append(timestamp)
        pruneEvents(now: timestamp)
    }

    mutating func ingest(
        timestamp: Date = Date(),
        isConnected: Bool,
        isConnecting: Bool,
        isReconnecting: Bool,
        hasError: Bool,
        errorMessage: String?,
        isPlaying: Bool,
        lagSeconds: TimeInterval,
        rxRateBps: Int?,
        totalBytesRead: Int64? = nil,
        bufferLevelSeconds: Double?,
        frameType: String?
    ) -> Output {
        pruneEvents(now: timestamp)

        let effectiveRxRateBps = resolveRxRateBps(
            timestamp: timestamp,
            explicitRxRateBps: rxRateBps,
            totalBytesRead: totalBytesRead
        )

        if let effectiveRxRateBps, effectiveRxRateBps > 0 {
            samples.append(Sample(timestamp: timestamp, rxRateBps: effectiveRxRateBps, bufferLevelSeconds: bufferLevelSeconds))
            consecutiveNoRxWhilePlaying = 0
        } else if isPlaying {
            consecutiveNoRxWhilePlaying += 1
        } else {
            consecutiveNoRxWhilePlaying = 0
        }
        pruneSamples(now: timestamp)

        if let frameType = frameType?.uppercased(), frameType.hasPrefix("I") {
            if let lastKeyframeAt {
                let interval = timestamp.timeIntervalSince(lastKeyframeAt)
                if interval.isFinite, interval >= 0.2, interval <= 30 {
                    estimatedKeyframeIntervalSeconds = interval
                }
            }
            lastKeyframeAt = timestamp
        }

        let reconnectCount30 = reconnectEvents.filter { timestamp.timeIntervalSince($0) <= 30 }.count
        let failureCount30 = failureEvents.filter { timestamp.timeIntervalSince($0) <= 30 }.count

        let jitterProxyMs = computeJitterProxyMs() ?? (effectiveRxRateBps != nil ? 0 : nil)
        let packetLossProxyPct = computePacketLossProxyPct(
            isPlaying: isPlaying,
            reconnectCount30: reconnectCount30,
            failureCount30: failureCount30,
            jitterProxyMs: jitterProxyMs,
            bufferLevelSeconds: bufferLevelSeconds
        )

        let lagDelta: TimeInterval
        if let lastLagSeconds {
            lagDelta = lagSeconds - lastLagSeconds
        } else {
            lagDelta = 0
        }
        self.lastLagSeconds = lagSeconds

        let health = computeHealth(
            isConnected: isConnected,
            isConnecting: isConnecting,
            isReconnecting: isReconnecting,
            hasError: hasError,
            errorMessage: errorMessage,
            isPlaying: isPlaying,
            lagDelta: lagDelta,
            reconnectCount30: reconnectCount30,
            packetLossProxyPct: packetLossProxyPct,
            jitterProxyMs: jitterProxyMs,
            bufferLevelSeconds: bufferLevelSeconds
        )

        return Output(
            rxRateBps: effectiveRxRateBps,
            bufferLevelSeconds: bufferLevelSeconds,
            jitterProxyMs: jitterProxyMs,
            packetLossProxyPct: packetLossProxyPct,
            streamHealth: health.health,
            streamHealthReason: health.reason,
            keyframeIntervalSeconds: estimatedKeyframeIntervalSeconds
        )
    }

    private mutating func resolveRxRateBps(
        timestamp: Date,
        explicitRxRateBps: Int?,
        totalBytesRead: Int64?
    ) -> Int? {
        if let explicitRxRateBps, explicitRxRateBps > 0 {
            if let totalBytesRead, totalBytesRead >= 0 {
                lastTotalBytesSample = (timestamp, totalBytesRead)
            }
            return explicitRxRateBps
        }

        guard let totalBytesRead, totalBytesRead >= 0 else {
            return nil
        }
        defer {
            lastTotalBytesSample = (timestamp, totalBytesRead)
        }

        guard let prior = lastTotalBytesSample else {
            return nil
        }

        let deltaBytes = totalBytesRead - prior.totalBytes
        let deltaTime = timestamp.timeIntervalSince(prior.timestamp)
        guard deltaBytes > 0, deltaTime > 0.2, deltaTime < 10 else {
            return nil
        }

        let bytesPerSecond = Double(deltaBytes) / deltaTime
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else {
            return nil
        }

        return Int(bytesPerSecond.rounded())
    }

    private mutating func pruneEvents(now: Date) {
        reconnectEvents = reconnectEvents.filter { now.timeIntervalSince($0) <= 120 }
        failureEvents = failureEvents.filter { now.timeIntervalSince($0) <= 120 }
    }

    private mutating func pruneSamples(now: Date) {
        samples = samples.filter { now.timeIntervalSince($0.timestamp) <= 15 }
    }

    private func computeJitterProxyMs() -> Double? {
        let recentRates = samples.map { Double($0.rxRateBps) }.filter { $0 > 0 }
        guard recentRates.count >= 3 else { return nil }

        let mean = recentRates.reduce(0, +) / Double(recentRates.count)
        guard mean > 0 else { return nil }

        let variance = recentRates
            .map { pow($0 - mean, 2) }
            .reduce(0, +) / Double(recentRates.count)
        let stdDev = sqrt(variance)
        let coefficientOfVariation = stdDev / mean
        let rateComponent = coefficientOfVariation * 1000

        let buffers = samples.compactMap { $0.bufferLevelSeconds }
        let bufferDeltas = zip(buffers.dropFirst(), buffers).map { abs($0 - $1) }
        let bufferComponent: Double
        if bufferDeltas.isEmpty {
            bufferComponent = 0
        } else {
            bufferComponent = (bufferDeltas.reduce(0, +) / Double(bufferDeltas.count)) * 250
        }

        return min(5000, max(0, rateComponent + bufferComponent))
    }

    private func computePacketLossProxyPct(
        isPlaying: Bool,
        reconnectCount30: Int,
        failureCount30: Int,
        jitterProxyMs: Double?,
        bufferLevelSeconds: Double?
    ) -> Double {
        var proxy = 0.0

        proxy += Double(reconnectCount30 * 18)
        proxy += Double(failureCount30 * 12)

        if isPlaying && consecutiveNoRxWhilePlaying >= 2 {
            proxy += min(40, Double((consecutiveNoRxWhilePlaying - 1) * 15))
        }
        if let jitterProxyMs, jitterProxyMs > 200 {
            proxy += min(25, (jitterProxyMs - 200) / 20)
        }
        if isPlaying, let bufferLevelSeconds, bufferLevelSeconds < 0.5 {
            proxy += 20
        }

        return min(100, max(0, proxy))
    }

    private func computeHealth(
        isConnected: Bool,
        isConnecting: Bool,
        isReconnecting: Bool,
        hasError: Bool,
        errorMessage: String?,
        isPlaying: Bool,
        lagDelta: TimeInterval,
        reconnectCount30: Int,
        packetLossProxyPct: Double,
        jitterProxyMs: Double?,
        bufferLevelSeconds: Double?
    ) -> (health: StreamHealth, reason: String?) {
        if hasError {
            return (.critical, errorMessage ?? "Player error")
        }
        if isReconnecting {
            return (.critical, "Reconnecting")
        }
        if isConnecting {
            return (.degraded, "Connecting")
        }
        if !isConnected {
            return (.critical, "Disconnected")
        }

        if isPlaying, let bufferLevelSeconds, bufferLevelSeconds < 0.25 {
            return (.critical, "Buffer nearly empty")
        }
        if packetLossProxyPct >= 35 {
            return (.critical, "High loss proxy")
        }

        let lagGrowingQuickly = isPlaying && lagDelta > 1.5
        if reconnectCount30 > 0 {
            return (.degraded, "Recent reconnects")
        }
        if packetLossProxyPct >= 12 {
            return (.degraded, "Loss proxy elevated")
        }
        if let jitterProxyMs, jitterProxyMs >= 150 {
            return (.degraded, "Jitter proxy elevated")
        }
        if lagGrowingQuickly {
            return (.degraded, "Playback lag growing")
        }

        return (.good, "Stable")
    }
}
