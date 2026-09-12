import Foundation
import SQLite3

private let unicodeContainsSQLFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard argumentCount == 2,
          let context,
          let arguments,
          let haystackBytes = sqlite3_value_text(arguments[0]),
          let needleBytes = sqlite3_value_text(arguments[1])
    else {
        if let context { sqlite3_result_int(context, 0) }
        return
    }

    let haystack = String(cString: haystackBytes)
    let needle = String(cString: needleBytes)
    let matched = haystack.range(
        of: needle,
        options: [.caseInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    ) != nil
    sqlite3_result_int(context, matched ? 1 : 0)
}

enum FileIndexDatabaseError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the file index: \(message)"
        case .execute(let message): "Could not update the file index: \(message)"
        case .prepare(let message): "Could not query the file index: \(message)"
        }
    }
}

actor FileIndexDatabase {
    private var database: OpaquePointer?
    private var rebuildingInPlace = false

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw FileIndexDatabaseError.open(message)
        }
        database = handle
        sqlite3_busy_timeout(handle, 5_000)

        try Self.execute("PRAGMA journal_mode=WAL", on: handle)
        try Self.execute("PRAGMA synchronous=NORMAL", on: handle)
        guard sqlite3_create_function_v2(
            handle,
            "unicode_contains",
            2,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            unicodeContainsSQLFunction,
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw FileIndexDatabaseError.open(String(cString: sqlite3_errmsg(handle)))
        }
        try Self.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS indexed_files USING fts5(
                name,
                path UNINDEXED,
                content_type UNINDEXED,
                size UNINDEXED,
                created UNINDEXED,
                modified UNINDEXED,
                tokenize='trigram'
            )
            """, on: handle)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func fileCount() throws -> Int {
        guard let statement = try prepare("SELECT count(*) FROM indexed_files") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Keeps an existing index searchable while a staging table is rebuilt.
    /// The first-ever build writes directly to FTS so results become available
    /// as soon as each crawler batch arrives.
    func beginRebuild() throws {
        rebuildingInPlace = try fileCount() == 0
        if rebuildingInPlace {
            try execute("DELETE FROM indexed_files")
        } else {
            try execute("DROP TABLE IF EXISTS index_staging")
            try execute("""
                CREATE TABLE index_staging(
                    path TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    content_type TEXT,
                    size INTEGER,
                    created REAL,
                    modified REAL
                )
                """)
        }
    }

    func insert(_ files: [IndexedFile]) throws {
        guard !files.isEmpty else { return }
        let sql = rebuildingInPlace
            ? "INSERT INTO indexed_files(name,path,content_type,size,created,modified) VALUES(?,?,?,?,?,?)"
            : "INSERT OR REPLACE INTO index_staging(path,name,content_type,size,created,modified) VALUES(?,?,?,?,?,?)"
        guard let statement = try prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        try execute("BEGIN")
        do {
            for file in files {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                if rebuildingInPlace {
                    bind(file.name, to: 1, in: statement)
                    bind(file.path, to: 2, in: statement)
                } else {
                    bind(file.path, to: 1, in: statement)
                    bind(file.name, to: 2, in: statement)
                }
                bind(file.contentType, to: 3, in: statement)
                bind(file.size, to: 4, in: statement)
                bind(file.createdAt, to: 5, in: statement)
                bind(file.modifiedAt, to: 6, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw FileIndexDatabaseError.execute(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func finishRebuild() throws {
        guard !rebuildingInPlace else { return }
        try execute("BEGIN")
        do {
            try execute("DELETE FROM indexed_files")
            try execute("""
                INSERT INTO indexed_files(name,path,content_type,size,created,modified)
                SELECT name,path,content_type,size,created,modified FROM index_staging
                """)
            try execute("DROP TABLE index_staging")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func search(
        text rawText: String,
        scope: SearchScope,
        pathPrefix: String? = nil,
        allowedRootPaths: [String]? = nil,
        limit: Int = 200
    ) throws -> [FileSearchResult] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var bindings: [String] = []
        var clauses: [String] = []
        let order: String

        if terms.isEmpty {
            order = "ORDER BY CAST(modified AS REAL) DESC"
        } else if terms.allSatisfy({ $0.count >= 3 }) {
            let expression = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
            clauses.append("name MATCH ?")
            bindings.append(expression)
            order = "ORDER BY rank, CAST(modified AS REAL) DESC"
        } else {
            for term in terms {
                clauses.append("unicode_contains(name, ?) = 1")
                bindings.append(term)
            }
            order = "ORDER BY CAST(modified AS REAL) DESC"
        }

        for rawPrefix in [scope.pathPrefix, pathPrefix].compactMap({ $0 }) {
            let prefix = rawPrefix == "/"
                ? rawPrefix
                : (rawPrefix.hasSuffix("/") ? String(rawPrefix.dropLast()) : rawPrefix)
            if prefix == "/" {
                clauses.append("substr(path, 1, 1) = '/'")
            } else {
                // SQLite LIKE is ASCII case-insensitive by default, which is
                // incorrect for paths on case-sensitive volumes. Compare the
                // exact prefix and its directory boundary with binary `=`.
                clauses.append("substr(path, 1, length(?)) = ? AND substr(path, length(?) + 1, 1) = '/'")
                bindings.append(contentsOf: [prefix, prefix, prefix])
            }
        }

        if let allowedRootPaths {
            var rootClauses: [String] = []
            for rawRoot in allowedRootPaths {
                let root = rawRoot == "/"
                    ? rawRoot
                    : (rawRoot.hasSuffix("/") ? String(rawRoot.dropLast()) : rawRoot)
                if root == "/" {
                    rootClauses.append("substr(path, 1, 1) = '/'")
                } else {
                    rootClauses.append(
                        "(path = ? OR (substr(path, 1, length(?)) = ? AND substr(path, length(?) + 1, 1) = '/'))"
                    )
                    bindings.append(contentsOf: [root, root, root, root])
                }
            }
            clauses.append(rootClauses.isEmpty ? "0" : "(\(rootClauses.joined(separator: " OR ")))")
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT name,path,content_type,size,created,modified
            FROM indexed_files \(whereClause) \(order) LIMIT \(limit)
            """
        guard let statement = try prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            bind(value, to: Int32(offset + 1), in: statement)
        }

        var results: [FileSearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = string(at: 0, in: statement),
                  let path = string(at: 1, in: statement)
            else { continue }
            results.append(FileSearchResult(
                url: URL(fileURLWithPath: path),
                displayName: name,
                contentType: string(at: 2, in: statement),
                fileSize: optionalInt64(at: 3, in: statement),
                createdAt: optionalDate(at: 4, in: statement),
                modifiedAt: optionalDate(at: 5, in: statement),
                lastUsedAt: nil
            ))
        }
        return results
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite database is closed"
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw FileIndexDatabaseError.execute("Database is closed") }
        try Self.execute(sql, on: database)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw FileIndexDatabaseError.execute(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else { throw FileIndexDatabaseError.prepare("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FileIndexDatabaseError.prepare(errorMessage)
        }
        return statement
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_int64(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: Date?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func string(at index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func optionalInt64(at index: Int32, in statement: OpaquePointer) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private func optionalDate(at index: Int32, in statement: OpaquePointer) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
