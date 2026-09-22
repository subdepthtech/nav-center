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
    private let toolProbe: ToolProbeConfiguration

    public init(repoRoot: URL, toolProbe: ToolProbeConfiguration? = nil) {
        self.repoRoot = repoRoot.standardizedFileURL
        self.toolProbe = toolProbe ?? ToolProbeConfiguration()
    }

    public func load() throws -> MasterResumeSnapshot {
        let url = masterResumeURL
        try PathSafety.assertExistingRegularFile(url, inside: repoRoot, label: "master resume")
        return MasterResumeSnapshot(
            relativePath: PathSafety.repoRelativePath(root: repoRoot, url: url),
            content: String(decoding: try PathSafety.readData(url, inside: repoRoot, label: "master resume", maxBytes: 1_048_576), as: UTF8.self),
            modifiedAt: modifiedAt(url)
        )
    }

    public func save(content: String, expectedContent: String? = nil) throws -> MasterResumeSaveResult {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NavCenterError.invalidPath("Master resume content cannot be empty.")
        }
        let rubyStatus = ToolProbe.resolve(.ruby, configuration: toolProbe)
        guard rubyStatus.state == .found, let ruby = rubyStatus.resolvedPath else {
            throw NavCenterError.invalidPath(ToolProbe.missingToolMessage(rubyStatus, action: "Master resume save"))
        }

        let url = masterResumeURL
        try PathSafety.assertExistingRegularFile(url, inside: repoRoot, label: "master resume")
        let original = try PathSafety.readData(url, inside: repoRoot, label: "master resume", maxBytes: 1_048_576)
        if let expectedContent, original != Data(expectedContent.utf8) { throw NavCenterError.invalidPath("Master resume changed on disk. Reload and reconcile your draft before saving.") }
        guard content.utf8.count <= 1_048_576 else { throw NavCenterError.invalidPath("Master resume exceeds the 1 MiB limit.") }
        let workDir = repoRoot.appendingPathComponent("tmp/master-resume-editor", isDirectory: true)
        try PathSafety.createDirectory(workDir, inside: repoRoot, label: "master resume work directory")

        let candidate = workDir.appendingPathComponent("candidate-\(UUID().uuidString).yaml")
        try PathSafety.assertWritablePath(candidate, inside: workDir, label: "master resume candidate")
        try PathSafety.atomicWrite(Data(content.utf8), to: candidate, inside: repoRoot, label: "master resume candidate")
        do {
            try validateYAML(candidate, ruby: ruby)
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            throw error
        }

        let backupDir = workDir.appendingPathComponent("backups", isDirectory: true)
        try PathSafety.createDirectory(backupDir, inside: repoRoot, label: "master resume backup directory")
        let backupURL = backupDir.appendingPathComponent("master_primary.\(Self.backupTimestamp()).\(String(UUID().uuidString.prefix(8))).yaml")
        try PathSafety.assertWritablePath(backupURL, inside: backupDir, label: "master resume backup")
        guard try PathSafety.readData(url, inside: repoRoot, label: "master resume") == original else { throw NavCenterError.invalidPath("Master resume changed during validation. Save was cancelled.") }
        try PathSafety.atomicWrite(original, to: backupURL, inside: repoRoot, label: "master resume backup")

        try PathSafety.assertWritablePath(url, inside: repoRoot, label: "master resume")
        try PathSafety.atomicWrite(Data(content.utf8), to: url, inside: repoRoot, label: "master resume")
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

    private func validateYAML(_ url: URL, ruby: String) throws {
        let result = try ProcessRunner.run(
            ruby,
            ["-e", Self.yamlValidator, url.path],
            cwd: repoRoot
        )
        guard result.status == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "Unknown YAML parse error.")
            throw NavCenterError.invalidPath("Master resume YAML is invalid: \(message)")
        }
    }

    private static let yamlValidator = #"""
    require 'yaml'
    require 'date'
    text = File.binread(ARGV[0], 1_048_577)
    abort 'YAML exceeds 1 MiB' if text.bytesize > 1_048_576
    stream = Psych.parse_stream(text)
    abort 'Expected exactly one YAML document' unless stream.children.length == 1
    count = 0
    allowed_tags = %w[map seq str int float bool null timestamp].map { |v| "tag:yaml.org,2002:#{v}" }
    visit = lambda do |node, depth|
      count += 1
      abort 'YAML structure exceeds limits' if depth > 40 || count > 50_000
      abort 'YAML aliases are not supported' if node.is_a?(Psych::Nodes::Alias)
      if node.respond_to?(:tag) && node.tag && !allowed_tags.include?(node.tag)
        abort 'Custom YAML tags are not supported'
      end
      (node.children || []).each { |child| visit.call(child, depth + 1) }
    end
    visit.call(stream, 0)
    value = YAML.safe_load(text, permitted_classes: [Date, Time], permitted_symbols: [], aliases: false)
    abort 'Master resume must be a mapping' unless value.is_a?(Hash)
    abort 'Profile must be a mapping' if value.key?('profile') && !value['profile'].is_a?(Hash)
    """#

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
