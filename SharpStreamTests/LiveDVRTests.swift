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
}
