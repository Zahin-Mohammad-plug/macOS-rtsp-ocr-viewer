//
//  FileAccessStore.swift
//  SharpStream
//
//  Keeps sandbox access to local video files across launches.
//
//  A file chosen in the Open panel or dropped on the window is readable only
//  for the current session. Saved/recent entries store just the path, so they
//  failed to reopen after a relaunch (unless the file happened to live in
//  Downloads/Movies). We store an app-scoped security bookmark per file and
//  resolve it when that file is opened again.
//

import Foundation

@MainActor
final class FileAccessStore {
    private let defaults: UserDefaults
    private let key = "securityScopedFileBookmarks"
    private var activeURL: URL?
    /// Test runs must not write bookmarks into the user's defaults.
    var isPersistenceEnabled = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Record access to a file the user just granted (Open panel, drag and drop).
    func remember(_ url: URL) {
        guard isPersistenceEnabled, url.isFileURL else { return }
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = storedBookmarks
            bookmarks[Self.key(for: url)] = data
            defaults.set(bookmarks, forKey: key)
        } catch {
            print("⚠️ Could not create bookmark for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Begin (and hold) access for `urlString` if it's a bookmarked local file.
    /// Any previously held access is released. Returns the URL to open, which
    /// may differ from the input if the file was moved or renamed.
    @discardableResult
    func beginAccess(for urlString: String) -> String {
        endAccess()
        guard let url = URL(string: urlString), url.isFileURL,
              let data = storedBookmarks[Self.key(for: url)] else {
            return urlString
        }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return urlString
        }

        if resolved.startAccessingSecurityScopedResource() {
            activeURL = resolved
        }
        if isStale {
            remember(resolved)
        }
        return resolved.absoluteString
    }

    func endAccess() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
    }

    private var storedBookmarks: [String: Data] {
        defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
