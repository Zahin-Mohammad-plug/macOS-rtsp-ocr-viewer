//
//  MPVCacheRangeTests.swift
//  SharpStreamTests
//
//  Tests for MPV cache range window calculation.
//

import XCTest
@testable import SharpStream

final class MPVCacheRangeTests: XCTestCase {
    func testWindowCalculationUsesMinStartAndMaxEnd() {
        let ranges: [(start: Double, end: Double)] = [
            (start: 5, end: 20),
            (start: 0, end: 12),
            (start: 18, end: 30)
        ]
        let window = MPVPlayerWrapper.windowSecondsForSeekableRanges(ranges)
        XCTAssertEqual(window, 30)
    }

    func testWindowCalculationReturnsNilForEmptyRanges() {
        XCTAssertNil(MPVPlayerWrapper.windowSecondsForSeekableRanges([]))
    }

    func testWindowCalculationIgnoresNegativeSpan() {
        let ranges: [(start: Double, end: Double)] = [
            (start: 10, end: 5)
        ]
        let window = MPVPlayerWrapper.windowSecondsForSeekableRanges(ranges)
        XCTAssertNil(window)
    }
}
