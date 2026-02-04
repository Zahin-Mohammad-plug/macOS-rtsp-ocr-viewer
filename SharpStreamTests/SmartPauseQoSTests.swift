//
//  SmartPauseQoSTests.swift
//  SharpStreamTests
//
//  Unit tests for Smart Pause adaptive QoS transitions.
//

import XCTest
@testable import SharpStream

final class SmartPauseQoSTests: XCTestCase {

    func testDegradeByConsecutiveCPUThresholds() {
        let manager = StreamManager()
        manager.connectionState = .connected

        manager.updateSmartPauseQoS(cpuUsage: 9.0, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 9.0, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .normal)

        manager.updateSmartPauseQoS(cpuUsage: 9.0, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        manager.updateSmartPauseQoS(cpuUsage: 13.0, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 13.0, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        manager.updateSmartPauseQoS(cpuUsage: 13.0, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)
    }

    func testDegradeByMemoryPressureAndRecoverWithHysteresis() {
        let manager = StreamManager()
        manager.connectionState = .connected

        manager.updateSmartPauseQoS(cpuUsage: 3.0, memoryPressure: .warning)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        manager.updateSmartPauseQoS(cpuUsage: 3.0, memoryPressure: .critical)
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)

        for _ in 0..<9 {
            manager.updateSmartPauseQoS(cpuUsage: 5.0, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)

        manager.updateSmartPauseQoS(cpuUsage: 5.0, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)

        for _ in 0..<10 {
            manager.updateSmartPauseQoS(cpuUsage: 5.0, memoryPressure: .normal)
        }
        XCTAssertEqual(manager.smartPauseSamplingTier, .normal)
    }

    func testQoSResetsToNormalWithoutActivePlayback() {
        let manager = StreamManager()
        manager.connectionState = .connected

        manager.updateSmartPauseQoS(cpuUsage: 13.0, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 13.0, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 13.0, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)

        manager.connectionState = .disconnected
        manager.updateSmartPauseQoS(cpuUsage: 13.0, memoryPressure: .critical)
        XCTAssertEqual(manager.smartPauseSamplingTier, .normal)
    }

    func testSamplingFPSStatsTrackAdaptiveTier() {
        let manager = StreamManager()
        manager.connectionState = .connected

        XCTAssertEqual(manager.streamStats.smartPauseSamplingFPS, 4.0)

        manager.updateSmartPauseQoS(cpuUsage: 9.5, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 9.5, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 9.5, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .reduced)
        XCTAssertEqual(manager.streamStats.smartPauseSamplingFPS, 2.0)

        manager.updateSmartPauseQoS(cpuUsage: 13.5, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 13.5, memoryPressure: .normal)
        manager.updateSmartPauseQoS(cpuUsage: 13.5, memoryPressure: .normal)
        XCTAssertEqual(manager.smartPauseSamplingTier, .minimal)
        XCTAssertEqual(manager.streamStats.smartPauseSamplingFPS, 1.0)
    }
}
