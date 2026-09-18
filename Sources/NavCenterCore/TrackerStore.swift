import Foundation
import SQLite3
import Darwin

public enum TrackerStatus: String, Codable, CaseIterable, Equatable {
    case submitted = "Submitted"
    case interview = "Interview"
    case notPursuing = "Not Pursuing"

    public static func normalized(_ value: String) throws -> TrackerStatus {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "submitted", "applied", "mark-applied":
            return .submitted
        case "interview", "interviewing", "mark-interview":
            return .interview
        case "not-pursuing", "not pursuing", "declined", "archive":
            return .notPursuing
        default:
            throw NavCenterError.invalidPath("Unsupported tracker status: \(value)")
        }
    }
}

public struct TrackerStatusUpdateResult: Equatable, Codable {
    public let applicationID: String
    public let packageName: String
    public let oldStatus: String
    public let newStatus: String
    public let changedAt: String
    public var warnings: [String] = []
}

public struct TrackerApplicationRow: Equatable, Codable {
    public let id: String
    public let date: String
    public let company: String
    public let position: String
    public let applyLink: String
    public let resumeFiles: String
    public let coverLetterFiles: String
    public let status: String
    public let notes: String
    public let nextActionDate: String
    public let applicationDir: String
}

public final class TrackerStore {
    private let repoRoot: URL
    private let dbPath: URL

    public init(repoRoot: URL, dbPath: URL? = nil) {
        self.repoRoot = repoRoot
        self.dbPath = dbPath ?? repoRoot.appendingPathComponent("tracking/applications.sqlite")
    }

    @discardableResult
    public func updateStatus(packageName: String, status: TrackerStatus, changedAt: String = ISO8601DateFormatter().string(from: Date())) throws -> TrackerStatusUpdateResult {
        let packageName = try PathSafety.normalizePackageName(packageName)
        // Validate the package before first-use tracker creation.
        _ = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        let existed = SQLiteSupport.exists(dbPath)
        try PathSafety.createDirectory(dbPath.deletingLastPathComponent(), inside: repoRoot, label: "tracking directory")
        let connection = try SQLiteSupport.Connection(dbPath: dbPath, repoRoot: repoRoot, writable: true, create: !existed)
        let result: TrackerStatusUpdateResult = try connection.transaction {
            if !existed { try connection.createSchema() }
            try connection.validateSchema()
            let matches = try connection.rows("select * from applications where application_dir = \(SQLiteSupport.quote("applications/" + packageName)) or id = \(SQLiteSupport.quote(trackerID(packageName: packageName)));")
            guard matches.count <= 1 else {
                throw NavCenterError.invalidPath("Multiple tracker records refer to this package. Resolve the duplicate records before changing status.")
            }
            let row = matches.first
            let applicationID = row.map { SQLiteSupport.string($0["id"]) } ?? trackerID(packageName: packageName)
            let oldStatus = row.map { SQLiteSupport.string($0["status"]) } ?? ""
            if row == nil {
                let package = try packageDefaults(packageName: packageName, applicationID: applicationID, status: status.rawValue, changedAt: changedAt)
                try connection.execute("""
                insert into applications (id, date, company, position, apply_link, resume_files, cover_letter_files, status, notes, next_action_date, application_dir, created_at, updated_at)
                values (\(SQLiteSupport.quote(package.id)), \(SQLiteSupport.quote(package.date)), \(SQLiteSupport.quote(package.company)), \(SQLiteSupport.quote(package.position)), \(SQLiteSupport.quote(package.applyLink)), '', '', \(SQLiteSupport.quote(status.rawValue)), \(SQLiteSupport.quote(package.notes)), '', \(SQLiteSupport.quote(package.applicationDir)), \(SQLiteSupport.quote(changedAt)), \(SQLiteSupport.quote(changedAt)));
                """)
            } else {
                try connection.execute("update applications set status = \(SQLiteSupport.quote(status.rawValue)), updated_at = \(SQLiteSupport.quote(changedAt)) where id = \(SQLiteSupport.quote(applicationID));")
            }
            try connection.execute("insert into status_events (application_id, old_status, new_status, changed_at) values (\(SQLiteSupport.quote(applicationID)), \(SQLiteSupport.quote(oldStatus)), \(SQLiteSupport.quote(status.rawValue)), \(SQLiteSupport.quote(changedAt)));")
            return TrackerStatusUpdateResult(applicationID: applicationID, packageName: packageName, oldStatus: oldStatus, newStatus: status.rawValue, changedAt: changedAt)
        }
        var committed = result
        do { try refreshMarkdownSnapshot() }
        catch { committed.warnings = ["Status and history were saved. The derived tracker Markdown could not be refreshed: \(error.localizedDescription)"] }
        return committed
    }

    public static func queryRows(repoRoot: URL, dbPath: URL, sql: String) throws -> [[String: Any]] {
        try SQLiteSupport.Connection(dbPath: dbPath, repoRoot: repoRoot, writable: false).rows(sql)
    }

    public func refreshMarkdownSnapshot() throws {
        try CoreFileSetCommit.serialized {
            let rows = try loadRows()
            let markdown = TrackerMarkdown.render(rows)
            let output = repoRoot.appendingPathComponent("tracking/applications.md")
            try PathSafety.assertWritablePath(output, inside: repoRoot, label: "Tracker Markdown snapshot")
            try PathSafety.atomicWrite(Data(markdown.utf8), to: output, inside: repoRoot, label: "Tracker Markdown snapshot")
        }
    }

    public func loadRows() throws -> [TrackerApplicationRow] {
        guard SQLiteSupport.exists(dbPath) else { return [] }
        let sql = """
        select id, date, company, position, apply_link as applyLink, resume_files as resumeFiles, cover_letter_files as coverLetterFiles, status, notes, next_action_date as nextActionDate, application_dir as applicationDir
        from applications
        order by date, company, position;
        """
        return try SQLiteSupport.jsonRows(dbPath: dbPath, repoRoot: repoRoot, sql: sql).map { row in
            TrackerApplicationRow(
                id: SQLiteSupport.string(row["id"]),
                date: SQLiteSupport.string(row["date"]),
                company: SQLiteSupport.string(row["company"]),
                position: SQLiteSupport.string(row["position"]),
                applyLink: SQLiteSupport.string(row["applyLink"]),
                resumeFiles: SQLiteSupport.string(row["resumeFiles"]),
                coverLetterFiles: SQLiteSupport.string(row["coverLetterFiles"]),
                status: SQLiteSupport.string(row["status"]),
                notes: SQLiteSupport.string(row["notes"]),
                nextActionDate: SQLiteSupport.string(row["nextActionDate"]),
                applicationDir: SQLiteSupport.string(row["applicationDir"])
            )
        }
    }

    private func rowForPackage(_ packageName: String) throws -> TrackerApplicationRow? {
        let id = trackerID(packageName: packageName)
        let applicationDir = "applications/\(packageName)"
        let sql = """
        select id, date, company, position, apply_link as applyLink, resume_files as resumeFiles, cover_letter_files as coverLetterFiles, status, notes, next_action_date as nextActionDate, application_dir as applicationDir
        from applications
        where application_dir = \(SQLiteSupport.quote(applicationDir)) or id = \(SQLiteSupport.quote(id))
        limit 1;
        """
        return try SQLiteSupport.jsonRows(dbPath: dbPath, repoRoot: repoRoot, sql: sql).first.map { row in
            TrackerApplicationRow(
                id: SQLiteSupport.string(row["id"]),
                date: SQLiteSupport.string(row["date"]),
                company: SQLiteSupport.string(row["company"]),
                position: SQLiteSupport.string(row["position"]),
                applyLink: SQLiteSupport.string(row["applyLink"]),
                resumeFiles: SQLiteSupport.string(row["resumeFiles"]),
                coverLetterFiles: SQLiteSupport.string(row["coverLetterFiles"]),
                status: SQLiteSupport.string(row["status"]),
                notes: SQLiteSupport.string(row["notes"]),
                nextActionDate: SQLiteSupport.string(row["nextActionDate"]),
                applicationDir: SQLiteSupport.string(row["applicationDir"])
            )
        }
    }

    private func packageDefaults(packageName: String, applicationID: String, status: String, changedAt: String) throws -> TrackerApplicationRow {
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        let postingURL = resolved.packageURL.appendingPathComponent("posting.md")
        let metadata: [String: String]
        if FileManager.default.fileExists(atPath: postingURL.path) {
            let data = try PathSafety.readData(postingURL, inside: repoRoot, label: "package posting")
            guard let text = String(data: data, encoding: .utf8) else { throw NavCenterError.invalidPath("Package posting is not UTF-8 text.") }
            metadata = Markdown.parseFrontmatter(text).metadata
        } else {
            metadata = [:]
        }
        let fallback = Self.parsePackageName(packageName)
        return TrackerApplicationRow(
            id: applicationID,
            date: fallback.date,
            company: metadata["company"]?.nonEmpty ?? fallback.company,
            position: metadata["role"]?.nonEmpty ?? fallback.role,
            applyLink: metadata["source_url"] ?? "",
            resumeFiles: "",
            coverLetterFiles: "",
            status: status,
            notes: "Created from package status action.",
            nextActionDate: "",
            applicationDir: "applications/\(packageName)"
        )
    }

    private func trackerID(packageName: String) -> String {
        packageName.replacingOccurrences(of: "-", with: "_").lowercased()
    }

    static func parsePackageName(_ packageName: String) -> (date: String, company: String, role: String) {
        let parts = packageName.split(separator: "_").map(String.init)
        let date = String(packageName.prefix(10))
        guard parts.count >= 3 else { return (date, packageName, "") }
        return (date, parts.dropFirst().prefix(1).joined(separator: " "), parts.dropFirst(2).joined(separator: " "))
    }
}

enum SQLiteSupport {
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    // SQLite opens filenames through its own VFS. NOFOLLOW and repeated identity
    // checks reject aliases; they do not promise immunity to hostile ancestor renames.
    final class Connection {
        private var database: OpaquePointer?
        let dbPath: URL
        let repoRoot: URL
        private let writable: Bool
        private let rootIdentity: String
        private var databaseIdentity: String
        private var operationDeadline = Date.distantFuture

        init(dbPath: URL, repoRoot: URL, writable: Bool, create: Bool = false) throws {
            self.dbPath = dbPath.standardizedFileURL
            self.repoRoot = repoRoot.standardizedFileURL
            self.writable = writable
            try Self.validatePaths(dbPath: dbPath, repoRoot: repoRoot, allowMissing: create)
            rootIdentity = try Self.identity(repoRoot)
            databaseIdentity = SQLiteSupport.exists(dbPath) ? try Self.identity(dbPath) : ""
            let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
            // Foundation may re-abbreviate /private/var as /var. SQLite's
            // NOFOLLOW rejects that system alias, so preserve the POSIX result
            // as a raw string after rejecting links inside our configured root.
            guard let canonicalRoot = Darwin.realpath(repoRoot.path, nil) else { throw NavCenterError.invalidPath("Could not resolve tracker workspace root.") }
            let rootPath = String(cString: canonicalRoot)
            free(canonicalRoot)
            let relative = PathSafety.repoRelativePath(root: repoRoot, url: dbPath)
            let filename = rootPath + "/" + relative
            let status = sqlite3_open_v2(filename, &database, flags, nil)
            guard status == SQLITE_OK else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open tracker database."
                if let database { sqlite3_close(database) }
                database = nil
                throw NavCenterError.commandFailed("Tracker database could not be opened: \(message)")
            }
            do {
                if databaseIdentity.isEmpty { databaseIdentity = try Self.identity(dbPath) }
                try validateIdentity()
                sqlite3_busy_timeout(database, 3_000)
                sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024)
                sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 1024 * 1024)
                sqlite3_progress_handler(database, 1000, { context in
                    guard let context else { return 1 }
                    let connection = Unmanaged<Connection>.fromOpaque(context).takeUnretainedValue()
                    return Date() > connection.operationDeadline ? 1 : 0
                }, Unmanaged.passUnretained(self).toOpaque())
            } catch {
                sqlite3_close(database)
                database = nil
                throw error
            }
        }

        deinit { if let database { sqlite3_close(database) } }

        func validateIdentity() throws {
            try Self.validatePaths(dbPath: dbPath, repoRoot: repoRoot, allowMissing: false)
            guard try Self.identity(repoRoot) == rootIdentity, try Self.identity(dbPath) == databaseIdentity else {
                throw NavCenterError.invalidPath("Tracker workspace or database identity changed during the operation.")
            }
        }

        private static func validatePaths(dbPath: URL, repoRoot: URL, allowMissing: Bool) throws {
            try PathSafety.assertNoSymlinkSegments(dbPath, root: repoRoot, label: "tracker database")
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let file = URL(fileURLWithPath: dbPath.path + suffix)
                if SQLiteSupport.exists(file) {
                    try PathSafety.assertExistingRegularFile(file, inside: repoRoot, label: "tracker database or sidecar")
                    var info = stat()
                    guard lstat(file.path, &info) == 0, info.st_nlink == 1, (info.st_mode & S_IFMT) == S_IFREG else {
                        throw NavCenterError.invalidPath("Tracker database and sidecars must be regular files with a single link.")
                    }
                } else if suffix.isEmpty && !allowMissing {
                    throw NavCenterError.notFound("Tracker database not found.")
                }
            }
        }

        private static func identity(_ url: URL) throws -> String {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NavCenterError.invalidPath("Could not inspect tracker filesystem identity.") }
            return "\(info.st_dev):\(info.st_ino)"
        }

        func execute(_ sql: String, checkAfter: Bool = true) throws {
            try validateIdentity()
            operationDeadline = Date().addingTimeInterval(15)
            var error: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(database, sql, nil, nil, &error)
            defer { sqlite3_free(error) }
            guard status == SQLITE_OK else {
                throw NavCenterError.commandFailed("Tracker operation failed: " + (error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))))
            }
            if checkAfter { try validateIdentity() }
        }

        func rows(_ sql: String) throws -> [[String: Any]] {
            try validateIdentity()
            operationDeadline = Date().addingTimeInterval(15)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw NavCenterError.commandFailed("Tracker query failed: \(String(cString: sqlite3_errmsg(database)))")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_stmt_readonly(statement) != 0 else { throw NavCenterError.invalidPath("Tracker query must be read-only.") }
            var result: [[String: Any]] = []
            var retainedBytes = 0
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw NavCenterError.commandFailed("Tracker query failed: \(String(cString: sqlite3_errmsg(database)))") }
                guard result.count < 100_000 else { throw NavCenterError.commandFailed("Tracker query exceeds the supported row limit.") }
                var row: [String: Any] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_NULL: row[name] = NSNull()
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, index)
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                    case SQLITE_BLOB:
                        let size = Int(sqlite3_column_bytes(statement, index))
                        row[name] = sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: size) } ?? Data()
                        retainedBytes += size
                    default:
                        let size = Int(sqlite3_column_bytes(statement, index))
                        if let bytes = sqlite3_column_text(statement, index) {
                            guard let value = String(data: Data(bytes: bytes, count: size), encoding: .utf8) else { throw NavCenterError.commandFailed("Tracker contains invalid UTF-8 text.") }
                            row[name] = value
                        }
                        retainedBytes += size
                    }
                }
                guard retainedBytes <= 32 * 1024 * 1024 else { throw NavCenterError.commandFailed("Tracker query exceeds the supported data limit.") }
                result.append(row)
            }
            try validateIdentity()
            return result
        }

        func transaction<T>(_ body: () throws -> T) throws -> T {
            try execute("BEGIN IMMEDIATE;")
            do {
                let value = try body()
                try execute("COMMIT;", checkAfter: false)
                return value
            } catch {
                // Rollback must still run if an identity check failed.
                _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }

        func validateSchema() throws {
            let version = (try rows("PRAGMA user_version;").first?["user_version"] as? Int64) ?? 0
            guard version <= 1 else { throw NavCenterError.invalidPath("This tracker schema is newer than this version of Nav Center supports.") }
            let required: [String: Set<String>] = [
                "applications": ["id", "date", "company", "position", "apply_link", "resume_files", "cover_letter_files", "status", "notes", "next_action_date", "application_dir", "created_at", "updated_at"],
                "status_events": ["application_id", "old_status", "new_status", "changed_at"],
                "artifacts": ["application_id"]
            ]
            for (table, columns) in required {
                let actual = Set(try rows("PRAGMA table_info(\(table));").map { SQLiteSupport.string($0["name"]) })
                guard columns.isSubset(of: actual) else { throw NavCenterError.invalidPath("Tracker schema is missing required columns in \(table). Restore or migrate the tracker before changing it.") }
            }
        }

        func createSchema() throws {
            try execute("""
            CREATE TABLE applications (id TEXT PRIMARY KEY, date TEXT, company TEXT, position TEXT, apply_link TEXT, resume_files TEXT, cover_letter_files TEXT, status TEXT, notes TEXT, next_action_date TEXT, application_dir TEXT, created_at TEXT, updated_at TEXT);
            CREATE TABLE status_events (application_id TEXT, old_status TEXT, new_status TEXT, changed_at TEXT);
            CREATE TABLE artifacts (application_id TEXT, path TEXT);
            PRAGMA user_version=1;
            """)
        }

        func backup(to destination: URL) throws {
            try validateIdentity()
            guard !SQLiteSupport.exists(destination) else { throw NavCenterError.invalidPath("Tracker backup destination already exists.") }
            let target = try Connection(dbPath: destination, repoRoot: repoRoot, writable: true, create: true)
            guard let backup = sqlite3_backup_init(target.database, "main", database, "main") else {
                throw NavCenterError.commandFailed("Could not initialize a consistent tracker backup.")
            }
            let deadline = Date().addingTimeInterval(10)
            var status: Int32
            repeat {
                status = sqlite3_backup_step(backup, 128)
                if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.01) }
            } while (status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED) && Date() < deadline
            let finish = sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE, finish == SQLITE_OK else { throw NavCenterError.commandFailed("Tracker backup did not complete within its safe deadline.") }
            try validateIdentity()
            let check = try target.rows("PRAGMA integrity_check;")
            guard check.count == 1, check.first?.values.first as? String == "ok" else { throw NavCenterError.commandFailed("Tracker backup integrity check failed.") }
        }
    }

    static func run(dbPath: URL, repoRoot: URL, sql: String) throws {
        try Connection(dbPath: dbPath, repoRoot: repoRoot, writable: true, create: !exists(dbPath)).execute(sql)
    }

    static func jsonRows(dbPath: URL, repoRoot: URL, sql: String) throws -> [[String: Any]] {
        try Connection(dbPath: dbPath, repoRoot: repoRoot, writable: false).rows(sql)
    }

    static func quote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "''"))'" }
    static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value)
    }
    static func literal(_ value: Any) -> String {
        if value is NSNull { return "NULL" }
        if let bytes = value as? Data { return "X'" + bytes.map { String(format: "%02x", $0) }.joined() + "'" }
        if let value = value as? String { return quote(value) }
        if let value = value as? NSNumber { return value.stringValue }
        return quote(String(describing: value))
    }
    static func identifier(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

enum TrackerMarkdown {
    static func render(_ rows: [TrackerApplicationRow]) -> String {
        var lines = [
            "| Date | Company | Position | Apply Link | Resume Files | Cover Letter Files | Status | Notes | Next Action Date |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
        ]
        lines += rows.map { row in
            [
                row.date,
                row.company,
                row.position,
                applyLink(row.applyLink),
                row.resumeFiles,
                row.coverLetterFiles,
                row.status,
                row.notes,
                row.nextActionDate
            ].map(escapeCell).joined(separator: " | ").wrappedTableRow
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func applyLink(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "[Apply](\(url))"
    }

    private static func escapeCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var wrappedTableRow: String {
        "| \(self) |"
    }
}
