import Foundation
import CryptoKit
import Darwin

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
    public let fingerprint: String

    public init(today: String, cutoffDate: String, olderThanDays: Int, candidates: [PackageCleanupCandidate], fingerprint: String = "") {
        self.today = today
        self.cutoffDate = cutoffDate
        self.olderThanDays = olderThanDays
        self.candidates = candidates
        self.fingerprint = fingerprint
    }
}

public struct PackageCleanupResult: Codable, Equatable {
    public let preview: PackageCleanupPreview
    public let removedPackages: [PackageCleanupCandidate]
    public let backupURL: URL
    public let manifestURL: URL
    public var warnings: [String]

    public init(preview: PackageCleanupPreview, removedPackages: [PackageCleanupCandidate], backupURL: URL, manifestURL: URL, warnings: [String] = []) {
        self.preview = preview
        self.removedPackages = removedPackages
        self.backupURL = backupURL
        self.manifestURL = manifestURL
        self.warnings = warnings
    }
}

public final class PackageCleanup {
    private let repoRoot: URL
    private let dbPath: URL
    // Internal fault injection for deterministic persistence-boundary tests.
    var beforeManifestWrite: ((String, URL) throws -> Void)?

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

        var digest = SHA256()
        digest.update(data: Data(try filesystemIdentity(repoRoot).utf8))
        if SQLiteSupport.exists(dbPath) { digest.update(data: Data(try filesystemIdentity(dbPath).utf8)) }
        for candidate in candidates {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            digest.update(data: try encoder.encode(candidate))
            if let row = trackerRows[candidate.packageName] { digest.update(data: try encoder.encode(row)) }
            let package = try PathSafety.resolvePackage(root: repoRoot, packageName: candidate.packageName)
            digest.update(data: Data(try packageFingerprint(package.packageURL).utf8))
        }
        return PackageCleanupPreview(today: today, cutoffDate: cutoffDate, olderThanDays: olderThanDays, candidates: candidates, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public func apply(olderThanDays: Int, today: String = DateFormatter.navCenterCoreDay.string(from: Date()), deleteTracked: Bool, confirmed: Bool, expectedPreview: PackageCleanupPreview? = nil) throws -> PackageCleanupResult {
        guard confirmed, let expectedPreview, !expectedPreview.fingerprint.isEmpty else {
            throw NavCenterError.invalidPath("Package cleanup requires confirmation of a current preview. Preview the packages again.")
        }
        let current = try preview(olderThanDays: olderThanDays, today: today)
        guard current == expectedPreview else { throw NavCenterError.invalidPath("Cleanup preview changed. Review the packages again before confirming.") }
        guard deleteTracked || !current.candidates.contains(where: \.isTracked) else {
            throw NavCenterError.invalidPath("Cleanup includes tracked packages; pass --delete-tracked to remove tracker rows.")
        }
        let databaseExisted = SQLiteSupport.exists(dbPath)
        let connection = databaseExisted ? try SQLiteSupport.Connection(dbPath: dbPath, repoRoot: repoRoot, writable: true) : nil
        try connection?.validateSchema()
        let evidence = try prepareEvidenceDirectory()
        let lease = try lockEvidenceDirectory(evidence)
        defer { _ = flock(lease, LOCK_UN); close(lease) }
        let packagesBackup = evidence.appendingPathComponent("packages", isDirectory: true)
        try PathSafety.createDirectory(packagesBackup, inside: repoRoot, label: "cleanup package backup")
        let backup = evidence.appendingPathComponent("applications.sqlite.backup")
        let manifestURL = evidence.appendingPathComponent("manifest.json")
        var manifest = CleanupManifest(version: 2, state: "prepared", preview: current, databaseExisted: databaseExisted, packageFingerprints: [:], backupReady: false)
        for candidate in current.candidates {
            manifest.packageFingerprints[candidate.packageName] = try packageFingerprint(PathSafety.applicationsRoot(repoRoot: repoRoot).appendingPathComponent(candidate.packageName))
        }
        try writeManifest(manifest, to: manifestURL)
        var moved: [PackageCleanupCandidate] = []
        let operation = {
            guard try self.preview(olderThanDays: olderThanDays, today: today) == expectedPreview else {
                throw NavCenterError.invalidPath("Cleanup preview changed before removal. Preview the packages again.")
            }
            if databaseExisted {
                // A separate reader can back up the committed snapshot while our
                // BEGIN IMMEDIATE connection excludes other database writers.
                try SQLiteSupport.Connection(dbPath: self.dbPath, repoRoot: self.repoRoot, writable: false).backup(to: backup)
                manifest.databaseBackupDigest = try self.backupDigest(backup)
            }
            // This durable boundary precedes every package move and SQL delete.
            manifest.backupReady = true
            try self.writeManifest(manifest, to: manifestURL)
            for candidate in current.candidates {
                let source = PathSafety.applicationsRoot(repoRoot: self.repoRoot).appendingPathComponent(candidate.packageName, isDirectory: true)
                guard try self.packageFingerprint(source) == manifest.packageFingerprints[candidate.packageName] else {
                    throw NavCenterError.invalidPath("Package changed after cleanup preview: \(candidate.packageName)")
                }
                try PathSafety.moveItem(source, to: packagesBackup.appendingPathComponent(candidate.packageName), inside: self.repoRoot, label: "recoverable package cleanup")
                moved.append(candidate)
            }
            if let connection { try self.removeTrackerRows(current.candidates.compactMap(\.trackerID), connection: connection) }
        }
        do {
            if let connection { try connection.transaction(operation) } else { try operation() }
        } catch {
            var rollbackErrors: [String] = []
            for candidate in moved.reversed() {
                do {
                    try PathSafety.moveItem(packagesBackup.appendingPathComponent(candidate.packageName), to: PathSafety.applicationsRoot(repoRoot: repoRoot).appendingPathComponent(candidate.packageName), inside: repoRoot, label: "cleanup rollback")
                } catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty { throw NavCenterError.commandFailed("Cleanup failed; some package backups require recovery from \(evidence.path): \(rollbackErrors.joined(separator: "; "))") }
            throw error
        }
        manifest.state = "completed"
        var warnings: [String] = []
        do { try writeManifest(manifest, to: manifestURL) }
        catch { warnings.append("Cleanup committed and backups are retained, but the recovery manifest status could not be updated: \(error.localizedDescription)") }
        if databaseExisted {
            do { try TrackerStore(repoRoot: repoRoot, dbPath: dbPath).refreshMarkdownSnapshot() }
            catch { warnings.append("Cleanup committed. The derived tracker Markdown could not be refreshed: \(error.localizedDescription)") }
        }
        return PackageCleanupResult(preview: current, removedPackages: current.candidates, backupURL: databaseExisted ? backup : evidence, manifestURL: manifestURL, warnings: warnings)
    }

    /// Restores completed or interrupted cleanup after validating the exact
    /// original/backup package locations and the affected tracker record sets.
    public func restore(manifestURL: URL, confirmed: Bool) throws -> PackageCleanupResult {
        guard confirmed else { throw NavCenterError.invalidPath("Cleanup restore requires explicit confirmation.") }
        let evidenceRoot = repoRoot.appendingPathComponent("tmp/package-cleanup", isDirectory: true)
        try PathSafety.assertNoSymlinkSegments(manifestURL, root: evidenceRoot, label: "cleanup recovery manifest")
        let evidence = manifestURL.deletingLastPathComponent()
        let lease = try lockEvidenceDirectory(evidence)
        defer { _ = flock(lease, LOCK_UN); close(lease) }
        let bytes = try PathSafety.readData(manifestURL, inside: evidenceRoot, label: "cleanup recovery manifest")
        var manifest = try JSONDecoder().decode(CleanupManifest.self, from: bytes)
        guard [1, 2].contains(manifest.version), ["prepared", "completed"].contains(manifest.state) else {
            throw NavCenterError.invalidPath("This cleanup manifest is unsupported or was already restored.")
        }
        let candidates = manifest.preview.candidates
        guard Set(candidates.map(\.packageName)).count == candidates.count,
              Set(manifest.packageFingerprints.keys) == Set(candidates.map(\.packageName)) else {
            throw NavCenterError.invalidPath("Cleanup recovery manifest contains duplicate or incomplete package identities.")
        }
        let packagesBackup = evidence.appendingPathComponent("packages", isDirectory: true)
        let backup = evidence.appendingPathComponent("applications.sqlite.backup")
        var toMove: [PackageCleanupCandidate] = []
        for candidate in candidates {
            guard try PathSafety.normalizePackageName(candidate.packageName) == candidate.packageName,
                  candidate.applicationDir == "applications/" + candidate.packageName,
                  candidate.isTracked == (candidate.trackerID != nil) else {
                throw NavCenterError.invalidPath("Cleanup recovery manifest has an invalid package or tracker binding.")
            }
            let original = PathSafety.applicationsRoot(repoRoot: repoRoot).appendingPathComponent(candidate.packageName)
            let retained = packagesBackup.appendingPathComponent(candidate.packageName)
            let originalExists = SQLiteSupport.exists(original)
            let backupExists = SQLiteSupport.exists(retained)
            guard originalExists != backupExists else {
                throw NavCenterError.invalidPath("Recovery requires exactly one original or retained package: \(candidate.packageName). Existing or missing targets require review.")
            }
            let current = originalExists ? original : retained
            guard try packageFingerprint(current) == manifest.packageFingerprints[candidate.packageName] else {
                throw NavCenterError.invalidPath("Package content or identity changed since cleanup: \(candidate.packageName). Newer work was preserved.")
            }
            if backupExists { toMove.append(candidate) }
        }

        // A v2 manifest without this marker predates all package/DB mutations.
        // An incomplete backup is irrelevant only when every original is intact.
        let beforeBackup = manifest.version == 2 && manifest.backupReady != true
        if beforeBackup {
            guard manifest.state == "prepared", toMove.isEmpty else {
                throw NavCenterError.invalidPath("Cleanup has moved packages without a complete recorded backup. Automatic recovery was refused.")
            }
        }
        let needsDatabase = manifest.databaseExisted && !beforeBackup
        if needsDatabase, manifest.version == 2 {
            guard let digest = manifest.databaseBackupDigest, try backupDigest(backup) == digest else {
                throw NavCenterError.invalidPath("The retained tracker backup changed or is incomplete. Automatic recovery was refused.")
            }
        }
        let source = needsDatabase ? try SQLiteSupport.Connection(dbPath: backup, repoRoot: repoRoot, writable: false) : nil
        let connection = needsDatabase ? try SQLiteSupport.Connection(dbPath: dbPath, repoRoot: repoRoot, writable: true) : nil
        try source?.validateSchema()
        try connection?.validateSchema()
        var movedThisAttempt: [PackageCleanupCandidate] = []
        let operation = {
            if let connection, let source {
                var insertions: [String] = []
                var recordStates = Set<Bool>()
                for candidate in candidates {
                    guard let id = candidate.trackerID else { continue }
                    let tables = [("applications", "id"), ("status_events", "application_id"), ("artifacts", "application_id")]
                    var expected: [[[String: Any]]] = []
                    var current: [[[String: Any]]] = []
                    for (table, column) in tables {
                        expected.append(try source.rows("select * from \(table) where \(column) = \(SQLiteSupport.quote(id));"))
                        let predicate = table == "applications"
                            ? "id = \(SQLiteSupport.quote(id)) or application_dir = \(SQLiteSupport.quote(candidate.applicationDir))"
                            : "\(column) = \(SQLiteSupport.quote(id))"
                        current.append(try connection.rows("select * from \(table) where \(predicate);"))
                    }
                    guard expected[0].count == 1,
                          SQLiteSupport.string(expected[0][0]["application_dir"]) == candidate.applicationDir,
                          SQLiteSupport.string(expected[0][0]["status"]) == candidate.status else {
                        throw NavCenterError.invalidPath("Tracker backup does not match the confirmed cleanup package: \(candidate.packageName)")
                    }
                    let absent = current.allSatisfy(\.isEmpty)
                    let unchanged = zip(expected, current).allSatisfy { self.canonicalRows($0.0) == self.canonicalRows($0.1) }
                    guard absent || unchanged else {
                        throw NavCenterError.invalidPath("Tracker records changed or are only partly present for \(candidate.packageName). Automatic recovery would conflict with newer work.")
                    }
                    recordStates.insert(absent)
                    if absent {
                        for (tableIndex, definition) in tables.enumerated() {
                            for row in expected[tableIndex] {
                                let columns = row.keys.sorted()
                                let values = columns.map { SQLiteSupport.literal(row[$0]!) }.joined(separator: ",")
                                insertions.append("insert into \(definition.0) (\(columns.map(SQLiteSupport.identifier).joined(separator: ","))) values (\(values));")
                            }
                        }
                    }
                }
                guard recordStates.count <= 1 else {
                    throw NavCenterError.invalidPath("Tracker records show a partial cleanup or later related changes. Automatic recovery was refused.")
                }
                // User-defined triggers could change unrelated records despite
                // these narrow INSERT statements. Do not guess their effects.
                if !insertions.isEmpty {
                    let triggers = try connection.rows("select name from sqlite_master where type = 'trigger' and tbl_name in ('applications', 'status_events', 'artifacts');")
                    guard triggers.isEmpty else {
                        throw NavCenterError.invalidPath("Tracker has custom triggers. Review them before automatic row restoration; existing records were preserved.")
                    }
                }
                // Validate every affected record before inserting any of them.
                for statement in insertions { try connection.execute(statement) }
            }
            for candidate in toMove {
                let retained = packagesBackup.appendingPathComponent(candidate.packageName)
                guard try self.packageFingerprint(retained) == manifest.packageFingerprints[candidate.packageName] else {
                    throw NavCenterError.invalidPath("Retained package changed during recovery: \(candidate.packageName)")
                }
                try PathSafety.moveItem(retained, to: PathSafety.applicationsRoot(repoRoot: self.repoRoot).appendingPathComponent(candidate.packageName), inside: self.repoRoot, label: "cleanup restore")
                movedThisAttempt.append(candidate)
            }
        }
        do {
            if let connection { try connection.transaction(operation) } else { try operation() }
        } catch {
            var failures: [String] = []
            for candidate in movedThisAttempt.reversed() {
                do { try PathSafety.moveItem(PathSafety.applicationsRoot(repoRoot: repoRoot).appendingPathComponent(candidate.packageName), to: packagesBackup.appendingPathComponent(candidate.packageName), inside: repoRoot, label: "restore rollback") }
                catch { failures.append(error.localizedDescription) }
            }
            guard failures.isEmpty else { throw NavCenterError.commandFailed("Restore failed; retained recovery data requires review: \(failures.joined(separator: "; "))") }
            throw error
        }
        manifest.state = "restored"
        var warnings: [String] = []
        do { try writeManifest(manifest, to: manifestURL) }
        catch { warnings.append("Packages and tracker records were restored, but the manifest status could not be updated. Confirmed recovery can safely be retried.") }
        if needsDatabase {
            do { try TrackerStore(repoRoot: repoRoot, dbPath: dbPath).refreshMarkdownSnapshot() }
            catch { warnings.append("Restore committed. Tracker Markdown refresh failed: \(error.localizedDescription)") }
        }
        return PackageCleanupResult(preview: manifest.preview, removedPackages: [], backupURL: manifest.databaseExisted ? backup : evidence, manifestURL: manifestURL, warnings: warnings)
    }

    private func lockEvidenceDirectory(_ directory: URL) throws -> Int32 {
        try PathSafety.assertNoSymlinkSegments(directory, root: repoRoot, label: "cleanup evidence")
        let identity = try PathSafety.identity(directory)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NavCenterError.invalidPath("Could not open cleanup evidence for recovery.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode else {
            close(descriptor)
            throw NavCenterError.invalidPath("Cleanup evidence directory changed during access.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NavCenterError.invalidPath("Cleanup or recovery is still active for this backup. Wait for it to stop before retrying.")
        }
        return descriptor
    }

    private func canonicalRows(_ rows: [[String: Any]]) -> [String] {
        rows.map { row in
            row.keys.sorted().map { key in
                let value = row[key]!
                // Length-delimited keys and typed scalar values retain duplicate
                // rows, nulls, blobs, and integer/real distinctions without order.
                let scalar = String(reflecting: type(of: value)) + ":" + SQLiteSupport.literal(value)
                return "\(key.utf8.count):\(key)\(scalar.utf8.count):\(scalar)"
            }.joined()
        }.sorted()
    }

    private func backupDigest(_ url: URL) throws -> String {
        let data = try PathSafety.readData(url, inside: repoRoot, label: "cleanup tracker backup", maxBytes: 256 * 1024 * 1024)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            guard rowsByPackage[parts[1]] == nil else { throw NavCenterError.invalidPath("Multiple tracker records refer to applications/\(parts[1]). Resolve duplicates before cleanup.") }
            rowsByPackage[parts[1]] = row
        }
        return rowsByPackage
    }

    private func removeTrackerRows(_ ids: [String], connection: SQLiteSupport.Connection) throws {
        guard !ids.isEmpty else { return }
        let quotedIDs = ids.map(SQLiteSupport.quote).joined(separator: ", ")
        try connection.execute("""
        delete from artifacts where application_id in (\(quotedIDs));
        delete from status_events where application_id in (\(quotedIDs));
        delete from applications where id in (\(quotedIDs));
        """)
    }

    private func prepareEvidenceDirectory() throws -> URL {
        let stamp = DateFormatter.navCenterCleanupStamp.string(from: Date()) + "-" + UUID().uuidString
        let url = repoRoot.appendingPathComponent("tmp/package-cleanup/\(stamp)", isDirectory: true)
        try PathSafety.createDirectory(url, inside: repoRoot, label: "Package cleanup evidence")
        return url
    }

    private struct CleanupManifest: Codable {
        var version: Int
        var state: String
        var preview: PackageCleanupPreview
        var databaseExisted: Bool
        var packageFingerprints: [String: String]
        var backupReady: Bool? = nil
        var databaseBackupDigest: String? = nil
    }

    private func writeManifest(_ manifest: CleanupManifest, to url: URL) throws {
        try beforeManifestWrite?(manifest.state, url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PathSafety.atomicWrite(encoder.encode(manifest), to: url, inside: repoRoot, label: "cleanup manifest")
    }

    private func filesystemIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NavCenterError.invalidPath("Could not inspect cleanup filesystem identity.") }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private func packageFingerprint(_ url: URL) throws -> String {
        try PathSafety.assertNoSymlinkSegments(url, root: repoRoot, label: "cleanup package")
        var digest = SHA256()
        var count = 0
        func visit(_ entry: URL) throws {
            count += 1
            guard count <= 10_000 else { throw NavCenterError.invalidPath("Package contains too many entries for a safe cleanup preview.") }
            try PathSafety.assertNoSymlinkSegments(entry, root: repoRoot, label: "cleanup package entry")
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { throw NavCenterError.invalidPath("Package entry changed during cleanup preview.") }
            digest.update(data: Data((PathSafety.repoRelativePath(root: url, url: entry) + ":" + (try filesystemIdentity(entry))).utf8))
            if (info.st_mode & S_IFMT) == S_IFDIR {
                for child in try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { try visit(child) }
            } else if (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 {
                digest.update(data: try PathSafety.readData(entry, inside: repoRoot, label: "cleanup package entry"))
            } else { throw NavCenterError.invalidPath("Cleanup package contains a linked or unsupported filesystem entry.") }
        }
        try visit(url)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func packageDate(_ packageName: String) -> String? {
        let prefix = String(packageName.prefix(10))
        guard prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = DateFormatter.navCenterCoreDay.date(from: prefix), DateFormatter.navCenterCoreDay.string(from: date) == prefix else { return nil }
        return prefix
    }

    private static func cutoffDate(today: String, olderThanDays: Int) throws -> String {
        guard let date = DateFormatter.navCenterCoreDay.date(from: today), DateFormatter.navCenterCoreDay.string(from: date) == today,
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
