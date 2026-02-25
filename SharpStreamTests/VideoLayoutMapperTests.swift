//
//  VideoLayoutMapperTests.swift
//  SharpStreamTests
//

import XCTest
@testable import SharpStream

final class VideoLayoutMapperTests: XCTestCase {
    func testVideoRectFillsContainerWhenAspectMatches() {
        let rect = VideoLayoutMapper.videoRect(
            container: CGSize(width: 1920, height: 1080),
            source: CGSize(width: 1280, height: 720)
        )

        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1920, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1080, accuracy: 0.001)
    }

    func testVideoRectLetterboxesWhenContainerIsSquare() {
        let rect = VideoLayoutMapper.videoRect(
            container: CGSize(width: 1000, height: 1000),
            source: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 218.75, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.height, 562.5, accuracy: 0.001)
    }

    func testMapVisionBoxCenter() {
        let mapped = VideoLayoutMapper.mapVisionBox(
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            in: CGRect(x: 10, y: 20, width: 1000, height: 500)
        )

        XCTAssertEqual(mapped.origin.x, 260, accuracy: 0.001)
        XCTAssertEqual(mapped.origin.y, 145, accuracy: 0.001)
        XCTAssertEqual(mapped.width, 500, accuracy: 0.001)
        XCTAssertEqual(mapped.height, 250, accuracy: 0.001)
    }

    func testMapVisionBoxTopLeft() {
        let mapped = VideoLayoutMapper.mapVisionBox(
            CGRect(x: 0.0, y: 0.8, width: 0.2, height: 0.2),
            in: CGRect(x: 50, y: 100, width: 800, height: 400)
        )

        XCTAssertEqual(mapped.origin.x, 50, accuracy: 0.001)
        XCTAssertEqual(mapped.origin.y, 100, accuracy: 0.001)
        XCTAssertEqual(mapped.width, 160, accuracy: 0.001)
        XCTAssertEqual(mapped.height, 80, accuracy: 0.001)
    }
}
