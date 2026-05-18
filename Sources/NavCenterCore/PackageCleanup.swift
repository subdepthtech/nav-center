import Foundation

public struct PackageCleanupCandidate: Codable, Equatable, Identifiable {
    public var id: String { packageName }
    public let packageName: String
    public let packageDate: String
    public let applicationDir: String
    public let trackerID: String?
    public let status: String
    public let isTracked: Bool

    public init(packageName: String, packageDate: String, applicationDir: String, trackerID: String?, status: String, isTracked: Bool) {
        self.packageName = packageName
        self.packageDate = packageDate
        self.applicationDir = applicationDir
        self.trackerID = trackerID
        self.status = status
        self.isTracked = isTracked
    }
}

public struct PackageCleanupPreview: Codable, Equatable {
    public let today: String
    public let cutoffDate: String
    public let olderThanDays: Int
    public let candidates: [PackageCleanupCandidate]

    public init(today: String, cutoffDate: String, olderThanDays: Int, candidates: [PackageCleanupCandidate]) {
        self.today = today
        self.cutoffDate = cutoffDate
        self.olderThanDays = olderThanDays
        self.candidates = candidates
    }
}

public struct PackageCleanupResult: Codable, Equatable {
    public let preview: PackageCleanupPreview
    public let removedPackages: [PackageCleanupCandidate]
    public let backupURL: URL
    public let manifestURL: URL

    public init(preview: PackageCleanupPreview, removedPackages: [PackageCleanupCandidate], backupURL: URL, manifestURL: URL) {
        self.preview = preview
        self.removedPackages = removedPackages
        self.backupURL = backupURL
        self.manifestURL = manifestURL
    }
}

public final class PackageCleanup {
    private let repoRoot: URL
    private let dbPath: URL

    public init(repoRoot: URL, dbPath: URL? = nil) {
        self.repoRoot = repoRoot
        self.dbPath = dbPath ?? repoRoot.appendingPathComponent("tracking/applications.sqlite")
    }

    public func preview(olderThanDays: Int, today: String = DateFormatter.navCenterCoreDay.string(from: Date())) throws -> PackageCleanupPreview {
        guard olderThanDays >= 1 else {
            throw NavCenterError.invalidPath("--older-than-days must be at least 1")
        }
        let cutoffDate = try Self.cutoffDate(today: today, olderThanDays: olderThanDays)
        let packages = try packageDirectories()
        let trackerRows = try trackerRowsByPackageName()

        let candidates = packages.compactMap { packageName -> PackageCleanupCandidate? in
            guard let date = Self.packageDate(packageName) else {
                return nil
            }
            guard date < cutoffDate else { return nil }
            let tracker = trackerRows[packageName]
            return PackageCleanupCandidate(
                packageName: packageName,
                packageDate: date,
                applicationDir: "applications/\(packageName)",
                trackerID: tracker?.id,
                status: tracker?.status ?? "Package Only",
                isTracked: tracker != nil
            )
        }.sorted { first, second in
            if first.packageDate != second.packageDate { return first.packageDate < second.packageDate }
            return first.packageName < second.packageName
        }

        return PackageCleanupPreview(today: today, cutoffDate: cutoffDate, olderThanDays: olderThanDays, candidates: candidates)
    }

    public func apply(olderThanDays: Int, today: String = DateFormatter.navCenterCoreDay.string(from: Date()), deleteTracked: Bool, confirmed: Bool) throws -> PackageCleanupResult {
        guard confirmed else {
            throw NavCenterError.invalidPath("Package cleanup requires explicit confirmation.")
        }
        let preview = try preview(olderThanDays: olderThanDays, today: today)
        let tracked = preview.candidates.filter(\.isTracked)
        if !tracked.isEmpty && !deleteTracked {
            throw NavCenterError.invalidPath("Cleanup includes tracked packages; pass --delete-tracked to remove tracker rows.")
        }

        for candidate in preview.candidates {
            _ = try PathSafety.resolvePackage(root: repoRoot, packageName: candidate.packageName)
        }

        let evidence = try prepareEvidenceDirectory()
        let backup = try backupDatabase(into: evidence)
        let manifest = evidence.appendingPathComponent("manifest.json")
        try writeManifest(preview: preview, to: manifest)

        for candidate in preview.candidates {
            let packageURL = PathSafety.applicationsRoot(repoRoot: repoRoot).appendingPathComponent(candidate.packageName, isDirectory: true)
            try FileManager.default.removeItem(at: packageURL)
        }
        try removeTrackerRows(preview.candidates.compactMap(\.trackerID))
        try TrackerStore(repoRoot: repoRoot, dbPath: dbPath).refreshMarkdownSnapshot()

        return PackageCleanupResult(preview: preview, removedPackages: preview.candidates, backupURL: backup, manifestURL: manifest)
    }

    private func packageDirectories() throws -> [String] {
        let applications = PathSafety.applicationsRoot(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: applications.path) else { return [] }
        try PathSafety.assertNoSymlinkSegments(applications, root: repoRoot, label: "applications root")
        let names = try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .map(\.lastPathComponent)
            .sorted()
        for name in names where Self.packageDate(name) == nil {
            throw NavCenterError.invalidPath("Package folder has no YYYY-MM-DD date prefix: applications/\(name)")
        }
        return names
    }

    private func trackerRowsByPackageName() throws -> [String: TrackerApplicationRow] {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return [:] }
        var rowsByPackage: [String: TrackerApplicationRow] = [:]
        for row in try TrackerStore(repoRoot: repoRoot, dbPath: dbPath).loadRows() {
            let parts = row.applicationDir.split(separator: "/").map(String.init)
            guard parts.count == 2, parts[0] == "applications" else { continue }
            rowsByPackage[parts[1]] = row
        }
        return rowsByPackage
    }

    private func removeTrackerRows(_ ids: [String]) throws {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: dbPath.path) else { return }
        let quotedIDs = ids.map(SQLiteSupport.quote).joined(separator: ", ")
        try SQLiteSupport.run(dbPath: dbPath, repoRoot: repoRoot, sql: """
        begin transaction;
        delete from artifacts where application_id in (\(quotedIDs));
        delete from status_events where application_id in (\(quotedIDs));
        delete from applications where id in (\(quotedIDs));
        commit;
        """)
    }

    private func prepareEvidenceDirectory() throws -> URL {
        let stamp = DateFormatter.navCenterCleanupStamp.string(from: Date())
        let url = repoRoot.appendingPathComponent("tmp/package-cleanup/\(stamp)", isDirectory: true)
        try PathSafety.assertWritablePath(url.appendingPathComponent(".keep"), inside: repoRoot, label: "Package cleanup evidence")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func backupDatabase(into directory: URL) throws -> URL {
        let backup = directory.appendingPathComponent("applications.sqlite.backup")
        if FileManager.default.fileExists(atPath: dbPath.path) {
            try FileManager.default.copyItem(at: dbPath, to: backup)
        } else {
            try Data().write(to: backup)
        }
        return backup
    }

    private func writeManifest(preview: PackageCleanupPreview, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preview).write(to: url)
    }

    private static func packageDate(_ packageName: String) -> String? {
        let prefix = String(packageName.prefix(10))
        return prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil ? nil : prefix
    }

    private static func cutoffDate(today: String, olderThanDays: Int) throws -> String {
        guard let date = DateFormatter.navCenterCoreDay.date(from: today),
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -olderThanDays, to: date) else {
            throw NavCenterError.invalidPath("Invalid cleanup date: \(today)")
        }
        return DateFormatter.navCenterCoreDay.string(from: cutoff)
    }
}

public extension DateFormatter {
    static let navCenterCoreDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let navCenterCleanupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
