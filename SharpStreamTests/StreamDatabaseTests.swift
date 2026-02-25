//
//  StreamDatabaseTests.swift
//  SharpStreamTests
//

import XCTest
@testable import SharpStream

final class StreamDatabaseTests: XCTestCase {
    func testSaveOrUpdateByURLCreatesNewEntry() throws {
        var database: StreamDatabase? = makeDatabase()
        defer { database = nil }

        let saved = try database!.saveOrUpdateByURL(
            name: "Camera 1",
            url: "rtsp://example.com:554/live/1_0",
            protocolType: .rtsp,
            lastUsed: nil
        )

        let streams = database!.getAllStreams()
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?.id, saved.id)
        XCTAssertEqual(streams.first?.name, "Camera 1")
    }

    func testSaveOrUpdateByURLUpdatesExistingEntryByURL() throws {
        var database: StreamDatabase? = makeDatabase()
        defer { database = nil }

        let first = try database!.saveOrUpdateByURL(
            name: "Old Name",
            url: "RTSP://Example.com:554/live/1_0",
            protocolType: .rtsp,
            lastUsed: nil
        )

        let updatedDate = Date()
        let second = try database!.saveOrUpdateByURL(
            name: "New Name",
            url: "rtsp://example.com:554/live/1_0",
            protocolType: .rtsp,
            lastUsed: updatedDate
        )

        let streams = database!.getAllStreams()
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(streams.first?.name, "New Name")
        XCTAssertEqual(streams.first?.id, first.id)
    }

    private func makeDatabase() -> StreamDatabase {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamDatabaseTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        return StreamDatabase(baseDirectory: tempDirectory)
    }
}
