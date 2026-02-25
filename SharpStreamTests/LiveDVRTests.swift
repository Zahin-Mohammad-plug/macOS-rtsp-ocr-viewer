//
//  LiveDVRTests.swift
//  SharpStreamTests
//
//  Tests for live DVR lag estimation and window handling.
//

import XCTest
@testable import SharpStream

final class LiveDVRTests: XCTestCase {
    func testLagStaysNearZeroWhenPlaybackKeepsUp() {
        let base = Date()
        let window = StreamManager.resolveLiveWindowSeconds(
            mpvWindow: nil,
            bufferDuration: 120,
            maxWindowSeconds: 600
        )
        var sample: StreamManager.LiveLagSample?

        let first = StreamManager.computeLiveDVRState(
            previousSample: sample,
            playbackTime: 100,
            now: base,
            windowSeconds: window,
            isPlaying: true
        )
        sample = first.sample

        let second = StreamManager.computeLiveDVRState(
            previousSample: sample,
            playbackTime: 110,
            now: base.addingTimeInterval(10),
            windowSeconds: window,
            isPlaying: true
        )

        XCTAssertLessThan(second.state.lagSeconds, 0.6)
    }

    func testLagIncreasesWhenPlaybackIsPaused() {
        let base = Date()
        let window = StreamManager.resolveLiveWindowSeconds(
            mpvWindow: nil,
            bufferDuration: 120,
            maxWindowSeconds: 600
        )
        var sample: StreamManager.LiveLagSample?

        let first = StreamManager.computeLiveDVRState(
            previousSample: sample,
            playbackTime: 200,
            now: base,
            windowSeconds: window,
            isPlaying: false
        )
        sample = first.sample

        let second = StreamManager.computeLiveDVRState(
            previousSample: sample,
            playbackTime: 200,
            now: base.addingTimeInterval(5),
            windowSeconds: window,
            isPlaying: false
        )

        XCTAssertGreaterThan(second.state.lagSeconds, 4.5)
    }

    func testLagAdjustsAfterSeekBackAndForward() {
        let base = Date()
        let window = StreamManager.resolveLiveWindowSeconds(
            mpvWindow: nil,
            bufferDuration: 120,
            maxWindowSeconds: 600
        )
        var sample: StreamManager.LiveLagSample?

        let first = StreamManager.computeLiveDVRState(
            previousSample: sample,
            playbackTime: 100,
            now: base,
            windowSeconds: window,
            isPlaying: true
        )
        sample = first.sample

        let seekBack = StreamManager.computeLiveDVRState(
            previousSample: sample,
            playbackTime: 80,
            now: base.addingTimeInterval(1),
            windowSeconds: window,
            isPlaying: true
        )
        sample = seekBack.sample

        let seekForward = StreamManager.computeLiveDVRState(
            previousSample: sample,
            playbackTime: 130,
            now: base.addingTimeInterval(2),
            windowSeconds: window,
            isPlaying: true
        )

        XCTAssertGreaterThan(seekBack.state.lagSeconds, 19)
        XCTAssertLessThan(seekForward.state.lagSeconds, 5)
    }

    func testWindowClampsToMaxBufferLength() {
        let window = StreamManager.resolveLiveWindowSeconds(
            mpvWindow: nil,
            bufferDuration: 600,
            maxWindowSeconds: 120
        )

        XCTAssertLessThanOrEqual(window, 120)
    }

    func testClampLiveSeekOffset() {
        XCTAssertEqual(StreamManager.clampLiveSeekOffset(10, lagSeconds: 3), 3)
        XCTAssertEqual(StreamManager.clampLiveSeekOffset(10, lagSeconds: 0), 0)
        XCTAssertEqual(StreamManager.clampLiveSeekOffset(-10, lagSeconds: 3), -10)
    }

    func testTransportSamplerMarksCriticalDuringReconnect() {
        var sampler = TransportMetricsSampler()
        sampler.markReconnectEvent(at: Date())

        let output = sampler.ingest(
            timestamp: Date(),
            isConnected: false,
            isConnecting: false,
            isReconnecting: true,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.2,
            rxRateBps: 450_000,
            bufferLevelSeconds: 2.0,
            frameType: "P"
        )

        XCTAssertEqual(output.streamHealth, .critical)
    }

    func testTransportSamplerMarksGoodWhenStable() {
        var sampler = TransportMetricsSampler()
        let base = Date()

        _ = sampler.ingest(
            timestamp: base,
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: 500_000,
            bufferLevelSeconds: 4.0,
            frameType: "I"
        )
        _ = sampler.ingest(
            timestamp: base.addingTimeInterval(1),
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: 510_000,
            bufferLevelSeconds: 4.1,
            frameType: "P"
        )
        let output = sampler.ingest(
            timestamp: base.addingTimeInterval(2),
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: 505_000,
            bufferLevelSeconds: 4.0,
            frameType: "P"
        )

        XCTAssertEqual(output.streamHealth, .good)
        XCTAssertNotNil(output.jitterProxyMs)
    }

    func testTransportSamplerMarksDegradedWithLowRxAndGrowingLag() {
        var sampler = TransportMetricsSampler()
        let base = Date()

        _ = sampler.ingest(
            timestamp: base,
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: 300_000,
            bufferLevelSeconds: 2.5,
            frameType: "P"
        )

        let output = sampler.ingest(
            timestamp: base.addingTimeInterval(1),
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 2.2,
            rxRateBps: nil,
            bufferLevelSeconds: 1.8,
            frameType: "P"
        )

        XCTAssertTrue(output.streamHealth == .degraded || output.streamHealth == .critical)
    }

    func testTransportSamplerDerivesRxRateFromTotalBytesCounter() {
        var sampler = TransportMetricsSampler()
        let base = Date()

        _ = sampler.ingest(
            timestamp: base,
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: nil,
            totalBytesRead: 1_000_000,
            bufferLevelSeconds: 3.0,
            frameType: "P"
        )

        let second = sampler.ingest(
            timestamp: base.addingTimeInterval(1),
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: nil,
            totalBytesRead: 1_320_000,
            bufferLevelSeconds: 3.2,
            frameType: "P"
        )

        _ = sampler.ingest(
            timestamp: base.addingTimeInterval(2),
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: nil,
            totalBytesRead: 1_640_000,
            bufferLevelSeconds: 3.1,
            frameType: "P"
        )

        let fourth = sampler.ingest(
            timestamp: base.addingTimeInterval(3),
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: nil,
            totalBytesRead: 1_960_000,
            bufferLevelSeconds: 3.0,
            frameType: "P"
        )

        XCTAssertNotNil(second.rxRateBps)
        XCTAssertGreaterThan(second.rxRateBps ?? 0, 250_000)
        XCTAssertNotNil(fourth.jitterProxyMs)
    }

    func testTransportSamplerReturnsZeroJitterUntilEnoughSamples() {
        var sampler = TransportMetricsSampler()
        let output = sampler.ingest(
            timestamp: Date(),
            isConnected: true,
            isConnecting: false,
            isReconnecting: false,
            hasError: false,
            errorMessage: nil,
            isPlaying: true,
            lagSeconds: 0.1,
            rxRateBps: 200_000,
            bufferLevelSeconds: 2.0,
            frameType: "P"
        )

        XCTAssertEqual(output.jitterProxyMs, 0)
    }

    func testResolveLiveBufferSettingsKeepsBackBufferStableForSameWindow() {
        let initial = StreamManager.resolveLiveBufferSettings(
            maxWindowSeconds: 600,
            bitrate: 3_000_000,
            previousSettings: nil,
            force: false
        )
        let updated = StreamManager.resolveLiveBufferSettings(
            maxWindowSeconds: 600,
            bitrate: 12_000_000,
            previousSettings: initial,
            force: false
        )

        XCTAssertEqual(updated.maxWindowSeconds, initial.maxWindowSeconds)
        XCTAssertEqual(updated.backBufferBytes, initial.backBufferBytes)
    }

    func testResolveLiveBufferSettingsRecomputesWhenForced() {
        let initial = StreamManager.resolveLiveBufferSettings(
            maxWindowSeconds: 600,
            bitrate: 2_000_000,
            previousSettings: nil,
            force: false
        )
        let forced = StreamManager.resolveLiveBufferSettings(
            maxWindowSeconds: 600,
            bitrate: 10_000_000,
            previousSettings: initial,
            force: true
        )

        XCTAssertNotEqual(forced.backBufferBytes, initial.backBufferBytes)
    }
}
