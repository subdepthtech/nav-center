import Foundation
import CoreFoundation
import Darwin

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
    private let toolProbe: ToolProbeConfiguration
    private var log: [PackageActionEntry] = []
    private var counter = 0

    public init(repoRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment, toolProbe: ToolProbeConfiguration? = nil) {
        self.repoRoot = repoRoot
        self.environment = environment
        self.toolProbe = toolProbe ?? ToolProbeConfiguration(environment: environment)
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
            label: action == "ats-scan" ? "Run ATS Scan" : "Export Resume Artifacts",
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

        var command = try buildCommand(action: action, packageName: resolved.packageName)
        entry.command = command.display
        entry.outputPath = command.outputPath
        entry.status = "running"
        entry.message = "Action is running."
        entry.completedAt = nil
        update(entry)

        let started = Date()
        if commandHook == nil {
            if let failure = unresolvedToolMessage(action: action, command: &command) {
                entry.status = "failed"
                entry.exitCode = nil
                entry.message = failure
                entry.completedAt = ISO8601DateFormatter().string(from: Date())
                entry.durationMs = Int(Date().timeIntervalSince(started) * 1000)
                update(entry)
                return entry
            }
            entry.command = resolvedDisplay(command)
            update(entry)
        }
        do {
            if action == "ats-scan" {
                let result = try runStagedATS(command, packageURL: resolved.packageURL, commandHook: commandHook) { result in
                    entry.exitCode = result.status
                    entry.stdoutTail = tail(result.stdout)
                    entry.stderrTail = tail(result.stderr)
                }
                entry.status = result.status == 0 ? "succeeded" : "failed"
                entry.message = actionMessage(action: action, status: entry.status, exitCode: result.status, executable: command.executable)
            } else {
                try ensureArtifactsDirectory(resolved.packageURL)
                let outputURL = repoRoot.appendingPathComponent(command.outputPath)
                try PathSafety.assertWritablePath(outputURL, inside: resolved.packageURL, label: "package action output")
                let oldData = SQLiteSupport.exists(outputURL) ? try PathSafety.readData(outputURL, inside: resolved.packageURL, label: "prior action output") : nil
                let oldIdentity = SQLiteSupport.exists(outputURL) ? try PathSafety.identity(outputURL) : nil
                let oldModified = try? outputURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let result: ProcessResult
                if action == "refresh-resume", commandHook == nil, command.executable == "native-export" {
                    let source = "applications/\(resolved.packageName)/Resume_\(resolved.packageName).md"
                    _ = try ArtifactExporter(repoRoot: repoRoot, environment: environment.merging(["NAV_CENTER_SKIP_VAULT_SYNC": "1"]) { _, value in value }, toolProbe: toolProbe).export(markdownPaths: [source])
                    result = ProcessResult(status: 0, stdout: "", stderr: "")
                } else {
                    result = try (commandHook ?? ProcessRunner.run)(command.executable, command.args, repoRoot, command.environment)
                }
                entry.exitCode = result.status
                entry.stdoutTail = tail(result.stdout)
                entry.stderrTail = tail(result.stderr)
                if result.status == 0 {
                    let output = try PathSafety.readData(outputURL, inside: resolved.packageURL, label: "package action output")
                    try PathSafety.assertWritablePath(outputURL, inside: resolved.packageURL, label: "package action output")
                    guard !output.isEmpty else { throw NavCenterError.commandFailed("Command exited successfully but the expected output is empty.") }
                    let modified = try outputURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let newIdentity = try PathSafety.identity(outputURL)
                    guard oldData != output || oldIdentity != newIdentity || oldModified != modified else {
                        throw NavCenterError.commandFailed("Command exited successfully but the expected output was not refreshed.")
                    }
                    guard output.starts(with: Data("%PDF-".utf8)) else { throw NavCenterError.commandFailed("Resume output is not a PDF.") }
                }
                entry.status = result.status == 0 ? "succeeded" : "failed"
                entry.message = actionMessage(action: action, status: entry.status, exitCode: result.status, executable: command.executable)
            }
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
        var executable: String
        let args: [String]
        let display: String
        let outputPath: String
        let environment: [String: String]
    }

    private func resolvedDisplay(_ command: BuiltCommand) -> String {
        let invocation = ([command.executable] + command.args).joined(separator: " ")
        guard command.environment["NAV_CENTER_SKIP_VAULT_SYNC"] == "1" else { return invocation }
        return "NAV_CENTER_SKIP_VAULT_SYNC=1 \(invocation)"
    }

    private struct ATSFileSnapshot: Equatable {
        let data: Data
        let identity: PathSafety.Identity
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    private func atsSnapshot(_ url: URL, inside root: URL, limit: Int = 4 * 1024 * 1024) throws -> ATSFileSnapshot? {
        try PathSafety.assertNoSymlinkSegments(url, root: root, label: "ATS file")
        var before = stat()
        if lstat(url.path, &before) != 0 {
            guard errno == ENOENT else { throw NavCenterError.invalidPath("Could not inspect ATS file: \(url.lastPathComponent)") }
            return nil
        }
        guard (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1 else {
            throw NavCenterError.invalidPath("ATS files must be regular files without aliases: \(url.lastPathComponent)")
        }
        let identity = try PathSafety.identity(url)
        let data = try PathSafety.readData(url, inside: root, label: "ATS file", maxBytes: limit)
        var after = stat()
        guard lstat(url.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_nlink == 1 else { throw NavCenterError.invalidPath("ATS file changed while being read. Retry the scan.") }
        return ATSFileSnapshot(data: data, identity: identity,
                               modifiedSeconds: after.st_mtimespec.tv_sec, modifiedNanoseconds: after.st_mtimespec.tv_nsec,
                               changedSeconds: after.st_ctimespec.tv_sec, changedNanoseconds: after.st_ctimespec.tv_nsec)
    }

    private func atsResumePath(_ packageURL: URL) throws -> String {
        let names = try atsDirectoryNames(packageURL)
        let artifacts = try atsDirectoryNames(packageURL.appendingPathComponent("artifacts"))
        guard names.count + artifacts.count <= 512 else { throw NavCenterError.invalidPath("ATS package contains too many files.") }
        for suffix in [".docx.txt", ".pdf.txt", ".txt"] {
            if let first = artifacts.filter({ $0.hasPrefix("Resume_") && $0.hasSuffix(suffix) }).sorted().first { return "artifacts/" + first }
        }
        guard let first = names.filter({ $0.hasPrefix("Resume_") && $0.hasSuffix(".md") }).sorted().first else {
            throw NavCenterError.notFound("ATS scan requires a Resume_*.md source or an exported resume text file.")
        }
        return first
    }

    private func atsDirectoryNames(_ url: URL) throws -> [String] {
        try PathSafety.assertNoSymlinkSegments(url, root: repoRoot, label: "ATS input directory")
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NavCenterError.invalidPath("Could not read ATS input directory.") }
        guard let directory = fdopendir(descriptor) else { close(descriptor); throw NavCenterError.invalidPath("Could not list ATS inputs.") }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw NavCenterError.invalidPath("Could not list ATS inputs.") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < 512 else { throw NavCenterError.invalidPath("ATS package contains too many files.") }
            names.append(name)
        }
        return names
    }

    private func runStagedATS(_ command: BuiltCommand, packageURL: URL, commandHook: CommandHook?, onResult: (ProcessResult) -> Void) throws -> ProcessResult {
        try ensureArtifactsDirectory(packageURL)
        let identities = try [repoRoot, PathSafety.applicationsRoot(repoRoot: repoRoot), packageURL, packageURL.appendingPathComponent("artifacts")].map { ($0, try PathSafety.identity($0)) }
        // Cooperating actions serialize on the package directory, without leaving lock files.
        let lease = open(packageURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lease >= 0 else { throw NavCenterError.invalidPath("Could not lock the ATS package.") }
        defer { _ = flock(lease, LOCK_UN); close(lease) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw NavCenterError.commandFailed("An ATS scan is already running for this package.") }
        var leaseInfo = stat()
        guard fstat(lease, &leaseInfo) == 0, leaseInfo.st_dev == identities[2].1.device, leaseInfo.st_ino == identities[2].1.inode else {
            throw NavCenterError.invalidPath("ATS package changed before the scan started.")
        }
        let outputURL = repoRoot.appendingPathComponent(command.outputPath)
        let previous = try atsSnapshot(outputURL, inside: repoRoot)
        let resumePath = try atsResumePath(packageURL)
        guard let resume = try atsSnapshot(packageURL.appendingPathComponent(resumePath), inside: repoRoot) else { throw NavCenterError.notFound("ATS resume is missing.") }
        let posting = try atsSnapshot(packageURL.appendingPathComponent("posting.md"), inside: repoRoot)
        guard String(data: resume.data, encoding: .utf8) != nil,
              posting.map({ String(data: $0.data, encoding: .utf8) != nil }) ?? true else {
            throw NavCenterError.invalidPath("ATS resume and posting text must contain valid UTF-8.")
        }

        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-ats-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else { throw NavCenterError.commandFailed("Could not create private ATS staging.") }
        let stage = URL(fileURLWithPath: String(cString: created), isDirectory: true).resolvingSymlinksInPath()
        let stageIdentity = try PathSafety.identity(stage)
        defer { if (try? PathSafety.identity(stage)) == stageIdentity { try? FileManager.default.removeItem(at: stage) } }
        let stagePackage = stage.appendingPathComponent(command.args[1], isDirectory: true)
        try PathSafety.createDirectory(stagePackage.appendingPathComponent("artifacts"), inside: stage, label: "ATS staging")
        try PathSafety.atomicWrite(resume.data, to: stagePackage.appendingPathComponent(resumePath), inside: stage, label: "ATS resume copy")
        if let posting { try PathSafety.atomicWrite(posting.data, to: stagePackage.appendingPathComponent("posting.md"), inside: stage, label: "ATS posting copy") }
        let childEnvironment = command.environment.merging(["ATSIM_JOB_HUNT_ROOT": stage.path, "PYTHONDONTWRITEBYTECODE": "1"]) { _, value in value }
        let result: ProcessResult
        if let commandHook { result = try commandHook(command.executable, command.args, stage, childEnvironment) }
        else { result = try ProcessRunner.run(command.executable, command.args, cwd: stage, environment: childEnvironment, timeout: 30, maximumOutputBytes: 1024 * 1024) }
        onResult(result)
        guard result.status == 0 else { return result }
        guard let generated = try atsSnapshot(stage.appendingPathComponent(command.outputPath), inside: stage) else {
            throw NavCenterError.commandFailed("ATS command did not produce a report.")
        }
        guard var report = try JSONSerialization.jsonObject(with: generated.data) as? [String: Any],
              let scores = report["scores"] as? [String: Any], let overall = scores["overall"] as? NSNumber,
              CFGetTypeID(overall) != CFBooleanGetTypeID(), overall.doubleValue.isFinite,
              (0...100).contains(overall.doubleValue), report["warnings"] is [String] else {
            throw NavCenterError.commandFailed("ATS output must contain scores.overall from 0 to 100 and a warnings list.")
        }
        // Report provenance refers to captured workspace inputs, not the temporary copies.
        var input = report["input"] as? [String: Any] ?? [:]
        input["resume"] = packageURL.path
        input["text_source"] = packageURL.appendingPathComponent(resumePath).path
        input["job_description"] = posting == nil ? NSNull() : packageURL.appendingPathComponent("posting.md").path as Any
        input["skills_file"] = NSNull()
        report["input"] = input
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else {
            throw NavCenterError.commandFailed("ATS report exceeds the 4 MiB limit after formatting. The current report was preserved.")
        }
        for (url, identity) in identities {
            guard try PathSafety.identity(url) == identity else { throw NavCenterError.invalidPath("ATS workspace changed during the scan. Retry without replacing the current report.") }
        }
        guard try atsResumePath(packageURL) == resumePath,
              try atsSnapshot(packageURL.appendingPathComponent(resumePath), inside: repoRoot) == resume,
              try atsSnapshot(packageURL.appendingPathComponent("posting.md"), inside: repoRoot) == posting,
              try atsSnapshot(outputURL, inside: repoRoot) == previous else {
            throw NavCenterError.commandFailed("ATS inputs or report changed during the scan. The current report was preserved; retry the scan.")
        }
        try PathSafety.atomicWrite(data, to: outputURL, inside: repoRoot, label: "ATS report")
        return result
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
            let executable = environment["NAV_CENTER_EXPORT_BIN"].flatMap({ $0.isEmpty ? nil : $0 }) ?? "native-export"
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
            try PathSafety.createDirectory(artifacts, inside: packageURL, label: "package artifacts directory")
        }
        try PathSafety.assertNoSymlinkSegments(artifacts, root: packageURL, label: "Package artifacts directory")
    }

    private func normalizeAction(_ actionKey: String) throws -> String {
        switch actionKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-") {
        case "ats", "ats-scan", "run-ats-scan":
            return "ats-scan"
        case "refresh-resume", "resume-refresh", "refresh-pdf", "export-artifacts":
            return "refresh-resume"
        default:
            throw NavCenterError.invalidPath("Package action is not supported: \(actionKey)")
        }
    }

    private func unresolvedToolMessage(action: String, command: inout BuiltCommand) -> String? {
        let tool: ExternalTool = action == "ats-scan" ? .atsim : .exportTool
        let actionName = action == "ats-scan" ? "ATS scan" : "Resume PDF refresh"
        let resolved = ToolProbe.resolve(tool, configuration: toolProbe)
        switch resolved.state {
        case .found:
            if let path = resolved.resolvedPath { command.executable = path }
            return nil
        case .builtIn where action == "refresh-resume" && command.executable == "native-export":
            for dependency in [ExternalTool.pandoc, .pdftotext, .chrome] {
                let resolvedDependency = ToolProbe.resolve(dependency, configuration: toolProbe)
                if resolvedDependency.state != .found {
                    return ToolProbe.missingToolMessage(resolvedDependency, action: "Document export")
                }
            }
            return nil
        case .builtIn:
            let variable = ExternalTool.exportTool.environmentVariable ?? "the override"
            let invalid = ToolStatus(
                tool: .exportTool,
                state: .overrideInvalid,
                resolvedPath: nil,
                source: nil,
                environmentVariable: ExternalTool.exportTool.environmentVariable,
                installHint: ExternalTool.exportTool.installHint,
                summary: "\(variable) is not an executable file"
            )
            return ToolProbe.missingToolMessage(invalid, action: actionName)
        default:
            return ToolProbe.missingToolMessage(resolved, action: actionName)
        }
    }

    private func actionMessage(action: String, status: String, exitCode: Int32, executable: String) -> String {
        if status == "succeeded" {
            if action == "refresh-resume" {
                return executable == "native-export"
                    ? "Resume artifacts exported: HTML, DOCX, PDF, and text extractions."
                    : "Resume PDF refreshed by the exporter set in NAV_CENTER_EXPORT_BIN."
            }
            return "ATS scan completed and ats-report.json was refreshed."
        }
        if exitCode == 127 {
            let tool: ExternalTool = action == "refresh-resume" ? .exportTool : .atsim
            let actionName = action == "refresh-resume" ? "Resume PDF refresh" : "ATS scan"
            let resolved = ToolProbe.resolve(tool, configuration: toolProbe)
            if resolved.state == .missing || resolved.state == .overrideInvalid {
                return ToolProbe.missingToolMessage(resolved, action: actionName)
            }
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
