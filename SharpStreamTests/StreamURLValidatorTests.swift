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

    func testSeekModeClassification() {
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .file, duration: nil), .disabled)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .file, duration: 120), .absolute)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .rtsp, duration: nil), .liveBuffered)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .rtsp, duration: 120), .absolute)
    }

    func testReconnectPolicyNetworkOnly() {
        XCTAssertTrue(StreamManager.shouldAutoReconnect(protocolType: .rtsp, userInitiatedDisconnect: false))
        XCTAssertTrue(StreamManager.shouldAutoReconnect(protocolType: .https, userInitiatedDisconnect: false))
        XCTAssertFalse(StreamManager.shouldAutoReconnect(protocolType: .file, userInitiatedDisconnect: false))
        XCTAssertFalse(StreamManager.shouldAutoReconnect(protocolType: .rtsp, userInitiatedDisconnect: true))
    }

    func testRecentStreamUseCountIncrements() throws {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-db-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let database = StreamDatabase(baseDirectory: baseDirectory)
        database.clearRecentStreams()

        database.addRecentStream(url: "rtsp://example.com/live")
        database.addRecentStream(url: "rtsp://example.com/live")
        database.addRecentStream(url: "file:///tmp/test.mp4")

        let recents = database.getRecentStreams(limit: 5)
        let rtspEntry = recents.first(where: { $0.url.hasPrefix("rtsp://example.com/live") })
        XCTAssertNotNil(rtspEntry, "Expected RTSP entry in recents. Got: \(recents.map { "\($0.url) (\($0.useCount))" })")
        XCTAssertGreaterThanOrEqual(rtspEntry?.useCount ?? 0, 2)
    }

    func testBufferIndexSaveLifecycle() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-tests-\(UUID().uuidString)", isDirectory: true)
        let diskPath = tempRoot.appendingPathComponent("disk", isDirectory: true)
        let indexPath = tempRoot.appendingPathComponent("buffer_index.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bufferManager = BufferManager(diskBufferPath: diskPath, bufferIndexPath: indexPath)

        await bufferManager.startIndexSaveTimer(streamURL: "rtsp://example.com/live", saveInterval: 0.1)
        try? await Task.sleep(nanoseconds: 350_000_000)
        await bufferManager.stopIndexSaveTask()

        XCTAssertTrue(FileManager.default.fileExists(atPath: indexPath.path))
        let recovery = await bufferManager.getRecoveryData()
        let recoveredURL = await MainActor.run { recovery?.streamURL }
        XCTAssertEqual(recoveredURL, "rtsp://example.com/live")

        let firstModified = try indexPath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try? await Task.sleep(nanoseconds: 350_000_000)
        let secondModified = try indexPath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        XCTAssertEqual(firstModified, secondModified, "Index should stop updating after stopIndexSaveTask()")
    }
}
