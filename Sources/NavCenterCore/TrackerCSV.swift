import Foundation

public struct TrackerApplication: Equatable {
    public var date: String
    public var company: String
    public var position: String
    public var applyLink: String
    public var resumeFiles: String
    public var coverLetterFiles: String
    public var status: String
    public var notes: String
    public var nextActionDate: String

    public init(date: String, company: String, position: String, applyLink: String, resumeFiles: String, coverLetterFiles: String, status: String, notes: String, nextActionDate: String) {
        self.date = date
        self.company = company
        self.position = position
        self.applyLink = applyLink
        self.resumeFiles = resumeFiles
        self.coverLetterFiles = coverLetterFiles
        self.status = status
        self.notes = notes
        self.nextActionDate = nextActionDate
    }
}

public enum TrackerCSV {
    public static let columns = ["Date", "Company", "Position", "Apply_Link", "Resume_Files", "Cover_Letter_Files", "Status", "Notes", "Next_Action_Date"]

    public static func serialize(_ rows: [TrackerApplication]) -> String {
        var lines = [columns.joined(separator: ",")]
        for row in rows {
            lines.append([
                row.date, row.company, row.position, row.applyLink, row.resumeFiles, row.coverLetterFiles, row.status, row.notes, row.nextActionDate
            ].map(serializeCell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func load(dbPath: URL, repoRoot: URL) throws -> [TrackerApplication] {
        let query = """
        SELECT date AS date, company AS company, position AS position, apply_link AS applyLink, resume_files AS resumeFiles, cover_letter_files AS coverLetterFiles, status AS status, notes AS notes, next_action_date AS nextActionDate
        FROM applications
        ORDER BY date, company, position;
        """
        let result = try ProcessRunner.run("sqlite3", ["-json", dbPath.path, query], cwd: repoRoot)
        guard result.status == 0 else { throw NavCenterError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return json.map {
            TrackerApplication(
                date: "\($0["date"] ?? "")",
                company: "\($0["company"] ?? "")",
                position: "\($0["position"] ?? "")",
                applyLink: "\($0["applyLink"] ?? "")",
                resumeFiles: "\($0["resumeFiles"] ?? "")",
                coverLetterFiles: "\($0["coverLetterFiles"] ?? "")",
                status: "\($0["status"] ?? "")",
                notes: "\($0["notes"] ?? "")",
                nextActionDate: "\($0["nextActionDate"] ?? "")"
            )
        }
    }

    private static func serializeCell(_ value: String) -> String {
        var text = value
        if let first = text.first, ["=", "+", "-", "@"].contains(first) {
            text = "'\(text)"
        }
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "\",\n\r ").union(.whitespacesAndNewlines)) != nil {
            return "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return text
    }
}
