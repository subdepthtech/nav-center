import Foundation
import Darwin
import NavCenterCore

// Configuration is immutable. DashboardStore serializes local operations; Codex
// operations delegate to NativeCodexBridge, which owns its synchronization.
final class NativeDashboardService: @unchecked Sendable {
    let repoRoot: URL

    private let inspector: PackageInspector
    private let actionRunner: PackageActionRunner
    private let environment: [String: String]

    init(repoRoot: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let root = repoRoot ?? WorkspaceManager.resolveWorkspaceRoot(environment: environment)
        self.repoRoot = root
        self.environment = environment
        self.inspector = PackageInspector(repoRoot: root)
        self.actionRunner = PackageActionRunner(repoRoot: root, environment: environment)
    }

    func fetchToolAvailability() throws -> ToolAvailabilityReport {
        ToolProbe.report(configuration: ToolProbeConfiguration(environment: environment))
    }

    func fetchSummary() throws -> DashboardSummary {
        let data = try loadData()
        let today = DateFormatter.navCenterDay.string(from: Date())
        let upcoming = data.applications
            .filter { !$0.nextActionDate.isEmpty }
            .sorted { $0.nextActionDate < $1.nextActionDate }
            .prefix(12)
            .map(compact)

        var statusCounts: [String: Int] = [:]
        for application in data.applications {
            statusCounts[application.status, default: 0] += 1
        }

        return DashboardSummary(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            localOnly: true,
            totals: DashboardTotals(
                applications: data.applications.count,
                trackerRows: data.applications.filter(\.source.tracker).count,
                packageOnly: data.applications.filter { !$0.source.tracker && $0.source.package }.count,
                packages: data.packages.count,
                artifacts: data.packages.reduce(0) { $0 + $1.health.artifactCount },
                nextActionsDue: data.applications.filter { !$0.nextActionDate.isEmpty && $0.nextActionDate <= today }.count,
                pursueNow: data.applications.filter { Self.isPursueNow($0.status) }.count,
                generated: data.applications.filter { $0.status.lowercased().contains("generated") }.count,
                submitted: data.applications.filter { $0.status.lowercased().contains("submitted") }.count,
                interviews: data.applications.filter { $0.status.lowercased().contains("interview") }.count
            ),
            statusCounts: statusCounts,
            upcomingActions: Array(upcoming),
            recentApplications: Array(data.applications.prefix(10).map(compact)),
            packageHealth: PackageHealthSummary(
                withPosting: data.packages.filter { $0.health.hasPosting }.count,
                withResumeSource: data.packages.filter { $0.health.hasResumeSource }.count,
                withInterviewPrep: data.packages.filter { $0.health.hasInterviewPrep }.count,
                withArtifacts: data.packages.filter { $0.health.artifactCount > 0 }.count,
                withAtsFiles: data.packages.filter { $0.health.atsFileCount > 0 }.count
            ),
            sources: data.sources
        )
    }

    func fetchApplications(limit: Int = 500) throws -> ApplicationsResponse {
        let data = try loadData()
        let applications = Array(data.applications.prefix(limit))
        return ApplicationsResponse(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            total: data.applications.count,
            limit: limit,
            offset: 0,
            applications: applications,
            sources: data.sources
        )
    }

    func fetchPackage(named packageName: String) throws -> PackageResponse {
        let data = try loadData()
        guard let package = data.packages.first(where: { $0.name == packageName }) else {
            throw DashboardAPIError.missingPackageName
        }
        let application = data.applications.first(where: { $0.packageName == packageName })
        return PackageResponse(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            package: package,
            application: application,
            statusEvents: [],
            sources: data.sources
        )
    }

    func fetchTab(packageName: String, tabKey: String, file: String? = nil) throws -> PackageTabPreviewResponse {
        let package = try fetchPackage(named: packageName).package
        guard let tab = package.tabs.first(where: { $0.key == tabKey }) else {
            throw DashboardAPIError.serverUnavailable("Package tab not found: \(tabKey)")
        }
        let targetFile = file.flatMap { path in tab.files.first { $0.relativePath == path } } ?? tab.primaryFile
        let content = try targetFile.flatMap { try fetchFilePreview(packageName: packageName, file: $0.relativePath).content }
        return PackageTabPreviewResponse(
            packageName: packageName,
            tab: tab,
            file: targetFile.map { previewFile(packageName: packageName, file: $0) },
            content: content
        )
    }

    func fetchFilePreview(packageName: String, file: String) throws -> PackageFilePreviewResponse {
        let package = try fetchPackage(named: packageName).package
        guard let packageFile = package.files.first(where: { $0.relativePath == file }), packageFile.previewable else {
            throw DashboardAPIError.serverUnavailable("File preview is not available: \(file)")
        }
        let fileURL = try localFileURL(packageName: packageName, relativePath: file)
        try PathSafety.assertExistingRegularFile(fileURL, inside: PathSafety.applicationsRoot(repoRoot: repoRoot).appendingPathComponent(packageName), label: "Package preview")
        return PackageFilePreviewResponse(
            file: previewFile(packageName: packageName, file: packageFile),
            content: try String(contentsOf: fileURL)
        )
    }

    func fetchActions(packageName: String, limit: Int = 20) -> ActionLogResponse {
        ActionLogResponse(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            localOnly: true,
            actions: actionRunner.actionLog(packageName: packageName, limit: limit).map(Self.convertAction)
        )
    }

    func runAction(packageName: String, actionKey: String, confirmed: Bool) throws -> ActionResultResponse {
        try ensureWorkspace()
        let entry = try actionRunner.run(packageName: packageName, actionKey: actionKey, confirmed: confirmed)
        return ActionResultResponse(ok: entry.status == "succeeded", action: Self.convertAction(entry))
    }

    func updatePackageStatus(packageName: String, status: TrackerStatus) throws -> TrackerStatusUpdateResult {
        try ensurePackageWorkspace()
        try ensureTrackerWriteAllowed(failureMessage: "Status changes are disabled because the tracker could not be read.")
        return try TrackerStore(repoRoot: repoRoot, dbPath: trackerDB).updateStatus(packageName: packageName, status: status)
    }

    func previewPackageCleanup(olderThanDays: Int = 7) throws -> PackageCleanupPreview {
        try ensurePackageWorkspace()
        return try PackageCleanup(repoRoot: repoRoot, dbPath: trackerDB).preview(olderThanDays: olderThanDays)
    }

    func applyPackageCleanup(olderThanDays: Int = 7, deleteTracked: Bool = true, expectedPreview: PackageCleanupPreview) throws -> PackageCleanupResult {
        try ensurePackageWorkspace()
        if deleteTracked { try ensureTrackerWriteAllowed(failureMessage: "Tracked cleanup is disabled because the tracker could not be read.") }
        return try PackageCleanup(repoRoot: repoRoot, dbPath: trackerDB).apply(
            olderThanDays: olderThanDays,
            deleteTracked: deleteTracked,
            confirmed: true,
            expectedPreview: expectedPreview
        )
    }

    func importDocuments(_ urls: [URL]) throws -> [ImportedDocument] {
        try ensureWorkspace()
        return try DocumentImporter(workspaceRoot: repoRoot).importDocuments(urls)
    }

    func createPackage(from request: JobDescriptionIntakeRequest) throws -> CreateApplicationResult {
        try ensureWorkspace()
        let trimmed = request.trimmed
        return try ApplicationCreator(repoRoot: repoRoot).create(options: CreateApplicationOptions(
            source: NavCenterCore.ApplicationSource.inline(InlineApplicationSource(
                content: trimmed.postingText,
                sourceURL: trimmed.sourceURL,
                title: trimmed.role,
                sourceName: trimmed.sourceName,
                sourceID: trimmed.sourceID,
                location: trimmed.location,
                salary: trimmed.salary,
                postedDate: trimmed.postedDate,
                jobType: trimmed.jobType,
                workSettings: trimmed.workSettings
            )),
            company: trimmed.company,
            role: trimmed.role,
            date: nil,
            dryRun: false,
            overwrite: false,
            allowLocalURL: false
        ))
    }

    func loadMasterResume() throws -> MasterResumeSnapshot {
        try ensureWorkspace()
        return try MasterResumeStore(repoRoot: repoRoot).load()
    }

    func saveMasterResume(content: String, expectedContent: String?) throws -> MasterResumeSaveResult {
        try ensureWorkspace()
        return try MasterResumeStore(repoRoot: repoRoot).save(content: content, expectedContent: expectedContent)
    }

    func prepareRealtimeInterviewKit(packageName: String, overwrite: Bool = false) throws -> RealtimeInterviewKitResponse {
        try ensureWorkspace()
        let result = try RealtimeInterviewKitGenerator(repoRoot: repoRoot).create(
            applicationPath: "applications/\(packageName)",
            dryRun: false,
            overwrite: overwrite
        )
        return RealtimeInterviewKitResponse(
            ok: true,
            packageName: packageName,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            outputPaths: result.outputURLs.map { PathSafety.repoRelativePath(root: repoRoot, url: $0) },
            sessionConfigPath: PathSafety.repoRelativePath(root: repoRoot, url: result.sessionConfigURL),
            transcriptPath: PathSafety.repoRelativePath(root: repoRoot, url: result.transcriptURL),
            reviewPromptPath: PathSafety.repoRelativePath(root: repoRoot, url: result.reviewPromptURL),
            wroteFiles: result.wroteFiles
        )
    }

    func realtimeInterviewReviewPrompt(packageName: String) throws -> String {
        try ensureWorkspace()
        return try RealtimeInterviewKitGenerator(repoRoot: repoRoot).reviewPrompt(applicationPath: "applications/\(packageName)")
    }

    func localFileURL(packageName: String, relativePath: String) throws -> URL {
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/"), !relativePath.contains("\\") else {
            throw DashboardAPIError.serverUnavailable("Package file path is not allowed: \(relativePath)")
        }
        let url = resolved.packageURL.appendingPathComponent(relativePath)
        try PathSafety.assertExistingRegularFile(url, inside: resolved.packageURL, label: "Package file")
        return url
    }

    func fetchCodexStatus() throws -> CodexStatusResponse {
        try NativeCodexBridge.shared(repoRoot: repoRoot).status()
    }

    func startCodexLogin(type: String = "chatgptDeviceCode") throws -> CodexLoginStartResponse {
        try NativeCodexBridge.shared(repoRoot: repoRoot).loginStart(type: type)
    }

    func sendCodexChat(_ payload: CodexChatRequest) throws -> CodexChatResponse {
        try NativeCodexBridge.shared(repoRoot: repoRoot).runPackageChat(payload)
    }

    func cancelCodexTurn() throws {
        NativeCodexBridge.shared(repoRoot: repoRoot).cancelCurrentTurn()
    }

    private struct LoadedData {
        var applications: [ApplicationRecord]
        var packages: [ApplicationPackage]
        var sources: DashboardSources
    }

    private func loadData() throws -> LoadedData {
        try ensurePackageWorkspace()
        let scan = try inspector.scanWithWarnings()
        let packages = scan.packages.map(Self.convertPackage)
        let packagesByName = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0) })
        let tracker = try loadTrackerRows()
        var applications: [ApplicationRecord] = []
        var usedPackages = Set<String>()

        for row in tracker.rows {
            let packageName = Self.packageName(from: row.applicationDir)
            let package = packageName.flatMap { packagesByName[$0] }
            if let packageName { usedPackages.insert(packageName) }
            applications.append(Self.applicationRecord(row: row, package: package))
        }

        for package in packages where !usedPackages.contains(package.name) {
            applications.append(Self.applicationRecord(row: nil, package: package))
        }

        applications.sort { first, second in
            if first.date != second.date { return first.date > second.date }
            if first.company != second.company { return first.company < second.company }
            return first.role < second.role
        }

        return LoadedData(
            applications: applications,
            packages: packages,
            sources: DashboardSources(
                tracker: TrackerSource(
                    available: tracker.available,
                    driver: "sqlite3",
                    readOnly: false,
                    queryOnly: false,
                    warnings: tracker.warnings
                ),
                packages: PackageSource(
                    available: true,
                    scanned: packages.count,
                    warnings: scan.warnings
                )
            )
        )
    }

    private var trackerDB: URL {
        repoRoot.appendingPathComponent("tracking/applications.sqlite")
    }

    @discardableResult
    private func ensureWorkspace() throws -> WorkspaceInitializationResult {
        try WorkspaceManager(workspaceRoot: repoRoot).initialize()
    }

    @discardableResult
    private func ensurePackageWorkspace() throws -> WorkspaceInitializationResult {
        try WorkspaceManager(workspaceRoot: repoRoot).initializeForPackageBrowsing()
    }

    private struct TrackerRow {
        var id: String
        var date: String
        var company: String
        var position: String
        var applyLink: String
        var status: String
        var notes: String
        var nextActionDate: String
        var applicationDir: String
        var createdAt: String
        var updatedAt: String
    }

    private struct TrackerReadState {
        var rows: [TrackerRow]
        var available: Bool
        var warnings: [String]
    }

    private static let trackerReadWarning = "The tracker could not be read. Packages are still available, but status changes and tracked cleanup are disabled until the tracker is accessible and valid."

    /// Filesystem-level reachability of the tracker, without reading any row.
    ///
    /// Shared by the dashboard read and the write gate so a status change does
    /// not pay for a full tracker load just to learn whether writing is allowed.
    private enum TrackerAccess {
        case missing
        case inaccessible
        case present
    }

    private func trackerFileAccess() throws -> TrackerAccess {
        let directory = trackerDB.deletingLastPathComponent()
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 {
            if errno == ENOENT { return .missing }
            if errno == EACCES || errno == EPERM { return .inaccessible }
            throw NavCenterError.invalidPath("Could not inspect tracking directory: \(String(cString: strerror(errno)))")
        }
        guard (directoryInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw NavCenterError.invalidPath("tracking directory must not contain a symbolic link: tracking")
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw NavCenterError.invalidPath("tracking directory must be a directory.")
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            if errno == EACCES || errno == EPERM { return .inaccessible }
            throw NavCenterError.invalidPath("Could not open tracking directory: \(String(cString: strerror(errno)))")
        }
        var databaseInfo = stat()
        let databaseStatus = fstatat(directoryDescriptor, trackerDB.lastPathComponent, &databaseInfo, AT_SYMLINK_NOFOLLOW)
        let databaseError = errno
        close(directoryDescriptor)
        if databaseStatus != 0 {
            if databaseError == ENOENT { return .missing }
            if databaseError == EACCES || databaseError == EPERM { return .inaccessible }
            throw NavCenterError.invalidPath("Could not inspect tracker database: \(String(cString: strerror(databaseError)))")
        }
        return .present
    }

    private func loadTrackerRows() throws -> TrackerReadState {
        switch try trackerFileAccess() {
        case .missing: return TrackerReadState(rows: [], available: false, warnings: [])
        case .inaccessible: return TrackerReadState(rows: [], available: false, warnings: [Self.trackerReadWarning])
        case .present: break
        }
        let query = """
        SELECT id, date, company, position, apply_link AS applyLink, status, notes, next_action_date AS nextActionDate, application_dir AS applicationDir, created_at AS createdAt, updated_at AS updatedAt
        FROM applications
        ORDER BY date DESC, company, position;
        """
        let rows: [[String: Any]]
        do {
            rows = try TrackerStore.queryRows(repoRoot: repoRoot, dbPath: trackerDB, sql: query)
        } catch {
            return TrackerReadState(rows: [], available: false, warnings: [Self.trackerReadWarning])
        }
        return TrackerReadState(rows: rows.map {
            TrackerRow(
                id: Self.string($0["id"]),
                date: Self.string($0["date"]),
                company: Self.string($0["company"]),
                position: Self.string($0["position"]),
                applyLink: Self.string($0["applyLink"]),
                status: Self.string($0["status"]),
                notes: Self.string($0["notes"]),
                nextActionDate: Self.string($0["nextActionDate"]),
                applicationDir: Self.string($0["applicationDir"]),
                createdAt: Self.string($0["createdAt"]),
                updatedAt: Self.string($0["updatedAt"])
            )
        }, available: true, warnings: [])
    }

    /// Refuse a tracker write the dashboard already knows cannot succeed, using a
    /// reachability probe rather than a full read: the previous implementation
    /// loaded, sorted and mapped every row only to inspect a warning list, and the
    /// write path then opened its own connection and read again.
    ///
    /// This stays a friendly-message fast path, not a guarantee. The tracker can
    /// become unreadable between this probe and the write, so the write path
    /// remains the authority on whether a change actually lands.
    private func ensureTrackerWriteAllowed(failureMessage: String) throws {
        func unavailable() -> DashboardAPIError {
            DashboardAPIError.serverUnavailable("\(failureMessage) Packages and drafts have been kept; refresh after the tracker is accessible and valid.")
        }
        switch try trackerFileAccess() {
        case .missing:
            // First-use tracker creation belongs to the write path itself.
            return
        case .inaccessible:
            throw unavailable()
        case .present:
            // Confirm the database opens and carries the expected table without
            // materializing its rows.
            do {
                _ = try TrackerStore.queryRows(
                    repoRoot: repoRoot,
                    dbPath: trackerDB,
                    sql: "SELECT 1 FROM applications LIMIT 1;"
                )
            } catch {
                throw unavailable()
            }
        }
    }

    private static func convertPackage(_ package: NavCenterCore.ApplicationPackage) -> ApplicationPackage {
        let files = package.files.map(convertFile)
        let health = PackageHealth(
            hasPosting: package.health.hasPosting,
            hasResumeSource: package.health.hasResumeSource,
            hasCoverLetterSource: package.health.hasCoverLetterSource,
            hasInterviewPrep: package.health.hasInterviewPrep,
            artifactCount: package.health.artifactCount,
            atsFileCount: package.health.atsFileCount,
            hasAtsReport: package.health.hasAtsReport,
            hasAtsJson: package.health.hasAtsJson,
            previewableCount: package.health.previewableCount
        )
        return ApplicationPackage(
            name: package.name,
            applicationDir: package.applicationDir,
            metadata: package.metadata.mapValues(JSONValue.string),
            files: files,
            tabs: package.tabs.map { tab in
                let tabFiles = tab.files.map(convertFile)
                return PackageTab(
                    key: tab.key,
                    label: tab.label,
                    available: tab.available,
                    fileCount: tab.fileCount,
                    primaryFile: tab.primaryFile.map(convertFile),
                    files: tabFiles
                )
            },
            artifactSummary: ArtifactSummary(
                total: health.artifactCount,
                previewable: health.previewableCount,
                ats: health.atsFileCount,
                byFormat: Dictionary(grouping: files, by: \.format).mapValues(\.count),
                byKind: Dictionary(grouping: files, by: \.kind).mapValues(\.count)
            ),
            health: health
        )
    }

    private static func convertFile(_ file: NavCenterCore.PackageFile) -> PackageFile {
        PackageFile(
            relativePath: file.relativePath,
            label: file.label,
            kind: file.kind,
            format: file.format,
            size: file.size,
            modifiedAt: file.modifiedAt,
            previewable: file.previewable,
            previewUrl: nil,
            rawUrl: nil,
            editable: file.editable
        )
    }

    private static func applicationRecord(row: TrackerRow?, package: ApplicationPackage?) -> ApplicationRecord {
        let fallback = parsePackageName(package?.name ?? packageName(from: row?.applicationDir ?? "") ?? "")
        let metadata = package?.metadata ?? [:]
        let packageName = package?.name ?? packageName(from: row?.applicationDir ?? "") ?? ""
        let company = row?.company ?? metadata["company"]?.stringValue ?? fallback.company
        let role = row?.position ?? metadata["role"]?.stringValue ?? fallback.role
        let notes = row?.notes ?? ""
        return ApplicationRecord(
            id: row?.id ?? packageName,
            packageName: packageName,
            date: row?.date ?? metadata["captured"]?.stringValue ?? fallback.date,
            company: company,
            role: role,
            location: metadata["location"]?.stringValue ?? "",
            salary: metadata["salary"]?.stringValue ?? "",
            status: row?.status ?? metadata["status"]?.stringValue ?? "Package Only",
            nextActionDate: row?.nextActionDate ?? "",
            applicationDir: row?.applicationDir ?? package?.applicationDir ?? "",
            applyLink: row?.applyLink ?? metadata["source_url"]?.stringValue ?? "",
            sourceName: metadata["source_name"]?.stringValue ?? "",
            sourceId: metadata["source_id"]?.stringValue ?? "",
            notes: notes,
            notesPreview: notes.count > 240 ? String(notes.prefix(240)) : notes,
            createdAt: row?.createdAt ?? "",
            updatedAt: row?.updatedAt ?? "",
            source: ApplicationSource(tracker: row != nil, package: package != nil),
            health: package?.health ?? .empty,
            files: package?.files ?? [],
            dbArtifacts: []
        )
    }

    private func compact(_ application: ApplicationRecord) -> ApplicationSummary {
        ApplicationSummary(
            id: application.id,
            packageName: application.packageName,
            date: application.date,
            company: application.company,
            role: application.role,
            location: application.location,
            status: application.status,
            nextActionDate: application.nextActionDate,
            packageUrl: nil
        )
    }

    private func previewFile(packageName: String, file: PackageFile) -> PackagePreviewFile {
        PackagePreviewFile(
            packageName: packageName,
            path: file.relativePath,
            label: file.label,
            size: file.size,
            modifiedAt: file.modifiedAt,
            contentType: contentType(file.format),
            encoding: "utf-8"
        )
    }

    private static func convertAction(_ entry: PackageActionEntry) -> DashboardAction {
        DashboardAction(
            id: entry.id,
            action: entry.action,
            label: entry.label,
            packageName: entry.packageName,
            status: entry.status,
            requestedAt: entry.requestedAt,
            completedAt: entry.completedAt,
            durationMs: entry.durationMs,
            command: entry.command,
            outputPath: entry.outputPath,
            exitCode: entry.exitCode.map(Int.init),
            signal: nil,
            message: entry.message,
            stdoutTail: entry.stdoutTail,
            stderrTail: entry.stderrTail
        )
    }

    private static func packageName(from applicationDir: String) -> String? {
        let parts = applicationDir.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "applications" else { return nil }
        return parts[1]
    }

    private static func parsePackageName(_ name: String) -> (date: String, company: String, role: String) {
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 3 else { return ("", name, "") }
        return (parts[0], parts.dropFirst().dropLast().joined(separator: " "), parts.last ?? "")
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value)
    }

    private static func isPursueNow(_ status: String) -> Bool {
        let lower = status.lowercased()
        return lower.contains("generated") || lower.contains("sourced") || lower.contains("pursue")
    }

    private func contentType(_ format: String) -> String {
        switch format.lowercased() {
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "html": return "text/html"
        default: return "text/plain"
        }
    }

}

extension NativeDashboardService: DashboardServicing {}

private extension DateFormatter {
    static let navCenterDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
