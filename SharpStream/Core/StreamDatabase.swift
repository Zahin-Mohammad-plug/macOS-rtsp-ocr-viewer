//
//  StreamDatabase.swift
//  SharpStream
//
//  SQLite database for saved streams and recent streams
//

import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class StreamDatabase {
    private var db: OpaquePointer?
    private let dbPath: String
    
    init(baseDirectory: URL? = nil) {
        let rootDirectory: URL
        if let baseDirectory {
            rootDirectory = baseDirectory
        } else {
            rootDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        let sharpStreamDir = rootDirectory.appendingPathComponent("SharpStream", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: sharpStreamDir, withIntermediateDirectories: true)
        
        dbPath = sharpStreamDir.appendingPathComponent("streams.db", isDirectory: false).path
        
        openDatabase()
        createTables()
    }
    
    deinit {
        closeDatabase()
    }
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Unable to open database. Error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    private func createTables() {
        // Saved streams table
        let createStreamsTable = """
        CREATE TABLE IF NOT EXISTS saved_streams (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL,
            protocol_type TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_used REAL
        );
        """
        
        // Recent streams table
        let createRecentTable = """
        CREATE TABLE IF NOT EXISTS recent_streams (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            last_used REAL NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 1
        );
        """
        
        executeSQL(createStreamsTable)
        executeSQL(createRecentTable)
    }
    
    private func executeSQL(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error executing SQL: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("Error preparing SQL: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(statement)
    }

    private func bindText(_ text: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, (text as NSString).utf8String, -1, sqliteTransientDestructor)
    }
    
    // MARK: - Saved Streams
    
    func saveStream(_ stream: SavedStream) throws {
        let sql = """
        INSERT OR REPLACE INTO saved_streams (id, name, url, protocol_type, created_at, last_used)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed
        }
        
        bindText(stream.id.uuidString, at: 1, to: statement)
        bindText(stream.name, at: 2, to: statement)
        bindText(stream.url, at: 3, to: statement)
        bindText(stream.protocolType.rawValue, at: 4, to: statement)
        sqlite3_bind_double(statement, 5, stream.createdAt.timeIntervalSince1970)
        if let lastUsed = stream.lastUsed {
            sqlite3_bind_double(statement, 6, lastUsed.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        
        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.executionFailed
        }
        
        sqlite3_finalize(statement)
    }
    
    func getAllStreams() -> [SavedStream] {
        let sql = "SELECT id, name, url, protocol_type, created_at, last_used FROM saved_streams ORDER BY name;"
        var statement: OpaquePointer?
        var streams: [SavedStream] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let stream = parseStream(from: statement) {
                    streams.append(stream)
                }
            }
        }
        
        sqlite3_finalize(statement)
        return streams
    }
    
    func getStream(byID id: UUID) -> SavedStream? {
        let sql = "SELECT id, name, url, protocol_type, created_at, last_used FROM saved_streams WHERE id = ?;"
        var statement: OpaquePointer?
        var stream: SavedStream?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindText(id.uuidString, at: 1, to: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                stream = parseStream(from: statement)
            }
        }
        
        sqlite3_finalize(statement)
        return stream
    }
    
    func deleteStream(byID id: UUID) throws {
        let sql = "DELETE FROM saved_streams WHERE id = ?;"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed
        }
        
        bindText(id.uuidString, at: 1, to: statement)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.executionFailed
        }
        
        sqlite3_finalize(statement)
    }
    
    func updateLastUsed(streamID: UUID, date: Date) throws {
        let sql = "UPDATE saved_streams SET last_used = ? WHERE id = ?;"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed
        }
        
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        bindText(streamID.uuidString, at: 2, to: statement)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.executionFailed
        }
        
        sqlite3_finalize(statement)
    }
    
    private func parseStream(from statement: OpaquePointer?) -> SavedStream? {
        guard let statement = statement else { return nil }
        
        guard let idString = sqlite3_column_text(statement, 0),
              let name = sqlite3_column_text(statement, 1),
              let url = sqlite3_column_text(statement, 2),
              let protocolTypeString = sqlite3_column_text(statement, 3),
              let id = UUID(uuidString: String(cString: idString)),
              let protocolType = StreamProtocol(rawValue: String(cString: protocolTypeString)) else {
            return nil
        }
        
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        let lastUsed: Date? = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        
        return SavedStream(
            id: id,
            name: String(cString: name),
            url: String(cString: url),
            protocolType: protocolType,
            createdAt: createdAt,
            lastUsed: lastUsed
        )
    }
    
    // MARK: - Recent Streams
    
    func addRecentStream(url: String) {
        let sql = """
        INSERT INTO recent_streams (id, url, last_used, use_count)
        VALUES (?, ?, ?, 1)
        ON CONFLICT(url) DO UPDATE SET
            last_used = excluded.last_used,
            use_count = use_count + 1;
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let id = UUID().uuidString
            bindText(id, at: 1, to: statement)
            bindText(url, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
    
    func getRecentStreams(limit: Int = 5) -> [RecentStream] {
        let sql = "SELECT id, url, last_used, use_count FROM recent_streams ORDER BY last_used DESC LIMIT ?;"
        var statement: OpaquePointer?
        var streams: [RecentStream] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idString = sqlite3_column_text(statement, 0),
                   let url = sqlite3_column_text(statement, 1),
                   let id = UUID(uuidString: String(cString: idString)) {
                    let lastUsed = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                    let useCount = Int(sqlite3_column_int(statement, 3))
                    
                    streams.append(RecentStream(
                        id: id,
                        url: String(cString: url),
                        lastUsed: lastUsed,
                        useCount: useCount
                    ))
                }
            }
        }
        
        sqlite3_finalize(statement)
        return streams
    }
    
    func clearRecentStreams() {
        let sql = "DELETE FROM recent_streams;"
        executeSQL(sql)
    }
}

enum DatabaseError: Error {
    case prepareFailed
    case executionFailed
    case notFound
}
