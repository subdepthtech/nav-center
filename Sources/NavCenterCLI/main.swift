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
            }
        case "import-docs":
            let files = parser.repeatedOption("--file").map { URL(fileURLWithPath: $0) }
            guard !files.isEmpty else {
                throw NavCenterError.invalidPath("import-docs requires at least one --file path.")
            }
            let imported = try DocumentImporter(workspaceRoot: workspace).importDocuments(files)
            try writeJSON(imported)
        case "feedback-diagnostics":
            let redact = parser.flag("--redact")
            let report = FeedbackDiagnostics(workspaceRoot: workspace).report(redact: redact)
            try writeJSON(report)
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
            navcenterctl feedback-diagnostics [--redact] [--workspace <path>]
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

private extension String {
    func nonEmptyFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
