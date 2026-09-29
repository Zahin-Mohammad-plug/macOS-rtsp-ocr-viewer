//
//  SmartPauseQoSTests.swift
//  SharpStreamTests
//
//  Unit tests for Smart Pause adaptive QoS transitions.
//

import XCTest
@testable import SharpStream

@MainActor
final class SmartPauseQoSTests: XCTestCase {

    func testDegradeByConsecutiveCaptureLoad() {
        let manager = StreamManager()
        manager.connectionState = .connected

        manager.updateSmartPauseQoS(pipelineLoad: 0.5, memoryPressure: .normal)
        manager.updateSmartPauseQoS(pipelineLoad: 0.5, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .normal)

        manager.updateSmartPauseQoS(pipelineLoad: 0.5, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        manager.updateSmartPauseQoS(pipelineLoad: 0.9, memoryPressure: .normal)
        manager.updateSmartPauseQoS(pipelineLoad: 0.9, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        manager.updateSmartPauseQoS(pipelineLoad: 0.9, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)
    }

    func testTypicalLoadStaysAtFullRate() {
        // Regression: total process CPU used to drive this, so ordinary video
        // decode pinned sampling at 1 FPS. Cheap capture must keep 4 FPS.
        let manager = StreamManager()
        manager.connectionState = .connected
        for _ in 0..<30 {
            manager.updateSmartPauseQoS(pipelineLoad: 0.08, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .normal)
    }

    func testDegradeByMemoryPressureAndRecoverWithHysteresis() {
        let manager = StreamManager()
        manager.connectionState = .connected

        manager.updateSmartPauseQoS(pipelineLoad: 0.05, memoryPressure: .warning)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        manager.updateSmartPauseQoS(pipelineLoad: 0.05, memoryPressure: .critical)
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)

        for _ in 0..<9 {
            manager.updateSmartPauseQoS(pipelineLoad: 0.05, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)

        manager.updateSmartPauseQoS(pipelineLoad: 0.05, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        for _ in 0..<10 {
            manager.updateSmartPauseQoS(pipelineLoad: 0.05, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .normal)
    }

    func testQoSResetsToNormalWithoutActivePlayback() {
        let manager = StreamManager()
        manager.connectionState = .connected

        for _ in 0..<3 {
            manager.updateSmartPauseQoS(pipelineLoad: 0.95, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)

        manager.connectionState = .disconnected
        manager.updateSmartPauseQoS(pipelineLoad: 0.95, memoryPressure: .critical)
        XCTAssertEqual(manager.smartPauseSamplingTier, .normal)
    }

    func testSamplingFPSStatsTrackAdaptiveTier() {
        let manager = StreamManager()
        manager.connectionState = .connected

        XCTAssertEqual(manager.streamStats.smartPauseSamplingFPS, 4.0)

        for _ in 0..<3 {
            manager.updateSmartPauseQoS(pipelineLoad: 0.5, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)
        XCTAssertEqual(manager.streamStats.smartPauseSamplingFPS, 2.0)

        for _ in 0..<3 {
            manager.updateSmartPauseQoS(pipelineLoad: 0.8, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)
        XCTAssertEqual(manager.streamStats.smartPauseSamplingFPS, 1.0)
    }
}
