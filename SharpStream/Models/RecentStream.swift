//
//  RecentStream.swift
//  SharpStream
//
//  Recently used stream tracking
//

import Foundation

struct RecentStream: Identifiable, Codable {
    let id: UUID
    let url: String
    var lastUsed: Date
    var useCount: Int
    
    init(id: UUID = UUID(), url: String, lastUsed: Date = Date(), useCount: Int = 1) {
        self.id = id
        self.url = url
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}

extension RecentStream: Comparable {
    static func < (lhs: RecentStream, rhs: RecentStream) -> Bool {
        if lhs.lastUsed != rhs.lastUsed {
            return lhs.lastUsed < rhs.lastUsed
        }
        return lhs.useCount < rhs.useCount
    }
}
