import Foundation

public struct PackageActionEntry: Codable, Equatable, Identifiable {
    public let id: String
    public let action: String
    public let label: String
    public let packageName: String
    public var status: String
    public let requestedAt: String
    public var completedAt: String?
    public var durationMs: Int
    public var command: String?
    public var outputPath: String?
    public var exitCode: Int32?
    public var message: String
    public var stdoutTail: String
    public var stderrTail: String
}

public final class PackageActionRunner {
    public typealias CommandHook = (_ executable: String, _ args: [String], _ cwd: URL, _ env: [String: String]) throws -> ProcessResult

    private let repoRoot: URL
    private let environment: [String: String]
    private var log: [PackageActionEntry] = []
    private var counter = 0

    public init(repoRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.repoRoot = repoRoot
        self.environment = environment
    }

    public func actionLog(packageName: String? = nil, limit: Int = 20) -> [PackageActionEntry] {
        let filtered = packageName.map { name in log.filter { $0.packageName == name } } ?? log
        return Array(filtered.prefix(max(1, limit)))
    }

    @discardableResult
    public func run(packageName: String, actionKey: String, confirmed: Bool, commandHook: CommandHook? = nil) throws -> PackageActionEntry {
        let action = try normalizeAction(actionKey)
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        let requestedAt = ISO8601DateFormatter().string(from: Date())
        var entry = record(PackageActionEntry(
            id: nextID(),
            action: action,
            label: action == "ats-scan" ? "Run ATS Scan" : "Refresh Resume PDF",
            packageName: resolved.packageName,
            status: "blocked",
            requestedAt: requestedAt,
            completedAt: requestedAt,
            durationMs: 0,
            command: nil,
            outputPath: nil,
            exitCode: nil,
            message: "Action was not run because confirmation was missing.",
            stdoutTail: "",
            stderrTail: ""
        ))

        guard confirmed else { return entry }

        let command = try buildCommand(action: action, packageName: resolved.packageName)
        entry.command = command.display
        entry.outputPath = command.outputPath
        entry.status = "running"
        entry.message = "Action is running."
        entry.completedAt = nil
        update(entry)

        let started = Date()
        do {
            try ensureArtifactsDirectory(resolved.packageURL)
            let result = try (commandHook ?? ProcessRunner.run)(command.executable, command.args, repoRoot, command.environment)
            entry.exitCode = result.status
            entry.stdoutTail = tail(result.stdout)
            entry.stderrTail = tail(result.stderr)
            entry.status = result.status == 0 ? "succeeded" : "failed"
            entry.message = actionMessage(action: action, status: entry.status, exitCode: result.status)
        } catch {
            entry.status = "failed"
            entry.message = error.localizedDescription
        }
        entry.completedAt = ISO8601DateFormatter().string(from: Date())
        entry.durationMs = Int(Date().timeIntervalSince(started) * 1000)
        update(entry)
        return entry
    }

    private struct BuiltCommand {
        let executable: String
        let args: [String]
        let display: String
        let outputPath: String
        let environment: [String: String]
    }

    private func buildCommand(action: String, packageName: String) throws -> BuiltCommand {
        let packagePath = "applications/\(packageName)"
        switch action {
        case "ats-scan":
            let output = "\(packagePath)/artifacts/ats-report.json"
            let executable = environment["NAV_CENTER_ATSIM_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "atsim"
            return BuiltCommand(
                executable: executable,
                args: ["scan", packagePath, "--out", output],
                display: "atsim scan \(packagePath) --out \(output)",
                outputPath: output,
                environment: [:]
            )
        case "refresh-resume":
            let source = "\(packagePath)/Resume_\(packageName).md"
            let output = "\(packagePath)/artifacts/Resume_\(packageName).pdf"
            guard let executable = environment["NAV_CENTER_EXPORT_BIN"].flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw NavCenterError.invalidPath("Refresh resume requires NAV_CENTER_EXPORT_BIN to point at an export command.")
            }
            return BuiltCommand(
                executable: executable,
                args: ["export", source],
                display: "NAV_CENTER_SKIP_VAULT_SYNC=1 \(executable) export \(source)",
                outputPath: output,
                environment: ["NAV_CENTER_SKIP_VAULT_SYNC": "1"]
            )
        default:
            throw NavCenterError.invalidPath("Package action is not supported: \(action)")
        }
    }

    private func ensureArtifactsDirectory(_ packageURL: URL) throws {
        let artifacts = packageURL.appendingPathComponent("artifacts", isDirectory: true)
        if FileManager.default.fileExists(atPath: artifacts.path) {
            let values = try artifacts.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw NavCenterError.invalidPath("Package artifacts directory must not be a symlink")
            }
            if values.isDirectory != true {
                throw NavCenterError.invalidPath("Package artifacts path must be a directory")
            }
        } else {
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        }
        try PathSafety.assertNoSymlinkSegments(artifacts, root: packageURL, label: "Package artifacts directory")
    }

    private func normalizeAction(_ actionKey: String) throws -> String {
        switch actionKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-") {
        case "ats", "ats-scan", "run-ats-scan":
            return "ats-scan"
        case "refresh-resume", "resume-refresh", "refresh-pdf":
            return "refresh-resume"
        default:
            throw NavCenterError.invalidPath("Package action is not supported: \(actionKey)")
        }
    }

    private func actionMessage(action: String, status: String, exitCode: Int32) -> String {
        if status == "succeeded" {
            return action == "refresh-resume" ? "Resume PDF refreshed from source markdown." : "ATS scan completed and ats-report.json was refreshed."
        }
        return action == "refresh-resume" ? "Resume PDF refresh failed with exit code \(exitCode)." : "ATS scan failed with exit code \(exitCode)."
    }

    private func record(_ entry: PackageActionEntry) -> PackageActionEntry {
        log.insert(entry, at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
        return entry
    }

    private func update(_ entry: PackageActionEntry) {
        guard let index = log.firstIndex(where: { $0.id == entry.id }) else { return }
        log[index] = entry
    }

    private func nextID() -> String {
        counter += 1
        return "action_\(Int(Date().timeIntervalSince1970 * 1000))_\(counter)"
    }

    private func tail(_ text: String) -> String {
        let limit = 4_000
        return text.count > limit ? String(text.suffix(limit)) : text
    }
}
