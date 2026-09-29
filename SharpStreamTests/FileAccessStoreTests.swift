//
//  FileAccessStoreTests.swift
//  SharpStreamTests
//
//  Security-scoped bookmark persistence for local files.
//

import XCTest
@testable import SharpStream

@MainActor
final class FileAccessStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var fileURL: URL!

    override func setUpWithError() throws {
        suiteName = "FileAccessStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-\(UUID().uuidString).mp4")
        try Data([0, 1, 2, 3]).write(to: fileURL)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testRememberedFileResolvesToSameFile() {
        let store = FileAccessStore(defaults: defaults)
        store.remember(fileURL)

        let resolved = store.beginAccess(for: fileURL.absoluteString)
        defer { store.endAccess() }

        XCTAssertEqual(URL(string: resolved)?.standardizedFileURL.resolvingSymlinksInPath().path,
                       fileURL.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testUnknownFilePassesThroughUnchanged() {
        let store = FileAccessStore(defaults: defaults)
        XCTAssertEqual(store.beginAccess(for: fileURL.absoluteString), fileURL.absoluteString)
        XCTAssertEqual(store.beginAccess(for: "rtsp://camera/live"), "rtsp://camera/live")
    }

    func testDisabledPersistenceStoresNothing() {
        let store = FileAccessStore(defaults: defaults)
        store.isPersistenceEnabled = false
        store.remember(fileURL)
        XCTAssertNil(defaults.dictionary(forKey: "securityScopedFileBookmarks"))
    }
}
