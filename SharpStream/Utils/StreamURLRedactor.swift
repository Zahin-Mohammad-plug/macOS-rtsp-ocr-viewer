//
//  StreamURLRedactor.swift
//  SharpStream
//
//  Redacts credentials and query fragments from stream URLs for logging.
//

import Foundation

enum StreamURLRedactor {
    static func redacted(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        guard var components = URLComponents(string: trimmed) else {
            if let index = trimmed.firstIndex(of: "?") {
                return String(trimmed[..<index])
            }
            return trimmed
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        return components.string ?? trimmed
    }
}
