import Foundation
import SQLite3

enum DownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case completed
    case failed
    case cancelled
    case missing
}

struct DownloadRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String { key }

    let key: String
    let identifier: String
    let fileName: String
    let title: String
    let expectedBytes: Int64?
    var localPath: String
    var state: DownloadState
    var receivedBytes: Int64
    var totalBytes: Int64?
    var errorMessage: String?
    var updatedAt: Date
}

struct PlaybackBookmark: Sendable {
    let identifier: String
    let fileName: String
    let seconds: Double
}

struct StoredCacheEntry: Sendable {
    let key: String
    let kind: String
    let response: Data
    let snapshot: Data?
    let storedAt: Date
    let maxAge: TimeInterval

    var isFresh: Bool { Date().timeIntervalSince(storedAt) <= maxAge }
}

enum StoreError: LocalizedError {
    case open(String)
    case statement(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let detail): "The library could not be opened. \(detail)"
        case .statement(let detail): "The library request could not be prepared. \(detail)"
        case .step(let detail): "The library change could not be saved. \(detail)"
        }
    }
}

actor SQLiteStore {
    private static let cacheBudget = 50 * 1_024 * 1_024
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // SQLite's opaque connection has no Sendable annotation. The actor remains its sole
    // operational owner; unsafe nonisolation is only needed so deinit can close it.
    nonisolated(unsafe) private var database: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        database = handle
        try Self.execute("PRAGMA journal_mode=WAL", on: handle)
        try Self.execute("PRAGMA foreign_keys=ON", on: handle)
        try Self.execute("PRAGMA synchronous=NORMAL", on: handle)
        try Self.migrate(handle)
    }

    deinit {
        sqlite3_close(database)
    }

    func saveArtifact(identifier: String, snapshot: Data, date: Date = .now) throws {
        try execute(
            """
            INSERT INTO saved_artifacts(identifier, snapshot, saved_at)
            VALUES(?, ?, ?)
            ON CONFLICT(identifier) DO UPDATE SET snapshot=excluded.snapshot, saved_at=excluded.saved_at
            """,
            bindings: [.text(identifier), .blob(snapshot), .double(date.timeIntervalSince1970)]
        )
    }

    @discardableResult
    func removeSavedArtifact(identifier: String) throws -> Data? {
        let snapshot = try savedArtifact(identifier: identifier)
        try execute("DELETE FROM saved_artifacts WHERE identifier=?", bindings: [.text(identifier)])
        return snapshot
    }

    func savedArtifact(identifier: String) throws -> Data? {
        try queryOne(
            "SELECT snapshot FROM saved_artifacts WHERE identifier=?",
            bindings: [.text(identifier)]
        ) { statement in Self.blob(statement, column: 0) ?? Data() }
    }

    func savedArtifacts() throws -> [Data] {
        try query(
            "SELECT snapshot FROM saved_artifacts ORDER BY saved_at DESC"
        ) { statement in Self.blob(statement, column: 0) ?? Data() }
    }

    func setPlaybackPosition(identifier: String, fileName: String, seconds: Double) throws {
        try execute(
            """
            INSERT INTO playback_positions(identifier, file_name, seconds, updated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(identifier, file_name) DO UPDATE SET
              seconds=excluded.seconds, updated_at=excluded.updated_at
            """,
            bindings: [
                .text(identifier), .text(fileName), .double(max(0, seconds)),
                .double(Date.now.timeIntervalSince1970)
            ]
        )
    }

    func bookLocator(identifier: String, fileName: String) throws -> String? {
        try queryOne(
            "SELECT locator FROM book_positions WHERE identifier=? AND file_name=?",
            bindings: [.text(identifier), .text(fileName)]
        ) { Self.text($0, column: 0) } ?? nil
    }

    func setBookLocator(_ locator: String, identifier: String, fileName: String, date: Date = .now) throws {
        try execute(
            """
            INSERT INTO book_positions(identifier, file_name, locator, updated_at) VALUES(?, ?, ?, ?)
            ON CONFLICT(identifier, file_name) DO UPDATE SET locator=excluded.locator, updated_at=excluded.updated_at
            """,
            bindings: [.text(identifier), .text(fileName), .text(locator), .double(date.timeIntervalSince1970)]
        )
    }

    func playbackPosition(identifier: String, fileName: String) throws -> Double? {
        try queryOne(
            "SELECT seconds FROM playback_positions WHERE identifier=? AND file_name=?",
            bindings: [.text(identifier), .text(fileName)]
        ) { sqlite3_column_double($0, 0) }
    }

    /// Saved positions, most recently updated first.
    func recentPlaybackPositions(limit: Int) throws -> [PlaybackBookmark] {
        try query(
            "SELECT identifier, file_name, seconds FROM playback_positions ORDER BY updated_at DESC LIMIT ?",
            bindings: [.int64(Int64(max(0, limit)))]
        ) {
            guard let identifier = Self.text($0, column: 0), let fileName = Self.text($0, column: 1) else { return nil }
            return PlaybackBookmark(identifier: identifier, fileName: fileName, seconds: sqlite3_column_double($0, 2))
        }.compactMap { $0 }
    }

    func setLastPlayback(_ bookmark: PlaybackBookmark?) throws {
        if let bookmark {
            try execute(
                """
                INSERT INTO last_playback(singleton, identifier, file_name, seconds)
                VALUES(1, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                  identifier=excluded.identifier, file_name=excluded.file_name, seconds=excluded.seconds
                """,
                bindings: [.text(bookmark.identifier), .text(bookmark.fileName), .double(bookmark.seconds)]
            )
        } else {
            try execute("DELETE FROM last_playback WHERE singleton=1")
        }
    }

    func lastPlayback() throws -> PlaybackBookmark? {
        try queryOne("SELECT identifier, file_name, seconds FROM last_playback WHERE singleton=1") {
            guard let identifier = Self.text($0, column: 0), let fileName = Self.text($0, column: 1) else {
                return nil
            }
            return PlaybackBookmark(
                identifier: identifier,
                fileName: fileName,
                seconds: sqlite3_column_double($0, 2)
            )
        } ?? nil
    }

    func setTrackChoice(_ choice: TrackChoice, kind: RememberedTrackKind, identifier: String, fileName: String) throws {
        let track: Binding
        switch choice {
        case .off: track = .null
        case .track(let id): track = .int64(Int64(id))
        }
        try execute(
            """
            INSERT INTO track_choices(identifier, file_name, kind, track_id, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(identifier, file_name, kind) DO UPDATE SET
              track_id=excluded.track_id, updated_at=excluded.updated_at
            """,
            bindings: [.text(identifier), .text(fileName), .text(kind.rawValue), track, .double(Date.now.timeIntervalSince1970)]
        )
    }

    func trackChoice(_ kind: RememberedTrackKind, identifier: String, fileName: String) throws -> TrackChoice? {
        try queryOne(
            "SELECT track_id FROM track_choices WHERE identifier=? AND file_name=? AND kind=?",
            bindings: [.text(identifier), .text(fileName), .text(kind.rawValue)]
        ) { statement -> TrackChoice in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return .off }
            let raw = sqlite3_column_int64(statement, 0)
            guard let id = UInt32(exactly: raw) else { throw StoreError.step("Remembered track \(raw) is not a valid track number.") }
            return .track(id)
        }
    }

    func setPreferredLanguage(_ preference: LanguagePreference, kind: RememberedTrackKind) throws {
        let language: Binding
        switch preference {
        case .off: language = .null
        case .language(let tag): language = .text(tag)
        }
        try execute(
            """
            INSERT INTO preferred_languages(kind, language, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(kind) DO UPDATE SET language=excluded.language, updated_at=excluded.updated_at
            """,
            bindings: [.text(kind.rawValue), language, .double(Date.now.timeIntervalSince1970)]
        )
    }

    func preferredLanguage(_ kind: RememberedTrackKind) throws -> LanguagePreference? {
        try queryOne("SELECT language FROM preferred_languages WHERE kind=?", bindings: [.text(kind.rawValue)]) {
            Self.text($0, column: 0).map(LanguagePreference.language) ?? .off
        }
    }

    func upsertDownload(_ record: DownloadRecord) throws {
        try execute(
            """
            INSERT INTO downloads(
              key, identifier, file_name, title, expected_bytes, local_path,
              state, received_bytes, total_bytes, error_message, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              title=excluded.title, expected_bytes=excluded.expected_bytes,
              local_path=excluded.local_path, state=excluded.state,
              received_bytes=excluded.received_bytes, total_bytes=excluded.total_bytes,
              error_message=excluded.error_message, updated_at=excluded.updated_at
            """,
            bindings: [
                .text(record.key), .text(record.identifier), .text(record.fileName), .text(record.title),
                record.expectedBytes.map(Binding.int64) ?? .null, .text(record.localPath),
                .text(record.state.rawValue), .int64(record.receivedBytes),
                record.totalBytes.map(Binding.int64) ?? .null,
                record.errorMessage.map(Binding.text) ?? .null,
                .double(record.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    func downloads() throws -> [DownloadRecord] {
        try query(
            """
            SELECT key, identifier, file_name, title, expected_bytes, local_path,
                   state, received_bytes, total_bytes, error_message, updated_at
            FROM downloads ORDER BY updated_at DESC
            """
        ) { statement in
            let state = Self.text(statement, column: 6).flatMap(DownloadState.init(rawValue:)) ?? .failed
            return DownloadRecord(
                key: Self.text(statement, column: 0) ?? "",
                identifier: Self.text(statement, column: 1) ?? "",
                fileName: Self.text(statement, column: 2) ?? "",
                title: Self.text(statement, column: 3) ?? "Untitled",
                expectedBytes: Self.optionalInt64(statement, column: 4),
                localPath: Self.text(statement, column: 5) ?? "",
                state: state,
                receivedBytes: sqlite3_column_int64(statement, 7),
                totalBytes: Self.optionalInt64(statement, column: 8),
                errorMessage: Self.text(statement, column: 9),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
            )
        }
    }

    func downloadResumeData(key: String) throws -> Data? {
        try queryOne("SELECT resume_data FROM downloads WHERE key=?", bindings: [.text(key)]) {
            Self.blob($0, column: 0)
        } ?? nil
    }

    func setDownloadResumeData(_ data: Data?, key: String) throws {
        try execute("UPDATE downloads SET resume_data=? WHERE key=?", bindings: [data.map(Binding.blob) ?? .null, .text(key)])
    }

    func deleteDownload(key: String) throws {
        try execute("DELETE FROM downloads WHERE key=?", bindings: [.text(key)])
    }

    func cacheEntry(key: String) throws -> StoredCacheEntry? {
        let entry: StoredCacheEntry? = try queryOne(
            """
            SELECT key, kind, response, snapshot, stored_at, max_age
            FROM cache_entries WHERE key=?
            """,
            bindings: [.text(key)]
        ) { statement in
            guard let key = Self.text(statement, column: 0),
                  let kind = Self.text(statement, column: 1),
                  let response = Self.blob(statement, column: 2) else { return nil }
            return StoredCacheEntry(
                key: key,
                kind: kind,
                response: response,
                snapshot: Self.blob(statement, column: 3),
                storedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                maxAge: sqlite3_column_double(statement, 5)
            )
        } ?? nil
        if entry != nil {
            try execute(
                "UPDATE cache_entries SET accessed_at=? WHERE key=?",
                bindings: [.double(Date.now.timeIntervalSince1970), .text(key)]
            )
        }
        return entry
    }

    func storeCache(
        key: String,
        kind: String,
        response: Data,
        snapshot: Data?,
        maxAge: TimeInterval
    ) throws {
        let now = Date.now.timeIntervalSince1970
        let byteCount = response.count + (snapshot?.count ?? 0)
        try execute(
            """
            INSERT INTO cache_entries(
              key, kind, response, snapshot, stored_at, accessed_at, max_age, byte_count
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              kind=excluded.kind, response=excluded.response, snapshot=excluded.snapshot,
              stored_at=excluded.stored_at, accessed_at=excluded.accessed_at,
              max_age=excluded.max_age, byte_count=excluded.byte_count
            """,
            bindings: [
                .text(key), .text(kind), .blob(response), snapshot.map(Binding.blob) ?? .null,
                .double(now), .double(now), .double(maxAge), .int64(Int64(byteCount))
            ]
        )
        try pruneCache()
    }

    private func pruneCache() throws {
        let currentBytes = try queryOne("SELECT COALESCE(SUM(byte_count), 0) FROM cache_entries") {
            Int(sqlite3_column_int64($0, 0))
        } ?? 0
        guard currentBytes > Self.cacheBudget else { return }
        try execute(
            """
            DELETE FROM cache_entries WHERE key IN (
              SELECT key FROM cache_entries ORDER BY accessed_at ASC
              LIMIT MAX(1, (SELECT COUNT(*) / 4 FROM cache_entries))
            )
            """
        )
        if try (queryOne("SELECT COALESCE(SUM(byte_count), 0) FROM cache_entries") {
            Int(sqlite3_column_int64($0, 0))
        } ?? 0) > Self.cacheBudget {
            try pruneCache()
        }
    }

    /// Numbered schema steps. `PRAGMA user_version` records how many have run, so
    /// each step runs exactly once per database. Never edit a shipped step; append.
    /// Step 1 is the original schema. It stays idempotent because databases created
    /// before versioning already have its tables at user_version 0.
    private static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS saved_artifacts(
          identifier TEXT PRIMARY KEY,
          snapshot BLOB NOT NULL,
          saved_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS playback_positions(
          identifier TEXT NOT NULL,
          file_name TEXT NOT NULL,
          seconds REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(identifier, file_name)
        );
        CREATE TABLE IF NOT EXISTS last_playback(
          singleton INTEGER PRIMARY KEY CHECK(singleton=1),
          identifier TEXT NOT NULL,
          file_name TEXT NOT NULL,
          seconds REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS downloads(
          key TEXT PRIMARY KEY,
          identifier TEXT NOT NULL,
          file_name TEXT NOT NULL,
          title TEXT NOT NULL,
          expected_bytes INTEGER,
          local_path TEXT NOT NULL,
          state TEXT NOT NULL,
          received_bytes INTEGER NOT NULL,
          total_bytes INTEGER,
          error_message TEXT,
          updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS downloads_state_index ON downloads(state, updated_at DESC);
        CREATE TABLE IF NOT EXISTS cache_entries(
          key TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          response BLOB NOT NULL,
          snapshot BLOB,
          stored_at REAL NOT NULL,
          accessed_at REAL NOT NULL,
          max_age REAL NOT NULL,
          byte_count INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS cache_access_index ON cache_entries(accessed_at);
        """,
        // 2: bytes URLSession hands back when a transfer fails, so Retry can continue it.
        "ALTER TABLE downloads ADD COLUMN resume_data BLOB;",
        // 3: the MKV player's audio and caption choice per file (NULL track_id
        // means turned off), and the language you prefer across items (NULL
        // language means captions off).
        """
        CREATE TABLE IF NOT EXISTS track_choices(
          identifier TEXT NOT NULL,
          file_name TEXT NOT NULL,
          kind TEXT NOT NULL CHECK(kind IN ('audio', 'caption')),
          track_id INTEGER,
          updated_at REAL NOT NULL,
          PRIMARY KEY(identifier, file_name, kind)
        );
        CREATE TABLE IF NOT EXISTS preferred_languages(
          kind TEXT PRIMARY KEY CHECK(kind IN ('audio', 'caption')),
          language TEXT,
          updated_at REAL NOT NULL
        );
        """,
        // 4: where you are in each book, as Readium's locator JSON.
        """
        CREATE TABLE IF NOT EXISTS book_positions(
          identifier TEXT NOT NULL,
          file_name TEXT NOT NULL,
          locator TEXT NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(identifier, file_name)
        );
        """
    ]

    static var schemaVersion: Int { migrations.count }

    private static func migrate(_ database: OpaquePointer?) throws {
        let current = try userVersion(database)
        guard current < migrations.count else { return }
        for (index, step) in migrations.enumerated().dropFirst(current) {
            try execute("BEGIN IMMEDIATE", on: database)
            do {
                try execute(step, on: database)
                try execute("PRAGMA user_version=\(index + 1)", on: database)
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    static func userVersion(_ database: OpaquePointer?) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.statement(database.map { String(cString: sqlite3_errmsg($0)) } ?? "No database")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.step(database.map { String(cString: sqlite3_errmsg($0)) } ?? "No database")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private enum Binding {
        case text(String)
        case blob(Data)
        case double(Double)
        case int64(Int64)
        case null
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.step(errorMessage)
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw StoreError.step(message)
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var output: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: output.append(try map(statement))
            case SQLITE_DONE: return output
            default: throw StoreError.step(errorMessage)
            }
        }
    }

    private func queryOne<T>(
        _ sql: String,
        bindings: [Binding] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> T? {
        try query(sql, bindings: bindings, map: map).first
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.statement(errorMessage)
        }
        return statement
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.transient)
                }
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .int64(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw StoreError.statement(errorMessage) }
        }
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func blob(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }
}
