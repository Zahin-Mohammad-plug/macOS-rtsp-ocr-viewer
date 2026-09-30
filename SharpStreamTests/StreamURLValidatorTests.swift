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
    
    /// The bundled FFmpeg has no libsrt; SRT must fail up front with guidance
    /// instead of connecting and reconnecting forever.
    func testSRTIsRejectedWithGuidance() {
        for url in ["srt://example.com:9000", "srt://example.com:20001?mode=listener"] {
            let result = StreamURLValidator.validate(url)
            XCTAssertFalse(result.isValid)
            XCTAssertEqual(result.errorMessage, StreamURLValidator.srtUnsupportedMessage)
        }
    }
    
    func testValidHLSURL() {
        let result = StreamURLValidator.validate("https://example.com/stream.m3u8")
        XCTAssertTrue(result.isValid, "Valid HLS URL should pass validation")
    }

    func testHLSDetectionForHTTPM3U8() {
        XCTAssertEqual(StreamProtocol.detect(from: "http://192.0.2.10/hls/1_0.m3u8"), .hls)
        XCTAssertEqual(StreamProtocol.detect(from: "https://example.com/live/index.m3u8"), .hls)
    }

    func testHTTPDetectionWithoutM3U8() {
        XCTAssertEqual(StreamProtocol.detect(from: "http://example.com/video.mp4"), .http)
        XCTAssertEqual(StreamProtocol.detect(from: "https://example.com/api/status"), .https)
    }

    func testStreamURLRedactionDropsCredentialsAndQuery() {
        let redacted = StreamURLRedactor.redacted("srt://user:secret@192.168.1.10:9000?passphrase=abc&mode=caller")
        XCTAssertEqual(redacted, "srt://192.168.1.10:9000")
    }

    func testWaitingForInboundCallerMessage() {
        XCTAssertEqual(
            ConnectionTestResult.waitingForInboundCaller.errorMessage,
            "Listener is ready. Waiting for inbound caller to connect."
        )
    }
    
    func testValidFileURL() {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.mp4")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let result = StreamURLValidator.validate("file://\(tempFile.path)")
        XCTAssertTrue(result.isValid, "Valid file URL should pass validation")
    }

    func testValidAbsoluteFilePath() {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-path.mov")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = StreamURLValidator.validate(tempFile.path)
        XCTAssertTrue(result.isValid, "Valid absolute file path should pass validation")
        XCTAssertEqual(StreamProtocol.detect(from: tempFile.path), .file)
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
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .rtsp, duration: 120), .liveBuffered)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .hls, duration: nil), .liveBuffered)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .hls, duration: 120), .absolute)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .http, duration: 120), .absolute)
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

    func testSchemesAreCaseInsensitiveAndRTSPSIsSupported() {
        XCTAssertTrue(StreamURLValidator.validate("RTSP://camera.local:8554/cam").isValid)
        XCTAssertTrue(StreamURLValidator.validate("rtsps://camera.local:322/cam").isValid)
        XCTAssertEqual(StreamProtocol.detect(from: "rtsps://camera.local/cam"), .rtsp)
        XCTAssertTrue(StreamURLValidator.validate("  rtsp://camera.local/cam\n").isValid)
    }

    func testUnknownSchemeIsNotGuessedAsHLS() {
        XCTAssertEqual(StreamProtocol.detect(from: "foohls://example.com/live"), .unknown)
        XCTAssertFalse(StreamURLValidator.validate("foohls://example.com/live").isValid)
    }

    func testHLSPlaylistLiveVersusVOD() {
        let live = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:40\n#EXTINF:2,\nseg40.ts\n"
        let vod = live + "#EXT-X-ENDLIST\n"
        let vodType = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2,\nseg0.ts\n"
        XCTAssertEqual(HLSPlaylistProbe.classify(live), true)
        XCTAssertEqual(HLSPlaylistProbe.classify(vod), false)
        XCTAssertEqual(HLSPlaylistProbe.classify(vodType), false)
        XCTAssertNil(HLSPlaylistProbe.classify("<html>not a playlist</html>"))

        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n\nmain_stream.m3u8?session=1\n"
        XCTAssertEqual(HLSPlaylistProbe.firstVariantURI(in: master), "main_stream.m3u8?session=1")
    }

    func testLiveHLSIsLiveEvenWithReportedDuration() {
        // mpv reports a duration for live HLS windows; the playlist probe wins.
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .hls, duration: 12, isLive: true), .liveBuffered)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .hls, duration: 12, isLive: false), .absolute)
        XCTAssertEqual(StreamManager.classifySeekMode(protocolType: .hls, duration: 12), .absolute)
    }

    func testSessionRecoveryLifecycle() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("session_recovery.json")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = SessionRecoveryStore(fileURL: fileURL)
        XCTAssertNil(store.load())

        let now = Date()
        store.markActive(streamURL: "rtsp://example.com/live", streamName: "Camera", now: now)
        XCTAssertEqual(store.load(now: now)?.streamURL, "rtsp://example.com/live")
        XCTAssertEqual(store.load(now: now)?.streamName, "Camera")

        // Stale sessions are not offered for resume.
        XCTAssertNil(store.load(now: now.addingTimeInterval(store.maxAge + 1)))

        // A clean disconnect/quit clears the marker.
        store.clear()
        XCTAssertNil(store.load(now: now))
    }
}
