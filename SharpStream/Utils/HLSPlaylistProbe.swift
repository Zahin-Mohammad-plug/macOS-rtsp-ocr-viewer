//
//  HLSPlaylistProbe.swift
//  SharpStream
//
//  Tells live HLS apart from VOD. mpv reports a duration for live playlists
//  too (the current window), so duration alone made live HLS look like a
//  seekable file: no LIVE badge, no rewind, no Jump to Live.
//

import Foundation

enum HLSPlaylistProbe {
    /// true = live, false = VOD, nil = couldn't tell.
    static func isLive(_ urlString: String, session: URLSession = .shared) async -> Bool? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (text, finalURL) = await fetch(url, session: session) else { return nil }

        // Master playlist: decide from its first variant.
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = firstVariantURI(in: text),
                  let variantURL = URL(string: variant, relativeTo: finalURL)?.absoluteURL,
                  let (variantText, _) = await fetch(variantURL, session: session) else { return nil }
            return classify(variantText)
        }
        return classify(text)
    }

    static func classify(_ mediaPlaylist: String) -> Bool? {
        guard mediaPlaylist.contains("#EXTM3U") else { return nil }
        if mediaPlaylist.contains("#EXT-X-ENDLIST") || mediaPlaylist.contains("#EXT-X-PLAYLIST-TYPE:VOD") {
            return false
        }
        return true
    }

    static func firstVariantURI(in masterPlaylist: String) -> String? {
        let lines = masterPlaylist.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            if let uri = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) {
                return uri
            }
        }
        return nil
    }

    private static func fetch(_ url: URL, session: URLSession) async -> (String, URL)? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let text = String(data: data.prefix(256 * 1024), encoding: .utf8) else { return nil }
        return (text, response.url ?? url)
    }
}
