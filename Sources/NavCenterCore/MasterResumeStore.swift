import Foundation

public struct MasterResumeSnapshot: Equatable {
    public let relativePath: String
    public let content: String
    public let modifiedAt: String

    public init(relativePath: String, content: String, modifiedAt: String) {
        self.relativePath = relativePath
        self.content = content
        self.modifiedAt = modifiedAt
    }
}

public struct MasterResumeSaveResult: Equatable {
    public let relativePath: String
    public let savedURL: URL
    public let backupURL: URL
    public let modifiedAt: String

    public init(relativePath: String, savedURL: URL, backupURL: URL, modifiedAt: String) {
        self.relativePath = relativePath
        self.savedURL = savedURL
        self.backupURL = backupURL
        self.modifiedAt = modifiedAt
    }
}

public final class MasterResumeStore {
    private let repoRoot: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot.standardizedFileURL
    }

    public func load() throws -> MasterResumeSnapshot {
        let url = masterResumeURL
        try PathSafety.assertExistingRegularFile(url, inside: repoRoot, label: "master resume")
        return MasterResumeSnapshot(
            relativePath: PathSafety.repoRelativePath(root: repoRoot, url: url),
            content: try String(contentsOf: url),
            modifiedAt: modifiedAt(url)
        )
    }

    public func save(content: String) throws -> MasterResumeSaveResult {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NavCenterError.invalidPath("Master resume content cannot be empty.")
        }

        let url = masterResumeURL
        try PathSafety.assertExistingRegularFile(url, inside: repoRoot, label: "master resume")
        let workDir = repoRoot.appendingPathComponent("tmp/master-resume-editor", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try PathSafety.assertNoSymlinkSegments(workDir, root: repoRoot, label: "master resume work directory")

        let candidate = workDir.appendingPathComponent("candidate-\(UUID().uuidString).yaml")
        try PathSafety.assertWritablePath(candidate, inside: workDir, label: "master resume candidate")
        try content.write(to: candidate, atomically: true, encoding: .utf8)
        do {
            try validateYAML(candidate)
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            throw error
        }

        let backupDir = workDir.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try PathSafety.assertNoSymlinkSegments(backupDir, root: repoRoot, label: "master resume backup directory")
        let backupURL = backupDir.appendingPathComponent("master_primary.\(Self.backupTimestamp()).\(String(UUID().uuidString.prefix(8))).yaml")
        try PathSafety.assertWritablePath(backupURL, inside: backupDir, label: "master resume backup")
        try FileManager.default.copyItem(at: url, to: backupURL)

        try PathSafety.assertWritablePath(url, inside: repoRoot, label: "master resume")
        try content.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: candidate)

        return MasterResumeSaveResult(
            relativePath: PathSafety.repoRelativePath(root: repoRoot, url: url),
            savedURL: url,
            backupURL: backupURL,
            modifiedAt: modifiedAt(url)
        )
    }

    private var masterResumeURL: URL {
        repoRoot.appendingPathComponent("master-resumes/master_primary.yaml")
    }

    private func validateYAML(_ url: URL) throws {
        let result = try ProcessRunner.run(
            "ruby",
            ["-e", "require 'yaml'; YAML.load_file(ARGV[0])", url.path],
            cwd: repoRoot
        )
        guard result.status == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "Unknown YAML parse error.")
            throw NavCenterError.invalidPath("Master resume YAML is invalid: \(message)")
        }
    }

    private func modifiedAt(_ url: URL) -> String {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return ""
        }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
