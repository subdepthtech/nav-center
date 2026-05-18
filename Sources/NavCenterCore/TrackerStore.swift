import Foundation

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
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw NavCenterError.notFound("Tracker database not found: \(PathSafety.repoRelativePath(root: repoRoot, url: dbPath))")
        }

        let packageName = try PathSafety.normalizePackageName(packageName)
        let row = try rowForPackage(packageName)
        let applicationID = row?.id ?? trackerID(packageName: packageName)
        let oldStatus = row?.status ?? ""

        if row == nil {
            let package = try packageDefaults(packageName: packageName, applicationID: applicationID, status: status.rawValue, changedAt: changedAt)
            try SQLiteSupport.run(dbPath: dbPath, repoRoot: repoRoot, sql: """
            insert into applications (id, date, company, position, apply_link, resume_files, cover_letter_files, status, notes, next_action_date, application_dir, created_at, updated_at)
            values (\(SQLiteSupport.quote(package.id)), \(SQLiteSupport.quote(package.date)), \(SQLiteSupport.quote(package.company)), \(SQLiteSupport.quote(package.position)), \(SQLiteSupport.quote(package.applyLink)), '', '', \(SQLiteSupport.quote(status.rawValue)), \(SQLiteSupport.quote(package.notes)), '', \(SQLiteSupport.quote(package.applicationDir)), \(SQLiteSupport.quote(changedAt)), \(SQLiteSupport.quote(changedAt)));
            """)
        } else {
            try SQLiteSupport.run(dbPath: dbPath, repoRoot: repoRoot, sql: """
            update applications
            set status = \(SQLiteSupport.quote(status.rawValue)), updated_at = \(SQLiteSupport.quote(changedAt))
            where id = \(SQLiteSupport.quote(applicationID));
            """)
        }

        try SQLiteSupport.run(dbPath: dbPath, repoRoot: repoRoot, sql: """
        insert into status_events (application_id, old_status, new_status, changed_at)
        values (\(SQLiteSupport.quote(applicationID)), \(SQLiteSupport.quote(oldStatus)), \(SQLiteSupport.quote(status.rawValue)), \(SQLiteSupport.quote(changedAt)));
        """)
        try refreshMarkdownSnapshot()

        return TrackerStatusUpdateResult(
            applicationID: applicationID,
            packageName: packageName,
            oldStatus: oldStatus,
            newStatus: status.rawValue,
            changedAt: changedAt
        )
    }

    public func refreshMarkdownSnapshot() throws {
        let rows = try loadRows()
        let markdown = TrackerMarkdown.render(rows)
        let output = repoRoot.appendingPathComponent("tracking/applications.md")
        try PathSafety.assertWritablePath(output, inside: repoRoot, label: "Tracker Markdown snapshot")
        try markdown.write(to: output, atomically: true, encoding: .utf8)
    }

    public func loadRows() throws -> [TrackerApplicationRow] {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return [] }
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
            metadata = Markdown.parseFrontmatter(try String(contentsOf: postingURL)).metadata
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
    static func run(dbPath: URL, repoRoot: URL, sql: String) throws {
        let result = try ProcessRunner.run("sqlite3", [dbPath.path, sql], cwd: repoRoot)
        guard result.status == 0 else {
            throw NavCenterError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func jsonRows(dbPath: URL, repoRoot: URL, sql: String) throws -> [[String: Any]] {
        let result = try ProcessRunner.run("sqlite3", ["-json", dbPath.path, sql], cwd: repoRoot)
        guard result.status == 0 else {
            throw NavCenterError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else { return [] }
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value)
    }
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
