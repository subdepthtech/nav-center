import Foundation
import NavCenterCore

@main
struct NavCenterCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("navcenterctl: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        try ArgumentParser.validate(arguments)
        var parser = ArgumentParser(arguments)
        guard let command = parser.next() else {
            printUsage()
            return
        }

        let workspace = parser.option("--workspace").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? WorkspaceManager.resolveWorkspaceRoot()

        switch command {
        case "init-workspace":
            let result = try WorkspaceManager(workspaceRoot: workspace).initialize()
            print("Initialized workspace: \(result.workspaceRoot.path)")
            if result.masterResumeCreated {
                print("Created master-resumes/master_primary.yaml")
            }
        case "doctor":
            let json = parser.flag("--json")
            let report = FeedbackDiagnostics(workspaceRoot: workspace).report(redact: true)
            if json {
                try writeJSON(report)
            } else {
                print("Workspace: \(report.workspace.path)")
                print("Missing directories: \(report.workspace.requiredDirectoriesMissing.joined(separator: ", ").nonEmptyFallback("none"))")
                print("Packages: \(report.workspace.applicationPackageCount)")
                printToolTable(report.tools)
            }
        case "import-docs":
            let files = parser.repeatedOption("--file").map { URL(fileURLWithPath: $0) }
            guard !files.isEmpty else {
                throw NavCenterError.invalidPath("import-docs requires at least one --file path.")
            }
            let imported = try DocumentImporter(workspaceRoot: workspace).importDocuments(files)
            try writeJSON(imported)
        case "feedback-diagnostics":
            let includeUnredacted = parser.flag("--include-unredacted")
            let explicitRedact = parser.flag("--redact")
            let report = FeedbackDiagnostics(workspaceRoot: workspace).report(redact: explicitRedact || !includeUnredacted)
            try writeJSON(report)
        case "restore-cleanup":
            let path = try parser.requiredOption("--manifest")
            let manifest = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path)
            let result = try PackageCleanup(repoRoot: workspace).restore(manifestURL: manifest, confirmed: parser.flag("--confirm"))
            let restored = result.restoredPackages.count
            let alreadyInPlace = result.preview.candidates.count - restored
            if restored == 0 && result.restoredTrackerRows == 0 {
                print("Restored 0 packages. \(alreadyInPlace) already in place; nothing to do.")
            } else {
                var message = "Restored \(restored) package\(restored == 1 ? "" : "s")."
                if result.restoredTrackerRows > 0 {
                    message += " Restored \(result.restoredTrackerRows) tracker row\(result.restoredTrackerRows == 1 ? "" : "s")."
                }
                if alreadyInPlace > 0 { message += " \(alreadyInPlace) already in place." }
                print(message)
            }
            for warning in result.warnings { print("Warning: \(warning)") }
        case "create-package":
            let company = try parser.requiredOption("--company")
            let role = try parser.requiredOption("--role")
            let posting = try parser.requiredOption("--posting")
            let result = try ApplicationCreator(repoRoot: workspace).create(options: CreateApplicationOptions(
                source: .job(posting),
                company: company,
                role: role,
                date: parser.option("--date"),
                dryRun: parser.flag("--dry-run"),
                overwrite: parser.flag("--overwrite"),
                allowLocalURL: false
            ))
            try writeJSON(result)
        case "export-artifacts":
            let sources = parser.repeatedOption("--source")
            guard !sources.isEmpty else {
                throw NavCenterError.invalidPath("export-artifacts requires at least one --source markdown path.")
            }
            let results = try ArtifactExporter(repoRoot: workspace).export(markdownPaths: sources)
            print(results.map(\.sourceURL.path).joined(separator: "\n"))
        case "help", "--help", "-h":
            printUsage()
        default:
            throw NavCenterError.invalidPath("Unknown command: \(command)")
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func printUsage() {
        print(
            """
            navcenterctl init-workspace [--workspace <path>]
            navcenterctl doctor [--json] [--workspace <path>]
            navcenterctl import-docs --file <path> [--file <path>] [--workspace <path>]
            navcenterctl create-package --company <name> --role <title> --posting <path> [--date YYYY-MM-DD] [--overwrite] [--dry-run] [--workspace <path>]
            navcenterctl export-artifacts --source <markdown> [--source <markdown>] [--workspace <path>]
            navcenterctl feedback-diagnostics [--redact] [--include-unredacted] [--workspace <path>]
            navcenterctl restore-cleanup --manifest <path> --confirm [--workspace <path>]
            """
        )
    }
}

private struct ArgumentParser {
    private var arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    // Validate the entire invocation before resolving a workspace or performing any IO.
    static func validate(_ arguments: [String]) throws {
        guard let command = arguments.first else { return }
        let specifications: [String: (values: Set<String>, flags: Set<String>, repeated: Set<String>)] = [
            "init-workspace": (["--workspace"], [], []),
            "doctor": (["--workspace"], ["--json"], []),
            "import-docs": (["--workspace", "--file"], [], ["--file"]),
            "feedback-diagnostics": (["--workspace"], ["--redact", "--include-unredacted"], []),
            "restore-cleanup": (["--workspace", "--manifest"], ["--confirm"], []),
            "create-package": (["--workspace", "--company", "--role", "--posting", "--date"], ["--dry-run", "--overwrite"], []),
            "export-artifacts": (["--workspace", "--source"], [], ["--source"]),
            "help": ([], [], []), "--help": ([], [], []), "-h": ([], [], [])
        ]
        guard let spec = specifications[command] else {
            throw NavCenterError.invalidPath("Unknown command: \(command)")
        }
        var index = 1
        var seen = Set<String>()
        while index < arguments.count {
            let name = arguments[index]
            guard spec.values.contains(name) || spec.flags.contains(name) else {
                throw NavCenterError.invalidPath("Unexpected argument: \(name)")
            }
            guard seen.insert(name).inserted || spec.repeated.contains(name) else {
                throw NavCenterError.invalidPath("Duplicate option: \(name)")
            }
            if spec.values.contains(name) {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("--") else {
                    throw NavCenterError.invalidPath("Missing value for \(name)")
                }
                index += 2
            } else { index += 1 }
        }
    }

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func option(_ name: String) -> String? {
        guard let optionIndex = arguments.firstIndex(of: name),
              arguments.indices.contains(optionIndex + 1) else {
            return nil
        }
        let value = arguments[optionIndex + 1]
        arguments.remove(at: optionIndex + 1)
        arguments.remove(at: optionIndex)
        if optionIndex < index { index = max(0, index - 2) }
        return value
    }

    mutating func requiredOption(_ name: String) throws -> String {
        guard let value = option(name), !value.isEmpty else {
            throw NavCenterError.invalidPath("Missing required option: \(name)")
        }
        return value
    }

    mutating func repeatedOption(_ name: String) -> [String] {
        var values: [String] = []
        while let value = option(name) {
            values.append(value)
        }
        return values
    }

    mutating func flag(_ name: String) -> Bool {
        guard let optionIndex = arguments.firstIndex(of: name) else {
            return false
        }
        arguments.remove(at: optionIndex)
        if optionIndex < index { index = max(0, index - 1) }
        return true
    }
}

private func printToolTable(_ report: ToolAvailabilityReport) {
    print("Tools:")
    for status in report.tools {
        let variable = status.environmentVariable ?? "-"
        print("\(status.tool.rawValue)\t\(doctorState(status))\t\(variable)\t\(doctorDetail(status))")
    }
    print(ToolProbe.finderPathNotice)
}

private func doctorState(_ status: ToolStatus) -> String {
    switch status.state {
    case .found:
        let source: String
        switch status.source {
        case .environment: source = "environment"
        case .path: source = "path"
        case .fallback: source = "fallback"
        case .defaultPath: source = "default"
        case nil: source = "path"
        }
        return "found (\(source))"
    case .missing:
        return "missing"
    case .overrideInvalid:
        return "override-invalid"
    case .builtIn:
        return "built-in"
    }
}

private func doctorDetail(_ status: ToolStatus) -> String {
    switch status.state {
    case .found:
        return status.resolvedPath ?? ""
    case .overrideInvalid:
        return status.summary
    case .missing, .builtIn:
        return status.installHint
    }
}

private extension String {
    func nonEmptyFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
