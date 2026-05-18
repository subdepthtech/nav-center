import Foundation

public struct FeedbackDiagnosticsReport: Codable, Equatable {
    public let generatedAt: String
    public let appVersion: String
    public let macOSVersion: String
    public let workspace: WorkspaceDiagnostics
    public let recentLogs: [String]
}

public struct WorkspaceDiagnostics: Codable, Equatable {
    public let path: String
    public let exists: Bool
    public let requiredDirectoriesMissing: [String]
    public let hasMasterResume: Bool
    public let hasTrackerDatabase: Bool
    public let applicationPackageCount: Int
    public let importedMarkdownCount: Int
}

public final class FeedbackDiagnostics {
    private let workspaceRoot: URL
    private let homeDirectory: URL
    private let appVersion: String
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        workspaceRoot: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appVersion: String = "0.1.0-beta",
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.appVersion = appVersion
        self.fileManager = fileManager
        self.now = now
    }

    public func report(redact: Bool) -> FeedbackDiagnosticsReport {
        let redactor = Redactor(homeDirectory: homeDirectory, enabled: redact)
        let workspace = workspaceReport(redactor: redactor)
        return FeedbackDiagnosticsReport(
            generatedAt: ISO8601DateFormatter().string(from: now()),
            appVersion: appVersion,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            workspace: workspace,
            recentLogs: recentLogs(redactor: redactor)
        )
    }

    private func workspaceReport(redactor: Redactor) -> WorkspaceDiagnostics {
        let missing = WorkspaceManager.requiredDirectories.filter { relativePath in
            !fileManager.fileExists(atPath: workspaceRoot.appendingPathComponent(relativePath).path)
        }
        return WorkspaceDiagnostics(
            path: redactor.redact(workspaceRoot.path),
            exists: fileManager.fileExists(atPath: workspaceRoot.path),
            requiredDirectoriesMissing: missing,
            hasMasterResume: fileManager.fileExists(atPath: workspaceRoot.appendingPathComponent("master-resumes/master_primary.yaml").path),
            hasTrackerDatabase: fileManager.fileExists(atPath: workspaceRoot.appendingPathComponent("tracking/applications.sqlite").path),
            applicationPackageCount: directoryCount(workspaceRoot.appendingPathComponent("applications", isDirectory: true)),
            importedMarkdownCount: fileCount(workspaceRoot.appendingPathComponent("imports/markdown", isDirectory: true))
        )
    }

    private func recentLogs(redactor: Redactor) -> [String] {
        let logs = workspaceRoot.appendingPathComponent("logs", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logs,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else {
            return []
        }
        return urls
            .filter { ($0.pathExtension == "log" || $0.pathExtension == "txt") && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(3)
            .compactMap { url in
                guard let text = try? String(contentsOf: url) else { return nil }
                return redactor.redact(String(text.suffix(2_000)))
            }
    }

    private func directoryCount(_ url: URL) -> Int {
        guard let urls = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        return urls.filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }.count
    }

    private func fileCount(_ url: URL) -> Int {
        guard let urls = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        return urls.filter { ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) }.count
    }
}

private struct Redactor {
    let homeDirectory: URL
    let enabled: Bool

    func redact(_ value: String) -> String {
        guard enabled else { return value }
        var redacted = value.replacingOccurrences(of: homeDirectory.path, with: "<home>")
        if let username = homeDirectory.lastPathComponent.split(separator: "/").last, !username.isEmpty {
            redacted = redacted.replacingOccurrences(of: String(username), with: "<user>")
        }
        redacted = redacted.replacingOccurrences(
            of: #"/Users/[^/\s\"]+"#,
            with: "<home>",
            options: .regularExpression
        )
        return redacted
    }
}
