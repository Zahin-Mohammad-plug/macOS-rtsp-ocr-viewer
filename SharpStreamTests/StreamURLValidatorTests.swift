//
//  StreamURLValidatorTests.swift
//  SharpStreamTests
//
//  Unit tests for stream URL validation
//

import XCTest
@testable import SharpStream

final class StreamURLValidatorTests: XCTestCase {
    
    func testValidRTSPURL() {
        let result = StreamURLValidator.validate("rtsp://example.com:554/stream")
        XCTAssertTrue(result.isValid, "Valid RTSP URL should pass validation")
    }

    func testValidRTSPLivePathURL() {
        let result = StreamURLValidator.validate("rtsp://example.com:554/live")
        XCTAssertTrue(result.isValid, "Valid RTSP URL with /live path should pass validation")
    }
    
    func testInvalidRTSPURL() {
        let result = StreamURLValidator.validate("rtsp://")
        XCTAssertFalse(result.isValid, "Invalid RTSP URL should fail validation")
        XCTAssertNotNil(result.errorMessage)
    }
    
    func testValidSRTURL() {
        let result = StreamURLValidator.validate("srt://example.com:9000")
        XCTAssertTrue(result.isValid, "Valid SRT URL should pass validation")
    }
    
    func testValidHLSURL() {
        let result = StreamURLValidator.validate("https://example.com/stream.m3u8")
        XCTAssertTrue(result.isValid, "Valid HLS URL should pass validation")
    }
    
    func testValidFileURL() {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.mp4")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let result = StreamURLValidator.validate("file://\(tempFile.path)")
        XCTAssertTrue(result.isValid, "Valid file URL should pass validation")
    }
    
    func testEmptyURL() {
        let result = StreamURLValidator.validate("")
        XCTAssertFalse(result.isValid, "Empty URL should fail validation")
    }
    
    func testUnknownProtocol() {
        let result = StreamURLValidator.validate("invalid://example.com")
        XCTAssertFalse(result.isValid, "Unknown protocol should fail validation")
    }

    func testTestStreamConfigParsesPrimaryAndList() {
        let config = TestStreamConfig(environment: [
            "SHARPSTREAM_TEST_RTSP_URL": "rtsp://example.com:554/live",
            "SHARPSTREAM_TEST_VIDEO_FILE": "/tmp/test.mp4",
            "SHARPSTREAM_TEST_STREAMS": "rtsp://a/live, https://example.com/test.m3u8"
        ])

        XCTAssertEqual(config.primaryRTSPURL, "rtsp://example.com:554/live")
        XCTAssertEqual(config.videoFilePath, "/tmp/test.mp4")
        XCTAssertEqual(config.streamList.count, 2)
        XCTAssertEqual(config.preferredStreamForSmokeTests, "rtsp://example.com:554/live")
    }

    func testTestStreamConfigHandlesMissingValues() {
        let config = TestStreamConfig(environment: [:])
        XCTAssertNil(config.primaryRTSPURL)
        XCTAssertNil(config.videoFilePath)
        XCTAssertTrue(config.streamList.isEmpty)
        XCTAssertNil(config.preferredStreamForSmokeTests)
    }
}
